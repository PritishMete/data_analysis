import pandas as pd
import io
from fastapi import FastAPI, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.post("/analyze")
async def analyze_dataset(file: UploadFile = File(...)):
    try:
        contents = await file.read()
        df = pd.read_csv(io.BytesIO(contents))

        # Capture df.info()
        buffer = io.StringIO()
        df.info(buf=buffer)
        info_str = buffer.getvalue()

        analysis = {
            "head": df.head(5).to_dict(),
            "shape": df.shape,
            "columns": df.columns.tolist(),

            "info": info_str,

            "describe": df.describe(include='all').fillna("").to_dict(),

            "missing_values": df.isnull().sum().to_dict(),

            "dtypes": df.dtypes.astype(str).to_dict(),

            "n_unique": df.nunique().to_dict(),

            "top_values": {
                col: df[col].value_counts().head(3).to_dict()
                for col in df.columns
            },

            "correlation": df.select_dtypes(include='number').corr().fillna(0).to_dict()
        }

        return analysis

    except Exception as e:
        return {"error": str(e)}
