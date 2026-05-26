# ai_engine.py
# ─────────────────────────────────────────────────────────────────────────────
# Intent classifier + slot extractor for Excel AI commands.
# Uses TF-IDF + Logistic Regression — no external AI API needed.
# ─────────────────────────────────────────────────────────────────────────────

import json
import re
import os
import pickle

from sklearn.pipeline import Pipeline
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression

TRAINING_DATA_PATH = "training_data.json"
MODEL_PATH         = "intent_model.pkl"


# ─── 1. Load Training Data ────────────────────────────────────────────────────

def load_training_data(path=TRAINING_DATA_PATH):
    """Load training_data.json, strip JS-style comments, return texts + intents."""
    with open(path, "r", encoding="utf-8") as f:
        raw = f.read()

    # Strip // comment lines (JSON doesn't support them natively)
    cleaned = re.sub(r"//.*", "", raw)
    data = json.loads(cleaned)

    texts   = [d["text"]   for d in data]
    intents = [d["intent"] for d in data]
    return texts, intents, data


# ─── 2. Train Model ───────────────────────────────────────────────────────────

def train_model(path=TRAINING_DATA_PATH):
    """Train TF-IDF + Logistic Regression pipeline and save to disk."""
    texts, intents, _ = load_training_data(path)

    model = Pipeline([
        ("tfidf", TfidfVectorizer(
            ngram_range=(1, 3),
            analyzer="word",
            sublinear_tf=True,
            min_df=1,
        )),
        ("clf", LogisticRegression(
            max_iter=500,
            C=5.0,
            solver="lbfgs",
            multi_class="auto",
        )),
    ])
    model.fit(texts, intents)

    with open(MODEL_PATH, "wb") as f:
        pickle.dump(model, f)

    print(f"✅ Model trained on {len(texts)} examples covering "
          f"{len(set(intents))} intents. Saved to {MODEL_PATH}.")
    return model


# ─── 3. Load Saved Model ─────────────────────────────────────────────────────

def load_model():
    """Load saved model, or train from scratch if none exists."""
    if not os.path.exists(MODEL_PATH):
        print("⚡ No saved model found — training from scratch...")
        return train_model()
    with open(MODEL_PATH, "rb") as f:
        return pickle.load(f)


# ─── 4. Slot Extraction ───────────────────────────────────────────────────────

def extract_slots(text: str) -> dict:
    """
    Pull structured parameters from free-form text using regex patterns.
    Returns a dict of any of: sheet_name, column, operation, filter_type,
    value, value2.
    """
    t = text.lower().strip()
    slots = {}

    # ── Sheet name: "called X" / "named X" / "as X" ──────────────────────────
    name_match = re.search(
        r"(?:called|named|as)\s+['\"]?([a-z][a-z0-9_ ]*?)['\"]?(?:\s|$)",
        t
    )
    if name_match:
        slots["sheet_name"] = name_match.group(1).strip().title()

    # ── Column name: "of the X column" / "of X" / "for X" / "by X" ──────────
    col_patterns = [
        r"(?:of the|of|for|in the|in|by|on)\s+['\"]?(\w+)['\"]?\s*(?:column|col)\b",
        r"(?:column|col)\s+['\"]?(\w+)['\"]?",
        r"(?:average|avg|sum|total|min|max|count|mean|minimum|maximum)\s+(?:of\s+)?(?:the\s+)?['\"]?(\w+)['\"]?",
    ]
    for pat in col_patterns:
        col_match = re.search(pat, t)
        if col_match:
            candidate = col_match.group(1).strip()
            # Skip noise words
            if candidate not in {"the", "a", "an", "this", "all", "row", "rows", "data"}:
                slots["column"] = candidate
                break

    # ── Operation ─────────────────────────────────────────────────────────────
    op_map = {
        "average": "average", "avg": "average", "mean": "average",
        "sum": "sum", "total": "sum",
        "min": "min", "minimum": "min",
        "max": "max", "maximum": "max",
        "count": "count", "how many": "count",
    }
    for keyword, op in op_map.items():
        if keyword in t:
            slots["operation"] = op
            break

    # ── Filter type ───────────────────────────────────────────────────────────
    ft_map = [
        (r"\btop\s*\d+\b",              "top_n"),
        (r"above average",              "above_average"),
        (r"below average",              "below_average"),
        (r"between",                    "between"),
        (r"greater than or equal|>=",   "greater_than_equal"),
        (r"less than or equal|<=",      "less_than_equal"),
        (r"greater than|>",             "greater_than"),
        (r"less than|<",                "less_than"),
        (r"does not equal|not equal|!=","not_equals"),
        (r"contains",                   "contains"),
        (r"\bequals?\b",                "equals"),
    ]
    for pat, ft in ft_map:
        if re.search(pat, t):
            slots["filter_type"] = ft
            break

    # ── Numeric values ────────────────────────────────────────────────────────
    nums = re.findall(r"\b\d+(?:\.\d+)?\b", t)
    if nums:
        slots["value"] = nums[0]
        if len(nums) > 1:
            slots["value2"] = nums[1]

    return slots


# ─── 5. Public: Parse a Command ──────────────────────────────────────────────

_model = None  # lazy-loaded singleton

def parse_command(text: str) -> dict:
    """
    Classify intent and extract slots from a natural-language command.

    Returns:
        {
            "intent": str,
            "confidence": float,   # 0.0 – 1.0
            "slots": dict,
        }
    """
    global _model
    if _model is None:
        _model = load_model()

    intent     = _model.predict([text])[0]
    confidence = float(_model.predict_proba([text]).max())
    slots      = extract_slots(text)

    return {
        "intent":     intent,
        "confidence": round(confidence, 3),
        "slots":      slots,
    }


def add_training_example(text: str, intent: str, slots: dict = None,
                          path: str = TRAINING_DATA_PATH):
    """Append a new labelled example and retrain the model immediately."""
    with open(path, "r", encoding="utf-8") as f:
        raw = re.sub(r"//.*", "", f.read())
    data = json.loads(raw)

    data.append({"text": text, "intent": intent, "slots": slots or {}})

    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)

    retrain_result = train_model(path)
    global _model
    _model = retrain_result
    return len(data)