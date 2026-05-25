# app.py

from fastapi import FastAPI, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware

import pandas as pd
import io
import json

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

# ---------------------------------------------------------
# API Route
# ---------------------------------------------------------

@app.post("/analyze")
async def analyze(file: UploadFile = File(...)):

    contents = await file.read()

    filename = file.filename.lower()

    try:

        # CSV
        if filename.endswith(".csv"):
            df = pd.read_csv(io.BytesIO(contents))

        # Excel
        elif filename.endswith(".xlsx"):
            df = pd.read_excel(io.BytesIO(contents))

        # JSON
        elif filename.endswith(".json"):
            data = json.loads(contents.decode("utf-8"))
            df = pd.DataFrame(data)

        else:
            return {
                "error": "Unsupported file format"
            }

        # Clean NaN
        df = df.fillna("")

        # Analyze
        result = analyze_dataframe(df)

        return result

    except Exception as e:
        return {
            "error": str(e)
        }

# ---------------------------------------------------------
# Root Route
# ---------------------------------------------------------

@app.get("/")
def root():
    return {
        "status": "ONLINE",
        "engine": "NEURAL DATA ANALYSIS CORE"
    }
