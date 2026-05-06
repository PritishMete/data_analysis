import pandas as pd
import io
from fastapi import FastAPI, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI()

# Allow your Flutter app to communicate with the server
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # For production, replace with your specific domain
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
async def root():
    return {"message": "Server is running 24/7"}

@app.post("/analyze")
async def analyze_dataset(file: UploadFile = File(...)):
    try:
        # Read the uploaded CSV
        contents = await file.read()
        df = pd.read_csv(io.BytesIO(contents))
        
        # Perform analysis
        analysis = {
            "summary": {
                "rows": len(df),
                "columns": len(df.columns),
                "column_names": df.columns.tolist()
            },
            "missing_values": df.isnull().sum().to_dict(),
            "patterns": {
                # Get mode of the first 5 string columns
                col: str(df[col].mode()[0]) if not df[col].mode().empty else "N/A" 
                for col in df.select_dtypes(include=['object']).columns[:5]
            }
        }
        return analysis
    except Exception as e:
        return {"error": str(e)}






