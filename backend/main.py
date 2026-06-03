from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
import os

app = FastAPI()

# Serve static files (GeoJSON)
static_dir = os.path.join(os.path.dirname(__file__), "static")
app.mount("/static", StaticFiles(directory=static_dir), name="static")

@app.get("/api/hello")
def hello():
    return {"message": "Flat Globe API is running"}

@app.get("/api/geojson")
def get_geojson():
    geojson_path = os.path.join(static_dir, "ne_110m_admin_0_countries.json")
    return FileResponse(geojson_path, media_type="application/json")

@app.get("/healthz")
def healthz():
    return {"status": "ok"}
