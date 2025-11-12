from pydantic import BaseModel
from typing import List, Dict
from app.models.entity import EntityState


class Resource(BaseModel):
    """A resource that entities can gather."""
    id: int
    type: str  
    x: float
    y: float
    resource_type: str  
    amount: float = 100.0

    class WordlState(BaseModel):
        """Complete state of the world simulation"""

        #time
        simulation_time: float = 0.0
        current_generation: int = 0

        #entities
        entities: List[EntityState] = []

        #resources
        resources: List[Resource] = []

        #statistics
        total_births: int = 0
        total_deaths: int = 0


        #metadata
        world_name: str = "Evolvy"
        created_at: str = ""