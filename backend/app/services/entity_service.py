from typing import List, Optional, Dict

class EntityService:
    def __init__(self):
        self.entities: Dict[int, dict] = {}
    
    def get_all_entity_ids(self) -> List[int]:
        """Get list of all entity IDs"""
        return list(self.entities.keys())
    
    def get_entity(self, entity_id: int) -> Optional[dict]:
        """Get entity by ID"""
        return self.entities.get(entity_id)
    
    def add_entity(self, entity_id: int, entity_data: dict):
        """Add new entity"""
        self.entities[entity_id] = entity_data
    
    def remove_entity(self, entity_id: int) -> bool:
        """Remove entity"""
        if entity_id in self.entities:
            del self.entities[entity_id]
            return True
        return False
    
    def clear_all(self):
        """Clear all entities"""
        self.entities.clear()