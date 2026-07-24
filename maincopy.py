from fastapi import FastAPI, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv
import pandas as pd
import io
import json
import traceback
from command_agent import parse_agentic_command

# Load environment variables from .env (GOOGLE_API_KEY, etc.)
# On Render, these are set directly in the dashboard instead, but load_dotenv()
# is harmless there too — it just won't find a .env file and does nothing.
load_dotenv()

from ai_analyst import generate_report

app = FastAPI()

# Allow Flutter/Web requests
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------
# Helper Function
# ---------------------------------------------------------
def analyze_dataframe(df: pd.DataFrame):
    try:
        describe_data = (
            df.describe(include='all')
            .fillna("")
            .reset_index()
            .to_dict(orient="records")
        )
    except Exception:
        describe_data = []
    preview = df.head(15).fillna("").to_dict(orient="records")
    sample = (
        df.sample(min(10, len(df)))
        .fillna("")
        .to_dict(orient="records")
        if len(df) > 0 else []
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
    buffer = io.StringIO()
    df.info(buf=buffer)
    info_text = buffer.getvalue()
    return {
        "rows": int(df.shape[0]),
        "columns": int(df.shape[1]),
        "column_names": list(df.columns),
        "duplicates": duplicate_count,
        "missing_values": missing_values,
        "unique_values": unique_values,
        "preview": preview,
        "sample": sample,
        "describe": describe_data,
        "info": info_text
    }


def _load_dataframe(filename: str, contents: bytes) -> pd.DataFrame:
    """Shared file-parsing logic used by both /analyze and /analyze-report."""
    filename = filename.lower()
    if filename.endswith(".csv"):
        return pd.read_csv(io.BytesIO(contents))
    elif filename.endswith(".xlsx"):
        return pd.read_excel(io.BytesIO(contents))
    elif filename.endswith(".json"):
        data = json.loads(contents.decode("utf-8"))
        return pd.DataFrame(data)
    else:
        raise ValueError("Unsupported file format")


# ---------------------------------------------------------
# API Route — raw stats (existing)
# ---------------------------------------------------------
@app.post("/analyze")
async def analyze(file: UploadFile = File(...)):
    contents = await file.read()
    filename = file.filename.lower()
    try:
        if filename.endswith(".csv"):
            df = pd.read_csv(io.BytesIO(contents))
        elif filename.endswith(".xlsx"):
            df = pd.read_excel(io.BytesIO(contents))
        elif filename.endswith(".json"):
            data = json.loads(contents.decode("utf-8"))
            df = pd.DataFrame(data)
        else:
            return {"error": "Unsupported file format"}
        df = df.fillna("")
        result = analyze_dataframe(df)
        return result
    except Exception as e:
        return {"error": str(e)}


# ---------------------------------------------------------
# API Route — AI-narrated report (new)
# ---------------------------------------------------------
@app.post("/analyze-report")
async def analyze_report(file: UploadFile = File(...)):
    contents = await file.read()
    try:
        df = _load_dataframe(file.filename, contents)
        result = await generate_report(df)
        return result
    except ValueError as e:
        return {"error": str(e)}
    except Exception as e:
        return {"error": str(e)}


# ---------------------------------------------------------
# agentic operation
# ---------------------------------------------------------

@app.post("/agentic_command")
async def agentic_command(payload: dict):
    text = payload.get("text", "")
    available_columns = payload.get("available_columns", [])
    available_sheets = payload.get("available_sheets", [])
    try:
        result = await parse_agentic_command(text, available_columns, available_sheets)
        return result
    except Exception as e:
        # Print full traceback to Render logs — the previous version only
        # returned the error message to the client, so the real cause never
        # showed up anywhere visible.
        print("[/agentic_command] EXCEPTION:")
        traceback.print_exc()
        return {"action": "unknown", "confidence": 0.0, "message": f"Error: {str(e)}"}


# ---------------------------------------------------------
# Root Route
# ---------------------------------------------------------
@app.get("/")
def root():
    return {
        "status": "ONLINE",
        "engine": "NEURAL DATA ANALYSIS CORE"
    }

# ---------------------------------------------------------
# AI Routes — must be AFTER app is created
# ---------------------------------------------------------
from ai_routes import ai_router
app.include_router(ai_router)
