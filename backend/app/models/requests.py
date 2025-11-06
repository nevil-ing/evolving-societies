from pydantic import BaseModel
from typing import List, Optional
from app.models.entity import EntityState

class DecisionRequest(BaseModel):
    id: int
    inputs: List[float]
    state: EntityState

class ReproductionRequest(BaseModel):
    parent1_id: int
    parent2_id: int
    child_id: int

class EntityCreateRequest(BaseModel):
    x: float
    y: float
    society_name: str
    parent1_id: Optional[int] = None
    parent2_id: Optional[int] = None
    generation: int = 1

class SaveWorldRequest(BaseModel):
    world_state: dict
    filename: Optional[str] = None

class LoadWorldRequest(BaseModel):
    filename: str

class SimulationControlRequest(BaseModel):
    action: str  # "start", "pause", "reset"
