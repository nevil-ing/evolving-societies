from pydantic import BaseModel
from typing import List
from app.models.entity import EntityState

class DecisionRequest(BaseModel):
    id: int
    inputs: List[float]
    state: EntityState

class ReproductionRequest(BaseModel):
    parent1_id: int
    parent2_id: int
    child_id: int

class SaveWorldRequest(BaseModel):
    world_state: dict
    filename: Optional[str] = None

class LoadWorldRequest(BaseModel):
    filename: str

class SimulationControlRequest(BaseModel):
    action: str  # "start", "pause", "reset"
