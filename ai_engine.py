# ai_engine.py
import json
import re
import os
import pickle

from sklearn.pipeline import Pipeline
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression

# Use /tmp on Render (always writable)
TRAINING_DATA_PATH = "training_data.json"
MODEL_PATH         = "/tmp/intent_model.pkl"


def load_training_data(path=TRAINING_DATA_PATH):
    with open(path, "r", encoding="utf-8") as f:
        raw = f.read()
    cleaned = re.sub(r"//.*", "", raw)
    data = json.loads(cleaned)
    texts   = [d["text"]   for d in data]
    intents = [d["intent"] for d in data]
    return texts, intents, data


def train_model(path=TRAINING_DATA_PATH):
    texts, intents, _ = load_training_data(path)
    model = Pipeline([
        ("tfidf", TfidfVectorizer(ngram_range=(1, 3), analyzer="word",
                                  sublinear_tf=True, min_df=1)),
        ("clf",   LogisticRegression(max_iter=500, C=5.0, solver="lbfgs")),
    ])
    model.fit(texts, intents)
    with open(MODEL_PATH, "wb") as f:
        pickle.dump(model, f)
    print(f"✅ Model trained on {len(texts)} examples, {len(set(intents))} intents.")
    return model


def load_model():
    # Always retrain on Render since /tmp is cleared on restart
    if not os.path.exists(MODEL_PATH):
        print("⚡ Training model from scratch...")
        return train_model()
    with open(MODEL_PATH, "rb") as f:
        return pickle.load(f)


def extract_slots(text: str) -> dict:
    t = text.lower().strip()
    slots = {}

    name_match = re.search(
        r"(?:called|named|as)\s+['\"]?([a-z][a-z0-9_ ]*?)['\"]?(?:\s|$)", t)
    if name_match:
        slots["sheet_name"] = name_match.group(1).strip().title()

    col_patterns = [
        r"(?:of the|of|for|in the|in|by|on)\s+['\"]?(\w+)['\"]?\s*(?:column|col)\b",
        r"(?:column|col)\s+['\"]?(\w+)['\"]?",
        r"(?:average|avg|sum|total|min|max|count|mean|minimum|maximum)\s+(?:of\s+)?(?:the\s+)?['\"]?(\w+)['\"]?",
    ]
    for pat in col_patterns:
        col_match = re.search(pat, t)
        if col_match:
            candidate = col_match.group(1).strip()
            if candidate not in {"the", "a", "an", "this", "all", "row", "rows", "data"}:
                slots["column"] = candidate
                break

    op_map = {"average": "average", "avg": "average", "mean": "average",
               "sum": "sum", "total": "sum", "min": "min", "minimum": "min",
               "max": "max", "maximum": "max", "count": "count"}
    for keyword, op in op_map.items():
        if keyword in t:
            slots["operation"] = op
            break

    ft_map = [
        (r"\btop\s*\d+\b", "top_n"),
        (r"above average", "above_average"),
        (r"below average", "below_average"),
        (r"between", "between"),
        (r"greater than or equal|>=", "greater_than_equal"),
        (r"less than or equal|<=", "less_than_equal"),
        (r"greater than|>", "greater_than"),
        (r"less than|<", "less_than"),
        (r"does not equal|not equal|!=", "not_equals"),
        (r"contains", "contains"),
        (r"\bequals?\b", "equals"),
    ]
    for pat, ft in ft_map:
        if re.search(pat, t):
            slots["filter_type"] = ft
            break

    nums = re.findall(r"\b\d+(?:\.\d+)?\b", t)
    if nums:
        slots["value"] = nums[0]
        if len(nums) > 1:
            slots["value2"] = nums[1]

    return slots


_model = None

def parse_command(text: str) -> dict:
    global _model
    if _model is None:
        _model = load_model()
    intent     = _model.predict([text])[0]
    confidence = float(_model.predict_proba([text]).max())
    slots      = extract_slots(text)
    return {"intent": intent, "confidence": round(confidence, 3), "slots": slots}


def add_training_example(text, intent, slots=None, path=TRAINING_DATA_PATH):
    with open(path, "r", encoding="utf-8") as f:
        data = json.loads(re.sub(r"//.*", "", f.read()))
    data.append({"text": text, "intent": intent, "slots": slots or {}})
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    global _model
    _model = train_model(path)
    return len(data)
