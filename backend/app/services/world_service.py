import json
import os
import torch
from datetime import datetime
from typing import Optional
from app.config import settings
from app.services.brain_service import BrainService

class WorldService:
    def __init__(self):
        self.brain_service = BrainService()
        os.makedirs(settings.WORLD_STATES_DIR, exist_ok=True)
        os.makedirs(settings.NEURAL_MODELS_DIR, exist_ok=True)
    
    async def save_world(self, world_state: dict, filename: Optional[str] = None) -> bool:
        """Save world state and neural networks"""
        try:
            if not filename:
                filename = f"world_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
            
            filepath = os.path.join(settings.WORLD_STATES_DIR, filename)
            
            with open(filepath, 'w') as f:
                json.dump(world_state, f, indent=2)
            
            # Save neural networks
            for entity_id, brain in self.brain_service.entity_brains.items():
                model_path = os.path.join(
                    settings.NEURAL_MODELS_DIR,
                    f"entity_{entity_id}.pt"
                )
                torch.save(brain.state_dict(), model_path)
            
            return True
        except Exception as e:
            print(f"Error saving world: {e}")
            return False
    
    async def load_world(self, filename: str) -> Optional[dict]:
        """Load world state"""
        try:
            filepath = os.path.join(settings.WORLD_STATES_DIR, filename)
            
            with open(filepath, 'r') as f:
                world_state = json.load(f)
            
            return world_state
        except Exception as e:
            print(f"Error loading world: {e}")
            return None
    
    def list_saves(self) -> list:
        """List all save files"""
        try:
            files = os.listdir(settings.WORLD_STATES_DIR)
            return [f for f in files if f.endswith('.json')]
        except:
            return []

