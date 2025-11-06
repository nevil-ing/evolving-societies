from pydantic import BaseModel
from typing import Optional, List

class GeneticTraits(BaseModel):
    aggression: float = 0.5
    cooperation: float = 0.5
    speed: float = 0.5
    efficiency: float = 0.5
    resourceGathering: float = 0.5
    reproductionDrive: float = 0.5
    socialDistance: float = 0.5
    communication: float = 0.5
    adaptability: float = 0.5
    territoriality: float = 0.5

class EntityResponse(BaseModel):
    id: int
    generation: int
    energy: float
    age: float
    society: str
    is_hybrid: bool
    children_count: int

class EntityState(BaseModel):
    """Current state of an entity in the simulation."""
    id: int 
    generation: int
    society_name: str
    is_hybrid: bool= False

    #positon and physics
    x: float
    y: float
    velocity_x: float = 0.0
    velocity_y: float = 0.0

    #life stats
    energy: float = 100.0
    age: float = 0.0
    lifespan: float = 100.0
    born_at: float = 0.0

    #genetics
    genes: GeneticTraits

    #relationships
    parent1_id: Optional[int] = None
    parent2_id: Optional[int] = None
    children_ids: List[int] = []

    #Behaviour tracking
    total_food_gathered: float = 0.0
    total_fights: int = 0
    total_reproductions: int = 0
    #total_social_interactions: int = 0
    total_distance_traveled: float = 0.0

    #status
    is_alive: bool = True
    reproduction_cooldown: float = 0.0
    communication_cooldown: float = 0.0