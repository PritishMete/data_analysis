"""Privacy firewall for metadata-only Gemini planner requests.

This module deliberately contains no dataframe/file handling. Planner endpoints
may send a natural-language query and schema metadata to Gemini, but they must
never accept workbook rows, cell values, file bytes, previews, or dataframes.
"""
from __future__ import annotations

import re
from typing import Any

FORBIDDEN_PAYLOAD_KEYS = {
    "rows", "data", "dataset", "dataset_rows", "records", "values", "cells",
    "preview", "sample", "samples", "csv", "file", "file_bytes", "upload",
    "workbook", "dataframe", "df", "raw_data", "raw_rows", "sheet_data",
}

EMAIL_RE = re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.I)
PHONE_RE = re.compile(r"(?<!\w)(?:\+?\d[\d\s().-]{7,}\d)(?!\w)")
URL_RE = re.compile(r"https?://\S+|www\.\S+", re.I)


def validate_metadata_planner_payload(payload: dict[str, Any], *, allow_sheets: bool = True) -> tuple[str, list[str], list[str]]:
    if not isinstance(payload, dict):
        raise ValueError("Planner payload must be a JSON object.")

    forbidden = FORBIDDEN_PAYLOAD_KEYS.intersection(payload.keys())
    if forbidden:
        raise ValueError("Dataset content is not accepted by the metadata-only planner.")

    allowed = {"text", "available_columns"} | ({"available_sheets"} if allow_sheets else set())
    unknown = set(payload.keys()) - allowed
    if unknown:
        raise ValueError("Planner payload contains unsupported fields.")

    text = payload.get("text", "")
    columns = payload.get("available_columns", [])
    sheets = payload.get("available_sheets", []) if allow_sheets else []

    if not isinstance(text, str) or not text.strip() or len(text) > 5000:
        raise ValueError("Planner query is missing or too large.")
    if not isinstance(columns, list) or len(columns) > 300 or not all(isinstance(c, str) for c in columns):
        raise ValueError("available_columns must contain at most 300 strings.")
    if allow_sheets and (not isinstance(sheets, list) or len(sheets) > 100 or not all(isinstance(s, str) for s in sheets)):
        raise ValueError("available_sheets must contain at most 100 strings.")

    # Keep ordinary user requests working, but remove obvious credentials/PII
    # patterns before they reach the model. This is a second layer; the primary
    # privacy guarantee is that workbook data is structurally unavailable here.
    safe_text = EMAIL_RE.sub("<EMAIL>", text)
    safe_text = URL_RE.sub("<URL>", safe_text)
    safe_text = PHONE_RE.sub("<PHONE>", safe_text)

    return safe_text, [str(c)[:300] for c in columns], [str(s)[:300] for s in sheets]
