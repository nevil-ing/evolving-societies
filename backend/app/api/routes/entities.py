from fastapi import APIRouter, HTTPException
from typing import List
from app.models.entity import EntityResponse
from app.models.requests import DecisionRequest, ReproductionRequest, EntityCreateRequest
from app.services.entity_service import EntityService
from app.services.brain_service import BrainService

router = APIRouter()
entity_service = EntityService()
brain_service = BrainService()

@router.get("/", response_model=List[int])
async def get_all_entities():
    """Get list of all entity IDs"""
    return entity_service.get_all_entity_ids()

@router.post("/", response_model=EntityResponse)
async def create_entity(request: EntityCreateRequest):
    """Create a new entity"""
    entity_id = len(entity_service.get_all_entity_ids()) + 1
    entity_data = {
        "id": entity_id,
        "x": request.x,
        "y": request.y,
        "society_name": request.society_name,
        "generation": request.generation,
        "parent1_id": request.parent1_id,
        "parent2_id": request.parent2_id,
        "energy": 100.0,
        "age": 0.0
    }
    entity_service.add_entity(entity_id, entity_data)
    return EntityResponse(
        id=entity_id,
        generation=request.generation,
        energy=100.0,
        age=0.0,
        society=request.society_name,
        is_hybrid=False,
        children_count=0
    )

@router.get("/{entity_id}", response_model=EntityResponse)
async def get_entity(entity_id: int):
    """Get specific entity details"""
    entity = entity_service.get_entity(entity_id)
    if not entity:
        raise HTTPException(status_code=404, detail="Entity not found")
    return entity

@router.post("/decision")
async def make_decision(request: DecisionRequest):
    """Make a decision for an entity"""
    result = await brain_service.process_decision(
        entity_id=request.id,
        inputs=request.inputs,
        state=request.state
    )
    return result

@router.post("/reproduce")
async def reproduce(request: ReproductionRequest):
    """Create offspring from two parents"""
    result = await brain_service.reproduce(
        parent1_id=request.parent1_id,
        parent2_id=request.parent2_id,
        child_id=request.child_id
    )
    return result

@router.delete("/{entity_id}")
async def delete_entity(entity_id: int):
    """Remove an entity"""
    success = entity_service.remove_entity(entity_id)
    if not success:
        raise HTTPException(status_code=404, detail="Entity not found")
    return {"status": "deleted", "entity_id": entity_id}