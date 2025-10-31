from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.config import settings
from app.api.routes import entities, simulation, statistics, world
from app.api.websocket import router as websocket_router

app = FastAPI(
    title="Evolving Societies API",
    description="Neural network-based artificial life simulation",
    version="0.1.0"
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(entities.router, prefix="/api/entities", tags=["entities"])
app.include_router(simulation.router, prefix="/api/simulation", tags=["simulation"])
app.include_router(statistics.router, prefix="/api/statistics", tags=["statistics"])
app.include_router(world.router, prefix="/api/world", tags=["world"])
app.include_router(websocket_router)

@app.get("/")
async def root():
    return {
        "message": "Evolving Societies API",
        "version": "0.1.0",
        "status": "running"
    }

@app.get("/health")
async def health():
    return {"status": "healthy"}

