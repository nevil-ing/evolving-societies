from pydantic import BaseModel
from typing import List, Dict

class Territory(BaseModel):
    """Physical boundaries of a society"""
    x: float
    y: float
    width: float
    height: float

class Environment(BaseModel):
    """Environmental conditions for a society"""
    name: str
    harshness: float  # 0.0 to 1.0
    description: str

class Society(BaseModel):
    """
    A society represents one of the three geometric groups.
    
    This defines their identity, territory, and characteristics.
    """
    name: str  # "Triangles", "Circles", or "Squares"
    color: str  # Hex color for visualization
    shape: str  # "triangle", "circle", "square"
    
    # Territory & Environment
    territory: Territory
    environment: Environment
    
    # Food preferences
    preferred_food: List[str]  # e.g., ["meat", "universal"]
    
    # Cultural traits (influence initial genes)
    culture: str
    base_lifespan: float  # Default lifespan for members
    
    # Initial population
    starting_population: int = 20

# Create the three societies
TRIANGLES = Society(
    name="Triangles",
    color="#ff4444",
    shape="triangle",
    territory=Territory(x=-600, y=-400, width=500, height=400),
    environment=Environment(
        name="Volcanic Wasteland",
        harshness=0.6,
        description="Hot, aggressive, resource-scarce"
    ),
    preferred_food=["meat", "universal"],
    culture="Warrior hunters who thrive on conflict",
    base_lifespan=90.0,
    starting_population=20
)

CIRCLES = Society(
    name="Circles",
    color="#4444ff",
    shape="circle",
    territory=Territory(x=100, y=-400, width=500, height=400),
    environment=Environment(
        name="Lush Gardens",
        harshness=0.1,
        description="Peaceful, abundant vegetation"
    ),
    preferred_food=["plant", "universal"],
    culture="Peaceful gatherers living in harmony",
    #economic_activity=""
    base_lifespan=85,
    starting_population=20
)

SQUARES = Society(
    name="Squares",
    color="#44ff44",
    shape="square",
    territory=Territory(x=-250, y=50, width=500, height=400),
    environment=Environment(
        name="Crystal Caverns",
        harshness=0.3,
        description="Rich in minerals, stable climate"
    ),
    preferred_food=["mineral", "universal"],
    culture="Methodical builders focused on efficiency",
    #economic=""
    #infastructure=""
    base_lifespan=80,
    starting_population=20
)


SOCIETIES = {
    "Triangles": TRIANGLES,
    "Circles": CIRCLES,
    "Squares": SQUARES
}