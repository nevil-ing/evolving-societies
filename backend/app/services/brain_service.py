import torch
import numpy as np
from typing import Dict
from app.core.neural_network import EntityBrain
from app.core.decision_engine import DecisionEngine
from app.config import settings

class BrainService:
    def __init__(self):
        self.entity_brains: Dict[int, EntityBrain] = {}
        self.decision_engine = DecisionEngine()
    
    async def process_decision(self, entity_id: int, inputs: list, state: dict):
        """Process entity decision using neural network"""
        if entity_id not in self.entity_brains:
            self.entity_brains[entity_id] = EntityBrain(
                input_size=settings.NN_INPUT_SIZE,
                hidden_size=settings.NN_HIDDEN_SIZE,
                output_size=settings.NN_OUTPUT_SIZE
            )
        
        brain = self.entity_brains[entity_id]
        input_tensor = torch.FloatTensor(inputs).unsqueeze(0)
        
        with torch.no_grad():
            decision_probs = brain(input_tensor).squeeze().numpy()
        
        # Get the action with highest probability
        action_index = np.argmax(decision_probs)
        
        # Map action index to action type
        action_types = ['wander', 'gather', 'fight', 'mate', 'socialize']
        action_type = action_types[min(action_index, len(action_types) - 1)]
        
        #action based on state and action type
        action = {
            'type': action_type,
            'vx': 0.0,
            'vy': 0.0
        }
        
        # Set target coordinates based on action type and state
        if action_type == 'gather' and 'nearby_food' in state and state.get('nearby_food', 0) > 0:
            
            action['target_x'] = state.get('food_x', 0)
            action['target_y'] = state.get('food_y', 0)
        elif action_type == 'fight' and 'nearby_enemies' in state and state.get('nearby_enemies', 0) > 0:
            action['target_x'] = state.get('enemy_x', 0)
            action['target_y'] = state.get('enemy_y', 0)
        elif action_type == 'mate' and 'nearby_allies' in state and state.get('nearby_allies', 0) > 0:
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
        
        child = EntityBrain.crossover(parent1, parent2)
        child.mutate(mutation_rate=settings.MUTATION_RATE)
        
        self.entity_brains[child_id] = child
        
        return {
            'type': 'child_created',
            'child_id': child_id,
            'success': True
        }
    
    def get_brain(self, entity_id: int) -> EntityBrain:
        """Get brain for entity"""
        return self.entity_brains.get(entity_id)
    
    def remove_brain(self, entity_id: int):
        """Remove brain"""
        if entity_id in self.entity_brains:
            del self.entity_brains[entity_id]