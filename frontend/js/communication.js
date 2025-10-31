class BackendCommunication {
    constructor() {
        this.ws = null;
        this.messageCallbacks = new Map();
        this.connect();
    }
    
    connect() {
        this.ws = new WebSocket('ws://localhost:8000/ws');
        
        this.ws.onopen = () => {
            console.log('Connected to FastAPI backend');
        };
        
        this.ws.onmessage = (event) => {
            const data = JSON.parse(event.data);
            this.handleMessage(data);
        };
        
        this.ws.onerror = (error) => {
            console.error('WebSocket error:', error);
        };
        
        this.ws.onclose = () => {
            console.log('Disconnected from backend');
            // Attempt reconnection after 5 seconds
            setTimeout(() => this.connect(), 5000);
        };
    }
    
    handleMessage(data) {
        const type = data.type;
        
        if (this.messageCallbacks.has(type)) {
            const callbacks = this.messageCallbacks.get(type);
            callbacks.forEach(callback => callback(data));
        }
    }
    
    on(messageType, callback) {
        if (!this.messageCallbacks.has(messageType)) {
            this.messageCallbacks.set(messageType, []);
        }
        this.messageCallbacks.get(messageType).push(callback);
    }
    
    send(data) {
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            this.ws.send(JSON.stringify(data));
        }
    }
    
    async getEntityDecision(entity, entities, resources) {
        return new Promise((resolve) => {
            // Prepare inputs for neural network (20 inputs total)
            const inputs = [
                entity.energy / 100,
                entity.age / 1000,
                entity.brain.genes.aggression,
                entity.brain.genes.cooperation,
                entity.brain.genes.speed,
                entity.brain.genes.efficiency,
                entity.brain.genes.resourceGathering,
                entity.brain.genes.reproductionDrive,
                entity.brain.genes.socialDistance,
                entity.brain.genes.communication,
                entity.brain.genes.adaptability,
                entity.brain.genes.territoriality,
                this.countNearbyFood(entity, resources) / 10,
                this.countNearbyEnemies(entity, entities) / 10,
                this.countNearbyAllies(entity, entities) / 10,
                entity.generation / 50,
                entity.isHybrid ? 1 : 0,
                entity.dietBonus,
                entity.reproductionCooldown / 20,
                entity.communicationCooldown / 10
            ];
            
            const messageId = `decision_${entity.id}_${Date.now()}`;
            
            const callback = (data) => {
                if (data.entity_id === entity.id) {
                    resolve(data);
                    // Remove callback after use
                    const callbacks = this.messageCallbacks.get('decision_result');
                    const index = callbacks.indexOf(callback);
                    if (index > -1) callbacks.splice(index, 1);
                }
            };
            
            this.on('decision_result', callback);
            
            this.send({
                type: 'entity_decision',
                id: entity.id,
                inputs: inputs,
                state: {
                    energy: entity.energy,
                    nearby_food: this.countNearbyFood(entity, resources),
                    nearby_enemies: this.countNearbyEnemies(entity, entities),
                    nearby_allies: this.countNearbyAllies(entity, entities)
                }
            });
        });
    }
    
    countNearbyFood(entity, resources) {
        return resources.filter(r => {
            if (r.amount <= 0) return false;
            const dist = entity.distanceTo(r);
            return dist < 250 && entity.canEatResource(r);
        }).length;
    }
    
    countNearbyEnemies(entity, entities) {
        return entities.filter(e => 
            e.society !== entity.society && 
            entity.distanceTo(e) < 150
        ).length;
    }
    
    countNearbyAllies(entity, entities) {
        return entities.filter(e => 
            e.society === entity.society && 
            e !== entity &&
            entity.distanceTo(e) < 150
        ).length;
    }
    
    async reproduceEntities(parent1, parent2, childId) {
        return new Promise((resolve) => {
            const callback = (data) => {
                if (data.child_id === childId) {
                    resolve(data);
                    const callbacks = this.messageCallbacks.get('child_created');
                    const index = callbacks.indexOf(callback);
                    if (index > -1) callbacks.splice(index, 1);
                }
            };
            
            this.on('child_created', callback);
            
            this.send({
                type: 'reproduce',
                parent1_id: parent1.id,
                parent2_id: parent2.id,
                child_id: childId
            });
        });
    }
    
    saveWorld(worldData) {
        this.send({
            type: 'save_world',
            world_state: worldData
        });
    }
    
    loadWorld(entityIds) {
        return new Promise((resolve) => {
            this.on('load_complete', (data) => {
                resolve(data);
            });
            
            this.send({
                type: 'load_world',
                entity_ids: entityIds
            });
        });
    }
}