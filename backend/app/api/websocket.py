from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from app.utils.connection_manager import ConnectionManager
from app.services.brain_service import BrainService
from app.services.world_service import WorldService

router = APIRouter()
manager = ConnectionManager()
brain_service = BrainService()
world_service = WorldService()

@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    
    try:
        await websocket.send_json({
            "type": "connection_response",
            "status": "connected"
        })
        
        while True:
            data = await websocket.receive_json()
            message_type = data.get("type")
            
            if message_type == "entity_decision":
                result = await brain_service.process_decision(
                    entity_id=data['id'],
                    inputs=data['inputs'],
                    state=data['state']
                )
                await websocket.send_json(result)
                
            elif message_type == "reproduce":
                result = await brain_service.reproduce(
                    parent1_id=data['parent1_id'],
                    parent2_id=data['parent2_id'],
                    child_id=data['child_id']
                )
                await websocket.send_json(result)
                
            elif message_type == "save_world":
                result = await world_service.save_world(data.get('world_state', {}))
                await websocket.send_json(result)
                
            elif message_type == "load_world":
                result = await world_service.load_world(data.get('filename'))
                await websocket.send_json(result)
                
    except WebSocketDisconnect:
        manager.disconnect(websocket)
    except Exception as e:
        print(f"WebSocket error: {e}")
        manager.disconnect(websocket)