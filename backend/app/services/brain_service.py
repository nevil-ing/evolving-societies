import torch
import numpy as np
from typing import Dict, Optional
from app.core.neural_network import EntityBrain
from app.core.decision_engine import DecisionEngine
from app.config import settings

class BrainService:
    def __init__(self):
        self.entity_brains: Dict[int, EntityBrain] = {}
        self.decision_engine = DecisionEngine()
        
        if torch.backends.mps.is_available():
            self.device = torch.device("mps")
            print(f"BrainService: Running on M1 GPU (Metal/MPS)")
        elif torch.cuda.is_available():
            self.device = torch.device("cuda")
            print(f"BrainService: Running on CUDA GPU")
        else:
            self.device = torch.device("cpu")
            print(f"BrainService: Running on CPU ")

    async def process_decision(self, entity_id: int, inputs: list, state: dict):
        """Process entity decision using neural network"""
        
        
        if entity_id not in self.entity_brains:
            # Initialize brain using settings dimensions
            brain = EntityBrain(
                input_size=settings.NN_INPUT_SIZE,   # Matches JS inputs (20)
                hidden_size=settings.NN_HIDDEN_SIZE,
                output_size=settings.NN_OUTPUT_SIZE
            )

            self.entity_brains[entity_id] = brain.to(self.device)
        
        brain = self.entity_brains[entity_id]
        
        input_tensor = torch.FloatTensor(inputs).unsqueeze(0).to(self.device)
        
        with torch.no_grad():
            # Run inference
            decision_tensor = brain(input_tensor).squeeze()
            
            # Move result back to CPU for NumPy processing (.cpu())
            decision_probs = decision_tensor.cpu().numpy()
        
        # Get the action with highest probability
        action_index = np.argmax(decision_probs)
        
        # Map action index to action type
        action_types = ['wander', 'gather', 'fight', 'mate', 'socialize']
 
        action_type = action_types[min(action_index, len(action_types) - 1)]
        
        if action_type == 'gather' and state.get('nearby_food', 0) == 0:
            action_type = 'wander'
        if action_type == 'fight' and state.get('nearby_enemies', 0) == 0:
            action_type = 'wander'
        if action_type == 'mate' and state.get('nearby_allies', 0) == 0:
            action_type = 'wander'
                    
        #action response
        action = {
            'type': action_type,
            'vx': 0.0,
            'vy': 0.0
        }
        
        
        if action_type == 'gather' and state.get('nearby_food', 0) > 0:
            action['target_x'] = state.get('food_x', 0)
            action['target_y'] = state.get('food_y', 0)
            
        elif action_type == 'fight' and state.get('nearby_enemies', 0) > 0:
            action['target_x'] = state.get('enemy_x', 0)
            action['target_y'] = state.get('enemy_y', 0)
            
        elif action_type == 'mate' and state.get('nearby_allies', 0) > 0:
            action['target_x'] = state.get('ally_x', 0)
            action['target_y'] = state.get('ally_y', 0)
        
        return {
            'type': 'decision_result',
            'entity_id': entity_id,
            'action': action,
            'action_probabilities': decision_probs.tolist()
        }
    
    async def reproduce(self, parent1_id: int, parent2_id: int, child_id: int):
        """Create child brain from two parents"""
        if parent1_id not in self.entity_brains or parent2_id not in self.entity_brains:
            return {
                'type': 'child_created',
                'child_id': child_id,
                'success': False,
                'error': 'Parent brains not found'
            }
        
        parent1 = self.entity_brains[parent1_id]
        parent2 = self.entity_brains[parent2_id]
        
        # Perform crossover
        child = EntityBrain.crossover(parent1, parent2)
        
        # Mutate weights
        child.mutate(mutation_rate=settings.MUTATION_RATE)
        
        
        # Ensure the new child is explicitly moved to the accelerator
        self.entity_brains[child_id] = child.to(self.device)
        
        return {
            'type': 'child_created',
            'child_id': child_id,
            'success': True
        }
    
    def get_brain(self, entity_id: int) -> Optional[EntityBrain]:
        """Get brain for entity"""
        return self.entity_brains.get(entity_id)
    
    def remove_brain(self, entity_id: int):
        """Remove brain to free up memory"""
        if entity_id in self.entity_brains:
            del self.entity_brains[entity_id]
            