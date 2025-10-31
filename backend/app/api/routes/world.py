from fastapi import APIRouter, HTTPException
from app.services.world_service import WorldService
from app.models.requests import SaveWorldRequest, LoadWorldRequest

router = APIRouter()
world_service = WorldService()

@router.post("/save")
async def save_world(request: SaveWorldRequest):
    """Save current world state"""
    success = await world_service.save_world(request.world_state, request.filename)
    if not success:
        raise HTTPException(status_code=500, detail="Failed to save world")
    return {"status": "saved", "filename": request.filename}

@router.post("/load")
async def load_world(request: LoadWorldRequest):
    """Load a saved world state"""
    world_state = await world_service.load_world(request.filename)
    if not world_state:
        raise HTTPException(status_code=404, detail="World state not found")
    return world_state

@router.get("/saves")
async def list_saves():
    """List all available save files"""
    saves = world_service.list_saves()
    return {"saves": saves}