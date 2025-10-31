from pydantic_settings import BaseSettings
from typing import List

class Settings(BaseSettings):
    # API Settings
    HOST: str = "0.0.0.0"
    PORT: int = 8000
    DEBUG: bool = True
    
    # CORS
    ALLOWED_ORIGINS: List[str] = ["*"]
    
    # Neural Network
    NN_INPUT_SIZE: int = 20
    NN_HIDDEN_SIZE: int = 64
    NN_OUTPUT_SIZE: int = 10
    
    # Genetics
    MUTATION_RATE: float = 0.15
    CROSSOVER_RATE: float = 0.7
    
    # Simulation
    MAX_ENTITIES: int = 5000
    RESOURCE_SPAWN_RATE: float = 0.2
    
    # Storage
    DATA_DIR: str = "../data"
    WORLD_STATES_DIR: str = "../data/world_states"
    NEURAL_MODELS_DIR: str = "../data/neural_models"
    
    class Config:
        env_file = ".env"

settings = Settings()