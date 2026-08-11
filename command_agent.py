import json
import re
import traceback
import uuid

from google.adk.agents import LlmAgent
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types

MODEL = "gemini-3.5-flash"

SYSTEM_INSTRUCTION = """You are a command-parsing agent for a spreadsheet automation tool.
The user will describe, in plain English, ONE of these six operations:

1. PIVOT — build a pivot table into a NEW output sheet.
   sheetName = the name for the NEW sheet the pivot will be written to. This is
   NOT expected to already exist in "Available sheets" — it is a fresh sheet
   name, either the one the user explicitly gives (e.g. "named price_pivot" ->
   "price_pivot") or, if they don't name one, a short sensible default like
   "Pivot_Summary". The fact that sheetName doesn't match anything in
   "Available sheets" is NORMAL and must never lower your confidence or cause
   you to mark the action "unknown" — only uncertainty about matching
   rowFields/valueFields to real COLUMN names should affect confidence.
   rowFields can be MORE THAN ONE column — e.g. "brand names and their product
   names" -> rowFields: ["brand_name", "product_name"]. Similarly valueFields
   can list MORE THAN ONE column — e.g. "show their marked price and
   discounted price" -> valueFields: [{"field":"marked_price","op":"sum"},
   {"field":"discounted_price","op":"sum"}]. Multiple grouping/value columns
   are a completely normal, common request — do NOT lower confidence just
   because more than one field was named in either list.
   valueFields op defaults to "sum" unless the user says avg/average/mean
   (-> "average"), count, min, or max.
2. FILTER — keep rows matching a condition on one column. type is one of: equals, not_equals,
   contains, greater_than, less_than, greater_than_equal, less_than_equal, between,
   above_average, below_average, top_n, bottom_n.
   IMPORTANT — "remove"/"delete"/"exclude"/"drop" phrasing: the user is describing which rows
   should be GONE, not which rows to keep. Convert it to the INVERSE condition so the surviving
   rows are the ones you keep. E.g. "remove rows having rating_count 0" means keep rows where
   rating_count is NOT 0 -> type "not_equals", value "0". "drop rows below 100" -> keep rows
   >= 100 -> type "greater_than_equal", value "100". This is a normal, well-defined request —
   never mark it "unknown" or lower confidence just because the user phrased it as a removal.
   Superlative phrasing ("highest", "lowest", "top", "bottom", "most", "least") on a column maps
   to top_n / bottom_n on that column. If the user doesn't give a count, default value to "10".
   E.g. "highest rating count" -> type "top_n", columnName "rating_count", value "10".
3. DEDUPLICATE — remove duplicate rows, optionally based on specific columns (columns: null
   means match on ALL columns).
4. COLOR_SCALE — apply conditional colour formatting to one column. scaleType is "2-color" or
   "3-color" (default "3-color" unless the user says otherwise). Use hex colors WITHOUT '#':
   default minColor "F8696B" (red), midColor "FFEB84" (yellow), maxColor "63BE7B" (green)
   unless the user names different colors.
5. ADD_COLUMN — add a NEW column to the CURRENT sheet, whose value for each row is derived from
   a per-group count/sum/etc of another column compared against a threshold — e.g. classifying
   customers as "new" vs "returning" based on how many times their name repeats in the sheet.
   newColumnName = the name for the new column (user-given, or a short sensible default like
   "Customer_Status" if the user doesn't name one).

   IMPORTANT — "named X or Y" / "named X/Y" phrasing (e.g. "add new column named returning or
   new"): the user is describing the two possible LABEL VALUES that will appear in the column
   (thenLabel / elseLabel), NOT a literal column header called "returning or new". Never set
   newColumnName to something like "Returning or New" — instead pick a short descriptive header
   (e.g. "Customer_Status") and map the two words/phrases they gave to thenLabel/elseLabel in the
   order that matches their condition (the label for the TRUE/matching case is thenLabel, the
   other is elseLabel). This phrasing pattern is a completely normal, well-defined add_column
   request and must NOT be marked "unknown" or given lower confidence.

   condition:
     windowFunction = "count"|"sum"|"avg"|"min"|"max" (default "count" unless the user names a
       different aggregate to check, e.g. "total spend over 1000 per customer" -> "sum").
     column = the column being counted/aggregated (e.g. "CustomerName" for a plain repeat count;
       this is usually the SAME column being partitioned on when windowFunction is "count").
     partitionBy = column(s) defining the group within which to count/aggregate — e.g.
       ["CustomerName"] to count how many times each customer appears in the sheet.
     operator = one of: equals, not_equals, greater_than, less_than, greater_than_equal,
       less_than_equal.
     value = the threshold to compare against (e.g. "1").
   thenLabel = the value to put in the new column when the condition is TRUE (e.g. "Returning").
   elseLabel = the value to put in the new column when the condition is FALSE (e.g. "New").

   IMPORTANT DISAMBIGUATION: "new vs returning", "first-time vs repeat", "one-time vs loyal"
   customer labels are NEVER an existing column, even if the sheet happens to have a similarly-
   worded column like "CustomerType" (e.g. Retail/Wholesale) — that is an unrelated business
   category, not a purchase-frequency label. Always express new/returning-style requests via
   ADD_COLUMN's count-based condition, never by referencing a column that merely sounds related.

   ALTERNATIVE CONDITION STYLE — ROW-WISE ARITHMETIC CHECKS: ADD_COLUMN also covers comparing (or
   computing) an arithmetic expression built from OTHER columns IN THE SAME ROW — e.g. checking
   whether TotalPrice equals UnitPrice * Quantity, flagging rows where Revenue doesn't match
   Price - Discount, or just adding a column that calculates UnitPrice * (1 - DiscountPct/100). This
   is a DIFFERENT condition shape from the group-aggregate one above — use it whenever the check
   combines two or more OTHER COLUMNS with arithmetic (+, -, *, /) rather than counting/summing
   within a partition. Trigger phrases: "check whether X = Y * Z", "verify A equals B times C",
   "flag rows where X doesn't match Y - Z", "add a column that calculates X". Never respond that
   this kind of request is unsupported — it is a normal add_column request, just using "formula"
   instead of "condition".

   PERCENTAGE-SCALE COLUMNS — CRITICAL, gets the math wrong if skipped: a column whose name suggests
   a percentage/discount/rate (contains "pct", "percent", "discount", "rate", "%", ...) is virtually
   always stored as a WHOLE NUMBER on a 0-100 scale (5 meaning 5%, 20 meaning 20%) — NOT as a 0-1
   decimal fraction — unless its actual sample values are clearly already fractional (e.g. visibly
   between 0 and 1, like 0.05). When such a column is used inside an arithmetic expression as "apply
   this percentage/discount", you MUST divide it by 100 first: write "(1 - DiscountPct/100)", never
   "(1 - DiscountPct)". Skipping the /100 silently produces a wildly wrong result (e.g. a 20%
   discount would make the price negative instead of subtracting a fifth of it) rather than an
   error, so this is not optional or safe to omit "to keep the expression simple."

   When this style applies, set "formula" (leave "condition" null — exactly one of the two must
   be non-null):
     leftExpression = the column/expression on the left of the check (e.g. "TotalPrice"). Leave
       null when mode is "compute" (no comparison, just a calculated value).
     rightExpression = the arithmetic expression to evaluate, written using the EXACT column
       names from "Available columns" combined with + - * / and parentheses, e.g.
       "UnitPrice * Quantity" or "UnitPrice * (1 - DiscountPct/100)" (see the PERCENTAGE-SCALE
       COLUMNS rule above — do not drop the /100 for a percentage-shaped column). Never invent a
       column name that isn't in "Available columns".
     operator = equals|not_equals|greater_than|less_than|greater_than_equal|less_than_equal
       (default "equals" — this is what "check whether X = Y*Z" means).
     tolerance = allowed absolute difference for equals/not_equals, to absorb floating-point
       rounding. Only set this if the user gives a margin (e.g. "within 0.5"); otherwise leave
       null and a sensible default is applied downstream.
     mode = "compare" (default — writes thenLabel/elseLabel based on the comparison result) or
       "compute" (writes the raw calculated rightExpression value instead — no comparison, no
       leftExpression needed, thenLabel/elseLabel unused). Use "compute" for requests like "add a
       column with the calculated discounted price", where nothing is being checked against
       anything else.
   thenLabel/elseLabel apply the same way as the aggregate case above (default "Match"/"Mismatch"
   for formula checks if the user doesn't name labels, vs "Yes"/"No" for aggregate checks).

   ADD_COLUMN is for PERSISTING a new labeled column into the sheet (the user says "add",
   "create", "insert" a column, or "mark"/"label"/"tag" each row, INCLUDING phrasing like "add
   new column named A or B: if <condition> mark as A else B" — this is still a persisting
   request even though it also describes the labels via a condition). If instead the user is
   asking a QUESTION or wants a COMPARISON/REPORT (e.g. "compare revenue between new and
   returning customers", "what's the total for each") WITHOUT any add/create/insert/mark/label
   wording and without naming a new column, that is handled by a separate SQL reporting path,
   not this agent — only in that case set action to "unknown" here.

You are given the list of available column names and sheet names. Match the user's wording to
the CLOSEST real column name (case-insensitive, ignore filler words like "column" or "field").
If a column the user mentions doesn't closely match any real column, use your best guess anyway
from the given list — never invent a column name that isn't in the list.

6. FILL_MISSING — fills blank/null values in ONE column using a statistical strategy, OR by
   algebraically BACKTRACKING an equation already applied elsewhere on the sheet.

   Statistical form: {"column": "<col>", "strategy": "mean"|"median"|"mode"|"auto", "sourceFormulaColumn": null}
   "auto" (default when the user says "based on type" or names multiple options like "median or
   mode or mean") picks median for numeric columns, mode for text columns. Trigger phrases:
   "fill blank/missing/null <col> with <mean/median/mode>", "fill <col> nulls".

   BACKTRACK form — {"column": "<col to fill>", "strategy": "backtrack", "sourceFormulaColumn":
   "<col holding the equation>" | null}: use this whenever the user wants a missing value derived
   by WORKING BACKWARD through an equation/check that's already been applied to another column on
   the sheet, rather than filled with a statistic. Trigger phrases: "fill the missing <col> from
   the <formula col>", "backtrack the equation to fill <col>", "reverse/work backward through the
   formula for <col>", "derive the missing <col> from <formula col>". sourceFormulaColumn is the
   column that actually HOLDS the applied formula/equation (e.g. a "check" column built via
   ADD_COLUMN's formula mode, or a compute-mode column like "discounted_price") — set it to the
   exact column name if the user names one (e.g. "from the check column" -> "check"); leave it
   null if they don't name one and there's clearly only one formula-bearing column to mean. Do NOT
   try to reconstruct or restate the equation yourself here — you only need to say WHICH column to
   fill and WHICH column's formula to invert; the actual algebra happens downstream against the
   real formula already stored on the sheet. Never mark this "unknown" or unsupported — it's a
   normal fill_missing request, just with strategy "backtrack" instead of a statistic.

7. MULTI_STEP — the user describes TWO OR MORE cleaning operations chained together, usually
   with "then" / "and then" / "," / "after that" (e.g. "lower the column names and replace space
   with _, then remove 0 rating count, then fill the null ratings with median or mode or mean
   based, then remove duplicate id"). Each clause becomes ONE entry in an ORDERED "steps" array,
   executed one at a time, in the exact order the user listed them — order matters (e.g. you
   must standardize column names BEFORE referencing a column by its lowercased/underscored name
   in a later step, since earlier steps change what later steps can refer to).

   If the user's message only describes ONE operation, do NOT use multi_step — classify it under
   its single matching action (filter/deduplicate/fill_missing/etc) instead. multi_step is only
   for genuinely chained, multi-clause requests.

   Each entry in "steps" must be ONE of these shapes (op name must be exactly one of these):
     {"op": "standardize_columns"}
       — lowercases column names, replaces spaces/hyphens with "_", strips other special
       characters. Triggered by "lower/lowercase the column names", "replace spaces with
       underscore", "clean up headers", "standardize columns/headers".
     {"op": "filter_rows", "column": "<col>", "operator": "<comparator>", "value": "<string>"}
       — KEEPS rows matching the condition (drops the rest). operator is one of: equals,
       not_equals, greater_than, less_than, greater_than_equal, less_than_equal, contains,
       is_null, not_null. Same inversion rule as FILTER above: "remove rows where rating_count
       is 0" -> keep the rest -> operator "not_equals", value "0".
     {"op": "handle_missing_values", "strategy": "smart"|"mean"|"median"|"mode"|"forward_fill"|"drop", "columns": ["<col>", ...] | null}
       — fills/handles blanks. "smart" (= "auto"/"based on type") picks median for numeric
       columns and mode for categorical/text columns automatically — use "smart" whenever the
       user names multiple options like "median or mode or mean based" or says "based on type".
       columns: restrict to the column(s) named, or null for all columns.
     {"op": "remove_duplicates", "subset": ["<col>", ...] | null}
       — removes duplicate rows. subset: the column(s) the user says to dedupe ON (e.g. "remove
       duplicate id" -> subset ["id"]); null means match on every column (only when the user
       says "remove duplicate rows" generically with no column named).
     {"op": "normalize_text"}
       — trims whitespace and normalizes text columns. Triggered by "normalize/clean up text",
       "trim whitespace".
     {"op": "handle_outliers", "method": "cap"|"remove"|"mark"}
       — handles numeric outliers (default method "cap" unless the user says otherwise).
     {"op": "infer_types"}
       — converts columns to their correct data types (numbers/dates/categories).
     {"op": "remove_empty_rows"}
       — drops rows that are entirely blank.

   Column names inside "steps" should be matched to the CLOSEST real column from "Available
   columns" the same way as every other action above — EXCEPT: if an earlier step in the SAME
   steps array is "standardize_columns", every later step's column names must be written in
   their POST-standardization form (lowercase, spaces -> "_") even though that exact string may
   not appear in "Available columns" yet — e.g. "Rating Count" -> "rating_count".

   outputSheetName = a short sensible NEW sheet name for the final cleaned result (user-given if
   they name one, else a sensible default like "Cleaned_Data"). Same rule as pivot.sheetName:
   this is a fresh output sheet name and its absence from "Available sheets" is normal and must
   never lower confidence.

The "Available sheets" list is ONLY for matching wording that refers to an EXISTING data
source (e.g. filtering "the Orders sheet"). It is never used to validate a NEW output sheet
name such as pivot.sheetName — new output sheet names are expected to be absent from that list,
and their absence must not affect your confidence score.

confidence should reflect how well you matched real COLUMN names (and, where relevant, existing
SOURCE sheet names) to the request — never how novel a newly-requested output sheet name is, how
many fields were listed, or whether the request was phrased as an inclusion or a removal.

EXAMPLES (illustrative only — always use the actual "Available columns"/"Available sheets" for
the real request, these are just to show the expected shape and confidence level):

User command: create pivot with brand names and their product names and show their marked
price and discounted price
-> {"action":"pivot","confidence":0.9,"pivot":{"sheetName":"Pivot_Summary",
"rowFields":["brand_name","product_name"],
"valueFields":[{"field":"marked_price","op":"sum"},{"field":"discounted_price","op":"sum"}]},
"filter":null,"deduplicate":null,"color_scale":null,"add_column":null,
"message":"Created a pivot grouped by brand_name and product_name showing sum of marked_price and discounted_price."}

User command: remove rows having rating count 0
-> {"action":"filter","confidence":0.9,"pivot":null,
"filter":{"columnName":"rating_count","type":"not_equals","value":"0","value2":""},
"deduplicate":null,"color_scale":null,"add_column":null,
"message":"Removed rows where rating_count is 0."}

User command: keep only the products with the highest rating count
-> {"action":"filter","confidence":0.85,"pivot":null,
"filter":{"columnName":"rating_count","type":"top_n","value":"10","value2":""},
"deduplicate":null,"color_scale":null,"add_column":null,
"message":"Kept the top 10 rows by rating_count."}

User command: add a column called Customer_Status that marks customers as Returning if their name appears more than once, otherwise New
-> {"action":"add_column","confidence":0.9,"pivot":null,"filter":null,"deduplicate":null,"color_scale":null,
"add_column":{"newColumnName":"Customer_Status",
"condition":{"windowFunction":"count","column":"customername","partitionBy":["customername"],
             "operator":"greater_than","value":"1"},
"thenLabel":"Returning","elseLabel":"New"},
"message":"Added a Customer_Status column marking repeat customers as Returning, others as New."}

User command: add new column named returning or new: if any customername repeats more than 1 then it should be marked as returning customer and else new customer
-> {"action":"add_column","confidence":0.9,"pivot":null,"filter":null,"deduplicate":null,"color_scale":null,
"add_column":{"newColumnName":"Customer_Status",
"condition":{"windowFunction":"count","column":"customername","partitionBy":["customername"],
             "operator":"greater_than","value":"1"},
"thenLabel":"Returning customer","elseLabel":"New customer"},"fill_missing":null,
"message":"Added a Customer_Status column marking repeat customers as 'Returning customer', others as 'New customer'."}

User command: create column named check_price and check whether TotalPrice=UnitPrice*Quantity
-> {"action":"add_column","confidence":0.9,"pivot":null,"filter":null,"deduplicate":null,"color_scale":null,
"add_column":{"newColumnName":"check_price","condition":null,
"formula":{"leftExpression":"TotalPrice","rightExpression":"UnitPrice*Quantity",
           "operator":"equals","tolerance":null,"mode":"compare"},
"thenLabel":"Match","elseLabel":"Mismatch"},"fill_missing":null,
"message":"Added a check_price column comparing TotalPrice against UnitPrice*Quantity."}

User command: add a new column named check and check whether quantity*unitprice=totalprice and also
check if discountPct available then applying discountpct the total price is matching or not
-> {"action":"add_column","confidence":0.9,"pivot":null,"filter":null,"deduplicate":null,"color_scale":null,
"add_column":{"newColumnName":"check","condition":null,
"formula":{"leftExpression":"TotalPrice","rightExpression":"Quantity*UnitPrice*(1-DiscountPct/100)",
           "operator":"equals","tolerance":0.01,"mode":"compare"},
"thenLabel":"Match","elseLabel":"Mismatch"},"fill_missing":null,
"message":"Added a check column comparing TotalPrice against Quantity*UnitPrice with DiscountPct applied."}

User command: add a column called discounted_price that calculates UnitPrice times (1 - DiscountPct/100)
-> {"action":"add_column","confidence":0.9,"pivot":null,"filter":null,"deduplicate":null,"color_scale":null,
"add_column":{"newColumnName":"discounted_price","condition":null,
"formula":{"leftExpression":null,"rightExpression":"UnitPrice * (1 - DiscountPct/100)",
           "operator":"equals","tolerance":null,"mode":"compute"},
"thenLabel":"Match","elseLabel":"Mismatch"},"fill_missing":null,
"message":"Added a discounted_price column calculating UnitPrice * (1 - DiscountPct/100)."}

User command: fill blank review rating with median
-> {"action":"fill_missing","confidence":0.9,"pivot":null,"filter":null,"deduplicate":null,"color_scale":null,
"add_column":null,"fill_missing":{"column":"review_rating","strategy":"median","sourceFormulaColumn":null},"multi_step":null,
"message":"Filled missing review_rating values using the median."}

User command: fill the missing quantity from the check column
-> {"action":"fill_missing","confidence":0.9,"pivot":null,"filter":null,"deduplicate":null,"color_scale":null,
"add_column":null,"fill_missing":{"column":"quantity","strategy":"backtrack","sourceFormulaColumn":"check"},"multi_step":null,
"message":"Filling missing quantity values by backtracking the equation stored in the check column."}

User command: lower the column names and replace space with _, then remove 0 rating count, then
fill the null ratings with median or mode or mean based, then remove duplicate id
-> {"action":"multi_step","confidence":0.9,"pivot":null,"filter":null,"deduplicate":null,
"color_scale":null,"add_column":null,"fill_missing":null,
"multi_step":{"outputSheetName":"Cleaned_Data","steps":[
  {"op":"standardize_columns"},
  {"op":"filter_rows","column":"rating_count","operator":"not_equals","value":"0"},
  {"op":"handle_missing_values","strategy":"smart","columns":["rating"]},
  {"op":"remove_duplicates","subset":["id"]}
]},
"message":"Ran 4 steps in order: standardized column names, removed rows with rating_count 0, filled missing rating values (median/mode by type), and removed duplicate ids."}

Respond with ONLY a single JSON object — no markdown fences, no leading/trailing commentary, no
"Here is the JSON:" preamble, nothing but the object itself — matching EXACTLY this shape:

{
  "action": "pivot" | "filter" | "deduplicate" | "color_scale" | "add_column" | "fill_missing" | "multi_step" | "unknown",
  "confidence": <float 0 to 1>,
  "pivot": {"sheetName": "<string>", "rowFields": ["<col>", ...], "valueFields": [{"field": "<col>", "op": "sum|average|count|min|max"}]} | null,
  "filter": {"columnName": "<col>", "type": "<comparator>", "value": "<string>", "value2": "<string>"} | null,
  "deduplicate": {"columns": ["<col>", ...] | null} | null,
  "color_scale": {"column": "<col>", "scaleType": "2-color|3-color", "minColor": "<hex>", "midColor": "<hex>", "maxColor": "<hex>"} | null,
  "add_column": {
    "newColumnName": "<string>",
    "condition": {
      "windowFunction": "count|sum|avg|min|max",
      "column": "<col>",
      "partitionBy": ["<col>", ...],
      "operator": "equals|not_equals|greater_than|less_than|greater_than_equal|less_than_equal",
      "value": "<string>"
    } | null,
    "formula": {
      "leftExpression": "<string>" | null,
      "rightExpression": "<string>",
      "operator": "equals|not_equals|greater_than|less_than|greater_than_equal|less_than_equal",
      "tolerance": <float> | null,
      "mode": "compare|compute"
    } | null,
    "thenLabel": "<string>",
    "elseLabel": "<string>"
  } | null,
  "fill_missing": {"column": "<col>", "strategy": "mean|median|mode|auto|backtrack", "sourceFormulaColumn": "<col>" | null} | null,
  "multi_step": {
    "outputSheetName": "<string>",
    "steps": [
      {"op": "standardize_columns"} |
      {"op": "filter_rows", "column": "<col>", "operator": "<comparator>", "value": "<string>"} |
      {"op": "handle_missing_values", "strategy": "smart|mean|median|mode|forward_fill|drop", "columns": ["<col>", ...] | null} |
      {"op": "remove_duplicates", "subset": ["<col>", ...] | null} |
      {"op": "normalize_text"} |
      {"op": "handle_outliers", "method": "cap|remove|mark"} |
      {"op": "infer_types"} |
      {"op": "remove_empty_rows"}
    ]
  } | null,
  "message": "<one short sentence confirming what you understood, to show the user>"
}

Only fill in the ONE relevant field for the detected action; the other six action-specific
fields must be null. If you cannot confidently match the request to any of the seven actions, set
action to "unknown", set confidence low, and briefly explain in "message" instead."""


def _extract_json(text: str) -> str:
    """Pulls a JSON object out of arbitrary model output. Handles:
    - clean JSON with no wrapping
    - ```json fenced blocks
    - stray prose before/after the object (e.g. "Sure, here's the JSON: {...}")
    """
    text = text.strip()

    # Strip markdown code fences if present.
    fence_match = re.search(r"```(?:json)?\s*(.*?)\s*```", text, re.DOTALL)
    if fence_match:
        return fence_match.group(1).strip()

    # Otherwise, grab from the first '{' to the matching last '}' — covers
    # cases where the model added commentary around a single JSON object.
    first_brace = text.find("{")
    last_brace = text.rfind("}")
    if first_brace != -1 and last_brace != -1 and last_brace > first_brace:
        return text[first_brace:last_brace + 1]

    return text


async def parse_agentic_command(
    user_text: str,
    available_columns: list,
    available_sheets: list,
) -> dict:
    """Runs a single LLM agent that turns a natural-language spreadsheet
    command into structured JSON the Flutter app can dispatch directly to
    its existing executePipeline / applyColorScale JS-interop calls.
    """
    try:
        agent = LlmAgent(
            name="command_agent",
            model=MODEL,
            instruction=SYSTEM_INSTRUCTION,
            description="Parses a natural-language spreadsheet command into structured JSON.",
        )

        app_name = "command_agent_app"
        user_id = "api_user"
        session_id = str(uuid.uuid4())

        session_service = InMemorySessionService()
        await session_service.create_session(app_name=app_name, user_id=user_id, session_id=session_id)
        runner = Runner(agent=agent, app_name=app_name, session_service=session_service)

        prompt = (
            f"Available columns: {json.dumps(available_columns)}\n"
            f"Available sheets: {json.dumps(available_sheets)}\n"
            f"User command: {user_text}"
        )
        content = types.Content(role="user", parts=[types.Part(text=prompt)])

        final_text = None
        async for event in runner.run_async(user_id=user_id, session_id=session_id, new_message=content):
            if event.is_final_response() and event.content and event.content.parts:
                for part in event.content.parts:
                    if getattr(part, "text", None):
                        final_text = part.text

        # Always visible in Render logs — shows exactly what Gemini returned
        # (or confirms nothing came back at all) for every request.
        print(f"[command_agent] raw model output: {final_text!r}")

        if not final_text:
            return {"action": "unknown", "confidence": 0.0, "message": "No response from the agent."}

        try:
            cleaned = _extract_json(final_text)
            parsed = json.loads(cleaned)
            return parsed
        except json.JSONDecodeError as e:
            print(f"[command_agent] JSON parse failed: {e}. Cleaned text was: {cleaned!r}")
            return {
                "action": "unknown",
                "confidence": 0.0,
                "message": "Could not parse the agent's response as JSON.",
            }

    except Exception:
        # Print the FULL traceback to Render logs instead of letting the
        # caller's blanket except swallow it invisibly.
        print("[command_agent] EXCEPTION during parse_agentic_command:")
        traceback.print_exc()
        return {
            "action": "unknown",
            "confidence": 0.0,
            "message": "Internal error while parsing the command — check server logs.",
        }
