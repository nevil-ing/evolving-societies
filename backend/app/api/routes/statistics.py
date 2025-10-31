from fastapi import APIRouter
from app.services.statistics_service import StatisticsService

router = APIRouter()
stats_service = StatisticsService()

@router.get("/")
async def get_statistics():
    """Get overall simulation statistics"""
    return stats_service.get_overall_stats()

@router.get("/societies")
async def get_society_stats():
    """Get per-society statistics"""
    return stats_service.get_society_breakdown()

@router.get("/evolution")
async def get_evolution_stats():
    """Get evolution metrics over time"""
    return stats_service.get_evolution_metrics()