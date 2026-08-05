from fastapi import FastAPI, UploadFile, File
from analyzer.analyze import analyze_file
import shutil
import os

app = FastAPI()

UPLOAD_DIR = "uploads"
os.makedirs(UPLOAD_DIR, exist_ok=True)

@app.get("/")
def home():
    return {"message": "Data Analysis API Running"}

@app.post("/analyze")
async def analyze(uploaded_file: UploadFile = File(...)):

    file_location = f"{UPLOAD_DIR}/{uploaded_file.filename}"

    with open(file_location, "wb") as buffer:
        shutil.copyfileobj(uploaded_file.file, buffer)

    result = analyze_file(file_location)

    return result