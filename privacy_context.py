"""Compatibility helpers for AI context. Privacy/anonymization mode removed."""

from typing import Any
import pandas as pd

PRIVACY_MODE = "off"

def strict_enabled() -> bool:
    return False

def safe_columns(columns):
    return list(columns)

def sanitize_user_text(text: str) -> str:
    return str(text or "")

def remap_plan(plan):
    return plan

def value_aliases(df: pd.DataFrame):
    return {}

def dataframe_profile(df: pd.DataFrame, include_samples: bool = True) -> dict:
    profile = {"columns": list(df.columns), "row_count": int(len(df)), "dtypes": {str(c): str(df[c].dtype) for c in df.columns}}
    if include_samples:
        profile["samples"] = {str(c): df[c].dropna().astype(str).head(5).tolist() for c in df.columns}
    return profile
