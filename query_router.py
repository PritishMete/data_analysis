"""
query_router.py
─────────────────────────────────────────────────────────────────────────────
Implements the query.json principle directly:

    "LLM should decide the analytical operation, but backend should generate
     and execute queries."

The router agent NEVER writes raw SQL. It only decides:
  (a) route: "sql" (an analytical question) vs "operation" (a spreadsheet
      action — pivot/filter/dedupe/color_scale, handled by command_agent.py)
  (b) if "sql": a STRUCTURED PLAN using the exact operation taxonomy from
      query.json — aggregation / filter / ranking / window_function — built
      only from column names, functions, and conditions (no SQL syntax).

A deterministic Python builder (`build_sql_from_plan`) then turns that plan
into a DuckDB SQL statement, resolving every column name against whatever
dataset is actually loaded at request time. Because the builder — not the
LLM — is what touches SQL syntax, this works on ANY dataset without
depending on column names the model has seen before, and it's trivially
testable without an LLM at all (see test_query_router.py).

Wire into main.py with:

    from query_router import handle_smart_query
    result = await handle_smart_query(text, df, available_sheets)
─────────────────────────────────────────────────────────────────────────────
"""

import json
import re
import traceback
import uuid

import duckdb
import pandas as pd

from google.adk.agents import LlmAgent
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types

from command_agent import parse_agentic_command

MODEL = "gemini-3.5-flash"

# Name the uploaded dataframe is registered under inside DuckDB.
TABLE_NAME = "data"

AGG_FUNCTIONS = {"sum", "avg", "count", "min", "max"}
FILTER_OPERATORS = {
    "equals", "not_equals", "contains",
    "greater_than", "less_than", "greater_than_equal", "less_than_equal",
    "between", "above_average", "below_average",
}
WINDOW_TYPES = {"rank", "dense_rank", "running_total", "moving_average"}


# ── Router prompt — outputs a STRUCTURED PLAN, never raw SQL ─────────────────

ROUTER_SYSTEM_INSTRUCTION = """You are a routing + query-planning agent for a natural language
data analysis tool. You are given the list of available column names for the currently loaded
dataset, plus the user's request. You NEVER write SQL — you only decide the route and, if
applicable, a structured plan built from the operation types below.

Decide ONE of two routes:

1. "sql" — the request is an analytical QUESTION about the data: aggregations, filtering to
   answer a question, ranking / top-N / bottom-N, or window functions (rank, dense_rank, running
   total, moving average). Any read-only question whose answer is a table or a single value.
2. "operation" — the request asks to MODIFY or reshape the spreadsheet itself: building a pivot
   table into a new sheet, permanently filtering/keeping/removing rows in a sheet, deduplicating,
   conditional colour formatting, or ADDING A NEW PERSISTENT COLUMN to the sheet (e.g. "add a
   column that marks customers as new or returning"). These go through a separate handler — set
   "plan" to null.

   DISAMBIGUATION for classification-style requests: if the user says "add", "create", "insert" a
   column, or "mark"/"label"/"tag" each row — that PERSISTS a change to the sheet, so route
   "operation". If instead the user is asking a QUESTION or wants a comparison/report (e.g.
   "compare revenue between new and returning customers") without asking to modify the sheet,
   route "sql" and use derived_columns (below) to compute the classification as part of the query.

If route is "sql", build a "plan" object using ONLY these fields (omit any that don't apply,
never invent a column that isn't in the available list — match wording to the closest real
column, case-insensitive):

{
  "group_by": ["<column>", ...],              // columns to group by, for aggregation/ranking
  "metrics": [{"column": "<column>", "function": "sum|avg|count|min|max", "alias": "<short_name>"}],
  "filters": [{"column": "<column>", "operator": "equals|not_equals|contains|greater_than|
                less_than|greater_than_equal|less_than_equal|between|above_average|below_average",
               "value": "<string>", "value2": "<string, only for between>"}],
  "window": {"type": "rank|dense_rank|running_total|moving_average",
             "partition_by": ["<column>", ...],
             "order_by": [{"column": "<column or metric alias>", "direction": "asc|desc"}],
             "window_size": <int, only for moving_average, default 3>},
  "keep_top_n_per_partition": <int, ONLY when the user wants just the top/bottom result WITHIN
                                each group, e.g. "best product in each region" -> 1>,
  "order_by": [{"column": "<column or metric alias>", "direction": "asc|desc"}],
  "limit": <int, for a plain top-N/bottom-N over the whole result, not per group>,
  "derived_columns": [
    {
      "alias": "<short_name, e.g. customer_category>",
      "case": {
        "condition": {
          "window_function": "count|sum|avg|min|max",
          "column": "<column to aggregate, omit for count(*)>",
          "partition_by": ["<column>", ...],
          "operator": "equals|not_equals|greater_than|less_than|greater_than_equal|less_than_equal",
          "value": "<string>"
        },
        "then": "<label if condition is true>",
        "else": "<label if condition is false>"
      }
    }
  ]
}

Use "derived_columns" whenever the user wants to CLASSIFY rows based on a per-group count/sum/etc
before aggregating — e.g. "compare revenue between new and returning customers" needs a derived
label (count of orders per customer > 1 -> "Returning" else "New") that group_by/metrics then
reference by its alias, exactly like a real column.

CRITICAL DISAMBIGUATION — "new vs returning customers" is NEVER a real column, even if the
dataset happens to have a similarly-worded column like "CustomerType" (e.g. Retail/Wholesale) or
"CustomerCategory". Those are unrelated business categories, not purchase-frequency labels. If
the user's wording is about NEW vs RETURNING, FIRST-TIME vs REPEAT, or ONE-TIME vs LOYAL
customers, you MUST use derived_columns with a count-based condition — do not take the shortcut
of matching to an existing categorical column just because a plausible-sounding one exists. Only
use an existing column directly when the user names an attribute the dataset actually tracks as
such (e.g. "revenue by customer type" or "revenue by retail vs wholesale" -> group_by that real
column, no derived_columns needed).

Respond with ONLY a single JSON object — no markdown fences, no commentary — matching EXACTLY:

{
  "route": "sql" | "operation",
  "plan": { ... as above ... } | null,
  "confidence": <float 0 to 1>,
  "message": "<one short sentence confirming what you understood>"
}

confidence reflects how well you matched real column names — never how complex the request is.

EXAMPLES (illustrative only — always use the real "Available columns" given to you):

User request: total revenue by region, ranked highest to lowest
-> {"route":"sql","plan":{"group_by":["region"],
     "metrics":[{"column":"revenue","function":"sum","alias":"total_revenue"}],
     "order_by":[{"column":"total_revenue","direction":"desc"}]},
    "confidence":0.9,"message":"Grouped revenue by region, ordered highest to lowest."}

User request: best-selling product in each region
-> {"route":"sql","plan":{"group_by":["region","product"],
     "metrics":[{"column":"quantity","function":"sum","alias":"total_qty"}],
     "window":{"type":"rank","partition_by":["region"],
               "order_by":[{"column":"total_qty","direction":"desc"}]},
     "keep_top_n_per_partition":1},
    "confidence":0.85,"message":"Found the top product by quantity within each region."}

User request: build a pivot table showing total sales by region and product
-> {"route":"operation","plan":null,"confidence":0.9,
    "message":"This reshapes the sheet, so it is a pivot operation, not a SQL question."}

User request: add a column called Customer_Status that marks returning customers
-> {"route":"operation","plan":null,"confidence":0.9,
    "message":"This adds a persistent column to the sheet, so it is an add_column operation, not a SQL question."}

User request: compare revenue between new and returning customers
-> {"route":"sql","plan":{
     "derived_columns":[{"alias":"customer_category","case":{
        "condition":{"window_function":"count","column":"customername",
                      "partition_by":["customername"],"operator":"greater_than","value":"1"},
        "then":"Returning","else":"New"}}],
     "group_by":["customer_category"],
     "metrics":[{"column":"totalprice","function":"sum","alias":"total_rev"}]},
    "confidence":0.85,
    "message":"Classified customers as new/returning by order count, then summed revenue per group."}

User request: compare revenue by customer type
-> {"route":"sql","plan":{
     "group_by":["customertype"],
     "metrics":[{"column":"totalprice","function":"sum","alias":"total_rev"}]},
    "confidence":0.9,
    "message":"Grouped revenue by the existing customer_type column (e.g. Retail vs Wholesale) — not a derived new/returning label, since the user asked about type, not purchase frequency."}
"""


def _extract_json(text: str) -> str:
    """Pulls a JSON object out of arbitrary model output (fenced or with stray prose)."""
    text = text.strip()
    fence_match = re.search(r"```(?:json)?\s*(.*?)\s*```", text, re.DOTALL)
    if fence_match:
        return fence_match.group(1).strip()
    first_brace = text.find("{")
    last_brace = text.rfind("}")
    if first_brace != -1 and last_brace != -1 and last_brace > first_brace:
        return text[first_brace:last_brace + 1]
    return text


# ── Deterministic SQL builder (no LLM involved) ───────────────────────────────

class PlanError(Exception):
    """Raised when a plan can't be safely resolved against the actual dataset."""


def _resolve_column(name: str, available_columns: list) -> str:
    """Matches a model-provided column name to a REAL column in the current
    dataset, case-insensitively, with a loose substring fallback. Raises
    PlanError if nothing reasonable matches — the plan must never silently
    reference a column that doesn't exist.
    """
    if not name:
        raise PlanError("Empty column name in plan.")
    name_l = str(name).strip().lower()
    for col in available_columns:
        if col.lower() == name_l:
            return col
    candidates = [c for c in available_columns if name_l in c.lower() or c.lower() in name_l]
    if candidates:
        return candidates[0]
    raise PlanError(f"Column '{name}' does not match any column in the current dataset.")


def _quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _sql_literal(value) -> str:
    """Renders a value for use in a SQL literal position, numeric when possible."""
    if value is None:
        return "NULL"
    s = str(value)
    try:
        float(s)
        return s  # numeric, no quoting needed
    except ValueError:
        return "'" + s.replace("'", "''") + "'"


def _build_filter_clause(f: dict, available_columns: list, table_name: str) -> str:
    col = _quote_ident(_resolve_column(f.get("column"), available_columns))
    op = f.get("operator")
    if op not in FILTER_OPERATORS:
        raise PlanError(f"Unsupported filter operator '{op}'.")
    value = f.get("value")

    if op == "equals":
        return f"{col} = {_sql_literal(value)}"
    if op == "not_equals":
        return f"{col} != {_sql_literal(value)}"
    if op == "contains":
        return f"{col} ILIKE '%' || {_sql_literal(value)} || '%'"
    if op == "greater_than":
        return f"{col} > {_sql_literal(value)}"
    if op == "less_than":
        return f"{col} < {_sql_literal(value)}"
    if op == "greater_than_equal":
        return f"{col} >= {_sql_literal(value)}"
    if op == "less_than_equal":
        return f"{col} <= {_sql_literal(value)}"
    if op == "between":
        value2 = f.get("value2")
        return f"{col} BETWEEN {_sql_literal(value)} AND {_sql_literal(value2)}"
    if op == "above_average":
        return f"{col} > (SELECT AVG({col}) FROM {table_name})"
    if op == "below_average":
        return f"{col} < (SELECT AVG({col}) FROM {table_name})"
    raise PlanError(f"Unhandled filter operator '{op}'.")


def _build_comparison(expr: str, operator: str, value) -> str:
    mapping = {
        "equals": "=", "not_equals": "!=",
        "greater_than": ">", "less_than": "<",
        "greater_than_equal": ">=", "less_than_equal": "<=",
    }
    if operator not in mapping:
        raise PlanError(f"Unsupported derived-column condition operator '{operator}'.")
    return f"{expr} {mapping[operator]} {_sql_literal(value)}"


def _build_derived_column(dc: dict, available_columns: list) -> tuple:
    """Builds a `CASE WHEN <window aggregate condition> THEN x ELSE y END AS alias`
    expression, e.g. for classifying rows by a per-group count/sum/etc before
    the main aggregation. Returns (alias, select_expr_sql).
    """
    alias = re.sub(r"\W+", "_", (dc.get("alias") or "derived_col").strip().lower()).strip("_")
    case = dc.get("case") or {}
    cond = case.get("condition") or {}

    wf = (cond.get("window_function") or "count").lower()
    if wf not in AGG_FUNCTIONS:
        raise PlanError(f"Unsupported derived-column window_function '{wf}'.")
    partition_by = [_resolve_column(c, available_columns) for c in cond.get("partition_by", []) or []]
    if not partition_by:
        raise PlanError("derived_columns condition requires at least one partition_by column.")
    partition_sql = f"PARTITION BY {', '.join(_quote_ident(c) for c in partition_by)}"

    if wf == "count":
        col = cond.get("column")
        col_expr = _quote_ident(_resolve_column(col, available_columns)) if col else "*"
        window_expr = f"COUNT({col_expr}) OVER ({partition_sql})"
    else:
        col = _resolve_column(cond.get("column"), available_columns)
        window_expr = f"{wf.upper()}({_quote_ident(col)}) OVER ({partition_sql})"

    condition_sql = _build_comparison(window_expr, cond.get("operator"), cond.get("value"))
    then_val = _sql_literal(case.get("then"))
    else_val = _sql_literal(case.get("else"))
    expr_sql = f"CASE WHEN {condition_sql} THEN {then_val} ELSE {else_val} END AS {_quote_ident(alias)}"
    return alias, expr_sql



def build_sql_from_plan(plan: dict, available_columns: list, table_name: str = TABLE_NAME) -> str:
    """Deterministically builds a single DuckDB SELECT statement from a
    structured plan. Every column reference is resolved against
    available_columns — nothing is trusted verbatim from the LLM.
    """
    if not plan:
        raise PlanError("Empty plan.")

    derived_columns = plan.get("derived_columns", []) or []
    source = table_name
    resolvable_columns = list(available_columns)

    if derived_columns:
        derived_select_parts = ["*"]
        for dc in derived_columns:
            alias, expr_sql = _build_derived_column(dc, resolvable_columns)
            derived_select_parts.append(expr_sql)
            resolvable_columns.append(alias)  # so group_by/metrics/order_by can reference it
        inner = f"SELECT {', '.join(derived_select_parts)} FROM {table_name}"
        source = f"({inner})"

    group_by = [_resolve_column(c, resolvable_columns) for c in plan.get("group_by", []) or []]
    metrics = plan.get("metrics", []) or []
    filters = plan.get("filters", []) or []
    window = plan.get("window")
    keep_top_n_per_partition = plan.get("keep_top_n_per_partition")
    order_by = plan.get("order_by", []) or []
    limit = plan.get("limit")

    select_parts = []
    alias_lookup = {}  # metric alias (lowercase) -> select expression, for order/window resolution

    for gc in group_by:
        select_parts.append(_quote_ident(gc))

    for m in metrics:
        func = (m.get("function") or "").lower()
        if func not in AGG_FUNCTIONS:
            raise PlanError(f"Unsupported aggregation function '{func}'.")
        col = _resolve_column(m.get("column"), resolvable_columns)
        alias = re.sub(r"\W+", "_", (m.get("alias") or f"{func}_{col}").strip().lower()).strip("_")
        expr = f"COUNT({_quote_ident(col)})" if func == "count" else f"{func.upper()}({_quote_ident(col)})"
        select_parts.append(f"{expr} AS {_quote_ident(alias)}")
        alias_lookup[alias.lower()] = expr

    if not group_by and not metrics:
        # No aggregation requested — plain row-level query.
        select_parts = ["*"]

    window_alias = None
    if window:
        wtype = (window.get("type") or "").lower()
        if wtype not in WINDOW_TYPES:
            raise PlanError(f"Unsupported window type '{wtype}'.")
        partition_by = [_resolve_column(c, resolvable_columns) for c in window.get("partition_by", []) or []]
        w_order = window.get("order_by", []) or []
        order_clauses = []
        for o in w_order:
            oc = o.get("column", "")
            direction = "DESC" if (o.get("direction") or "desc").lower() == "desc" else "ASC"
            expr = alias_lookup.get(str(oc).lower())
            if expr is None:
                expr = _quote_ident(_resolve_column(oc, resolvable_columns))
            order_clauses.append(f"{expr} {direction}")

        partition_sql = f"PARTITION BY {', '.join(_quote_ident(c) for c in partition_by)}" if partition_by else ""
        order_sql = f"ORDER BY {', '.join(order_clauses)}" if order_clauses else ""
        over_clause = " ".join(p for p in [partition_sql, order_sql] if p)

        if wtype == "rank":
            window_alias = "rnk"
            select_parts.append(f"RANK() OVER ({over_clause}) AS {window_alias}")
        elif wtype == "dense_rank":
            window_alias = "rnk"
            select_parts.append(f"DENSE_RANK() OVER ({over_clause}) AS {window_alias}")
        elif wtype == "running_total":
            if not metrics:
                raise PlanError("running_total requires at least one metric.")
            metric_expr = list(alias_lookup.values())[0]
            window_alias = "running_total"
            select_parts.append(
                f"SUM({metric_expr}) OVER ({order_sql} ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS {window_alias}"
            )
        elif wtype == "moving_average":
            if not metrics:
                raise PlanError("moving_average requires at least one metric.")
            size = int(window.get("window_size") or 3)
            metric_expr = list(alias_lookup.values())[0]
            window_alias = "moving_avg"
            select_parts.append(
                f"AVG({metric_expr}) OVER ({order_sql} ROWS BETWEEN {max(size - 1, 0)} PRECEDING AND CURRENT ROW) AS {window_alias}"
            )

    where_sql = ""
    if filters:
        clauses = [_build_filter_clause(f, resolvable_columns, source) for f in filters]
        where_sql = "WHERE " + " AND ".join(clauses)

    group_sql = f"GROUP BY {', '.join(_quote_ident(c) for c in group_by)}" if group_by and metrics else ""

    inner_sql = f"SELECT {', '.join(select_parts)} FROM {source} {where_sql} {group_sql}".strip()

    sql = inner_sql
    if keep_top_n_per_partition:
        if not window_alias:
            raise PlanError("keep_top_n_per_partition requires a window (rank/dense_rank) to filter on.")
        sql = f"SELECT * FROM ({inner_sql}) t WHERE {window_alias} <= {int(keep_top_n_per_partition)}"

    outer_order_clauses = []
    for o in order_by:
        oc = str(o.get("column", ""))
        direction = "DESC" if (o.get("direction") or "desc").lower() == "desc" else "ASC"
        if oc.lower() in alias_lookup:
            ref = _quote_ident(re.sub(r"\W+", "_", oc.strip().lower()).strip("_"))
        elif window_alias and oc.lower() == window_alias:
            ref = _quote_ident(window_alias)
        else:
            ref = _quote_ident(_resolve_column(oc, resolvable_columns))
        outer_order_clauses.append(f"{ref} {direction}")

    if outer_order_clauses:
        sql += f" ORDER BY {', '.join(outer_order_clauses)}"

    if limit:
        sql += f" LIMIT {int(limit)}"

    return sql


# ── Router agent call ─────────────────────────────────────────────────────────

async def _run_router_agent(user_text: str, available_columns: list) -> dict:
    agent = LlmAgent(
        name="query_router_agent",
        model=MODEL,
        instruction=ROUTER_SYSTEM_INSTRUCTION,
        description="Routes a request to SQL or a spreadsheet operation, planning the SQL structurally.",
    )

    app_name = "query_router_app"
    user_id = "api_user"
    session_id = str(uuid.uuid4())

    session_service = InMemorySessionService()
    await session_service.create_session(app_name=app_name, user_id=user_id, session_id=session_id)
    runner = Runner(agent=agent, app_name=app_name, session_service=session_service)

    prompt = (
        f"Available columns: {json.dumps(available_columns)}\n"
        f"User request: {user_text}"
    )
    content = types.Content(role="user", parts=[types.Part(text=prompt)])

    final_text = None
    async for event in runner.run_async(user_id=user_id, session_id=session_id, new_message=content):
        if event.is_final_response() and event.content and event.content.parts:
            for part in event.content.parts:
                if getattr(part, "text", None):
                    final_text = part.text

    print(f"[query_router] raw model output: {final_text!r}")

    if not final_text:
        return {"route": "operation", "plan": None, "confidence": 0.0,
                "message": "No response from the router agent."}

    try:
        cleaned = _extract_json(final_text)
        return json.loads(cleaned)
    except json.JSONDecodeError as e:
        print(f"[query_router] JSON parse failed: {e}. Cleaned text was: {cleaned!r}")
        return {"route": "operation", "plan": None, "confidence": 0.0,
                "message": "Could not parse the router's response as JSON."}


# ── SQL execution ──────────────────────────────────────────────────────────────

def _execute_sql(sql: str, df: pd.DataFrame, table_name: str = TABLE_NAME) -> dict:
    con = duckdb.connect(database=":memory:")
    try:
        con.register(table_name, df)
        result_df = con.execute(sql).df()
        result_df = result_df.where(pd.notnull(result_df), None)
        return {
            "columns": list(result_df.columns),
            "rows": result_df.to_dict(orient="records"),
            "row_count": len(result_df),
        }
    finally:
        con.close()


# ── Main entry point ───────────────────────────────────────────────────────────

async def handle_smart_query(
    user_text: str,
    df: pd.DataFrame,
    available_sheets: list | None = None,
) -> dict:
    """Decides SQL vs spreadsheet-operation for a natural-language request.
    For "sql", the LLM only produces a structured plan; build_sql_from_plan
    (pure Python, no LLM) turns that into the actual query against whichever
    dataset is currently loaded — so the same plan format works regardless
    of what columns the dataset happens to have.
    """
    available_columns = list(df.columns)
    available_sheets = available_sheets or []

    try:
        decision = await _run_router_agent(user_text, available_columns)
    except Exception:
        print("[query_router] EXCEPTION during routing:")
        traceback.print_exc()
        return {
            "route": "unknown",
            "success": False,
            "message": "Internal error while routing the query — check server logs.",
        }

    route = decision.get("route")
    confidence = decision.get("confidence", 0.0)
    message = decision.get("message", "")

    if route == "sql":
        plan = decision.get("plan")
        try:
            sql = build_sql_from_plan(plan, available_columns)
        except PlanError as e:
            return {
                "route": "sql",
                "success": False,
                "confidence": confidence,
                "plan": plan,
                "message": f"Could not build a valid query from the plan: {e}",
            }
        try:
            result = _execute_sql(sql, df)
        except Exception as e:
            print("[query_router] EXCEPTION during SQL execution:")
            traceback.print_exc()
            return {
                "route": "sql",
                "success": False,
                "confidence": confidence,
                "plan": plan,
                "sql": sql,
                "message": f"SQL execution failed: {e}",
            }
        return {
            "route": "sql",
            "success": True,
            "confidence": confidence,
            "plan": plan,
            "sql": sql,
            "message": message,
            "result": result,
        }

    # route == "operation" (also the default fallback for anything unexpected)
    try:
        op_result = await parse_agentic_command(user_text, available_columns, available_sheets)
    except Exception as e:
        print("[query_router] EXCEPTION during operation parsing:")
        traceback.print_exc()
        return {
            "route": "operation",
            "success": False,
            "confidence": confidence,
            "message": f"Operation parsing failed: {e}",
        }

    return {
        "route": "operation",
        "success": True,
        "confidence": confidence,
        "message": message,
        "operation": op_result,
    }
