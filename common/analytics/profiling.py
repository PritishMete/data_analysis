"""Shared dataset-profiling engine.

Moved out of main.py so it has a single home that both the Excel adapter
(main.py) and the Power BI adapter (powerbi_routes.py) import FROM, rather
than one importing it from the other. That previous shape --
powerbi_routes.py doing `from main import analyze_dataframe` while main.py
does `from powerbi_routes import router` -- is a circular dependency:
main.py -> powerbi_routes.py -> main.py. Python tolerated it here only
because of import ORDER (main.py defines analyze_dataframe before its
bottom-of-file `from powerbi_routes import router`), which is fragile and
not a real fix. The correct dependency direction is:

    common/analytics/profiling.py  (shared engine, depends on nothing app-specific)
            ^                                         ^
            |                                         |
        main.py                              powerbi_routes.py

Neither adapter imports the other.
"""
from __future__ import annotations

import pandas as pd


def analyze_dataframe(df: pd.DataFrame):
    """Structured statistics only — for other modules to consume, not for
    end-user narration. Every value below comes from the exact same pandas
    calls this function always made (df.describe(include='all'),
    isnull().sum(), nunique(), duplicated().sum()); this refactor only
    changes how those already-computed numbers are GROUPED in the returned
    dict, not what's computed. No business insight or recommendation is
    generated here — see common/insights/recommendation_engine.py for
    that, which is a deliberately separate concern this function knows
    nothing about.

    Grouped shape (exactly these seven top-level keys):
        summary               rows / columns / column_names
        distribution          per-column unique-value counts
        quality               a rollup view combining duplicate_rows and
                               missing_values — the same two values as the
                               "duplicates"/"missing_values" keys below,
                               just re-referenced together for a caller
                               that wants one overall quality signal
                               instead of two separate lookups
        duplicates             duplicate row count
        missing_values         per-column missing-value counts
        numeric_statistics      df.describe() output, numeric columns only
        categorical_statistics  df.describe() output, non-numeric columns only

    Raw row previews/samples and the df.info() text blob are deliberately
    NOT part of this output anymore — they're actual data, or free text,
    neither of which is a "structured metric".
    """
    try:
        describe_df = df.describe(include="all")
    except Exception:
        describe_df = pd.DataFrame()

    numeric_columns = df.select_dtypes(include="number").columns.tolist()
    categorical_columns = [c for c in df.columns if c not in numeric_columns]

    numeric_statistics = (
        describe_df[numeric_columns].fillna("").to_dict()
        if numeric_columns and not describe_df.empty
        else {}
    )
    categorical_statistics = (
        describe_df[categorical_columns].fillna("").to_dict()
        if categorical_columns and not describe_df.empty
        else {}
    )

    missing_values = {
        col: int(df[col].isnull().sum())
        for col in df.columns
    }
    unique_values = {
        col: int(df[col].nunique())
        for col in df.columns
    }
    duplicate_count = int(df.duplicated().sum())

    # -- Raw row previews/sample/describe (restored) -------------------------
    # These were dropped in the grouped-stats refactor above under the
    # reasoning that they're "actual data, or free text, neither of which is
    # a structured metric" -- but the Flutter client's PreviewTables and
    # DescribeMatrix widgets (lib/features/analysis/widgets/preview_tables.dart,
    # describe_matrix.dart) read these three keys directly off the /analyze
    # response and have never been migrated off them. Restoring them here
    # rather than migrating those widgets, since this is the smaller/safer
    # diff and doesn't touch the grouped summary/distribution/quality shape
    # that quality_report.dart and overview_metrics.dart already depend on.
    preview = df.head(15).fillna("").to_dict(orient="records")
    sample = (
        df.sample(min(10, len(df))).fillna("").to_dict(orient="records")
        if len(df) > 0 else []
    )
    describe_records = (
        describe_df.fillna("").reset_index().to_dict(orient="records")
        if not describe_df.empty else []
    )

    return {
        "summary": {
            "rows": int(df.shape[0]),
            "columns": int(df.shape[1]),
            "column_names": list(df.columns),
            # Per-column pandas dtypes as plain strings (e.g. "int64",
            # "float64", "object", "datetime64[ns]", "bool").
            # df.dtypes.astype(str) is the canonical way to serialise the
            # dtype Index as plain strings without special NumPy types.
            # Placed inside "summary" so it follows the existing grouped
            # shape that quality_report.dart / overview_metrics.dart depend on.
            "dtypes": df.dtypes.astype(str).to_dict(),
        },
        "distribution": {
            "unique_values": unique_values,
        },
        "quality": {
            "duplicate_rows": duplicate_count,
            "missing_values": missing_values,
        },
        "duplicates": {
            "count": duplicate_count,
        },
        "missing_values": missing_values,
        "numeric_statistics": numeric_statistics,
        "categorical_statistics": categorical_statistics,
        # Legacy flat fields -- required by preview_tables.dart / describe_matrix.dart.
        "preview": preview,
        "sample": sample,
        "describe": describe_records,
    }
