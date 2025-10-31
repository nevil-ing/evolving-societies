from pydantic import BaseModel
from typing import Optional, List

class EntityResponse(BaseModel):
    id: int
    generation: int
    energy: float
    age: float
    society: str
    is_hybrid: bool
    children_count: int

class EntityState(BaseModel):
    energy: float
    nearby_food: int
    nearby_enemies: int
    nearby_allies: int