from fastapi import APIRouter
from app.services.entity_service import EntityService
from app.models.requests import SimulationControlRequest

router = APIRouter()
entity_service = EntityService()

@router.post("/start")
async def start_simulation():
    """Start the simulation"""
    return {"status": "started"}

@router.post("/pause")
async def pause_simulation():
    """Pause the simulation"""
    return {"status": "paused"}

@router.post("/reset")
async def reset_simulation():
    """Reset the simulation"""
    entity_service.clear_all()
    return {"status": "reset"}

@router.get("/status")
async def get_status():
    """Get current simulation status"""
    return {
        "total_entities": len(entity_service.get_all_entity_ids()),
        "running": True
    }