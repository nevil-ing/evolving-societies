from app.services.entity_service import EntityService

class StatisticsService:
    def __init__(self):
        self.entity_service = EntityService()
    
    def get_overall_stats(self) -> dict:
        """Calculate overall statistics"""
        entities = self.entity_service.entities
        
        return {
            "total_population": len(entities),
            "total_generations": self._calculate_max_generation(entities),
            # Add more stats
        }
    
    def get_society_breakdown(self) -> dict:
        """Get statistics per society"""
        # Implementation
        pass
    
    def get_evolution_metrics(self) -> dict:
        """Get evolution metrics over time"""
        # Implementation
        pass
    
    def _calculate_max_generation(self, entities: dict) -> int:
        """Helper to find max generation"""
        if not entities:
            return 0
        return max([e.get('generation', 1) for e in entities.values()])