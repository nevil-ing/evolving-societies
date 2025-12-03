// Societies configuration
const societies = {
    triangles: {
        name: 'Triangles',
        color: '#ff4444',
        territory: { x: -600, y: -400, width: 500, height: 400 },
        environment: {
            name: 'Volcanic Wasteland',
            harshness: 0.5,
            description: 'Hot, aggressive, resource-scarce'
        },
        preferredFood: ['meat', 'universal'],
        culture: 'Warrior hunters who thrive on conflict',
        drawShape: (ctx, size, health) => {
            ctx.fillStyle = `rgba(255, 68, 68, ${health * 0.7 + 0.3})`;
            ctx.strokeStyle = '#ff0000';
            ctx.lineWidth = 2;
            ctx.beginPath();
            ctx.moveTo(0, -size);
            ctx.lineTo(-size, size);
            ctx.lineTo(size, size);
            ctx.closePath();
            ctx.fill();
            ctx.stroke();
        }
    },
    circles: {
        name: 'Circles',
        color: '#4444ff',
        territory: { x: 100, y: -400, width: 500, height: 400 },
        environment: {
            name: 'Lush Gardens',
            harshness: 0.1,
            description: 'Peaceful, abundant vegetation'
        },
        preferredFood: ['plant', 'universal'],
        culture: 'Peaceful gatherers living in harmony',
        drawShape: (ctx, size, health) => {
            ctx.fillStyle = `rgba(68, 68, 255, ${health * 0.7 + 0.3})`;
            ctx.strokeStyle = '#0000ff';
            ctx.lineWidth = 2;
            ctx.beginPath();
            ctx.arc(0, 0, size, 0, Math.PI * 2);
            ctx.fill();
            ctx.stroke();
        }
    },
    squares: {
        name: 'Squares',
        color: '#44ff44',
        territory: { x: -250, y: 50, width: 500, height: 400 },
        environment: {
            name: 'Crystal Caverns',
            harshness: 0.3,
            description: 'Rich in minerals, stable climate'
        },
        preferredFood: ['mineral', 'universal'],
        culture: 'Methodical builders focused on efficiency',
        drawShape: (ctx, size, health) => {
            ctx.fillStyle = `rgba(68, 255, 68, ${health * 0.7 + 0.3})`;
            ctx.strokeStyle = '#00ff00';
            ctx.lineWidth = 2;
            ctx.fillRect(-size, -size, size * 2, size * 2);
            ctx.strokeRect(-size, -size, size * 2, size * 2);
        }
    }
};

// Backend API URL
const API_BASE_URL = 'http://localhost:8000';
const WS_URL = 'ws://localhost:8000/ws';

// Canvas setup
const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d');

canvas.width = window.innerWidth;
canvas.height = window.innerHeight;

window.addEventListener('resize', () => {
    canvas.width = window.innerWidth;
    canvas.height = window.innerHeight;
});

// Game state
let simulationTime = 0;
let isPaused = false;
let lastTime = Date.now();
let timeSpeed = 1;
let maxGeneration = 1;
let entityIdCounter = 0;

// Camera
let camera = { x: 0, y: 0, zoom: 0.6 };

// Communication signals
const signals = [];
const resources = [];
let entities = [];
let selectedEntity = null;

// Backend communication
let backend = null;

// Initialize backend connection
function initBackend() {
    backend = new BackendCommunication();
    
    backend.on('connection_response', (data) => {
        console.log('Connected to backend:', data);
        updateConnectionStatus(true);
    });
    
    // Note: 'decision_result' is now handled via Promises in the update loop,
    // but we keep this listener just in case specific global events are needed.
    
    backend.on('child_created', (data) => {
        console.log('Child created via Backend Genetics:', data);
    });
}

function updateConnectionStatus(connected) {
    const statusEl = document.getElementById('connectionStatus');
    if (statusEl) {
        statusEl.textContent = connected ? 'Connected (Neural Engine Active)' : 'Disconnected';
        statusEl.style.color = connected ? '#00ff00' : '#ff4444';
    }
}

function applyAction(entity, action) {
    // This function needs to run every frame to keep the entity moving towards its target
    if (!action) return;

    if (action.type === 'move') {
        entity.vx = action.vx || 0;
        entity.vy = action.vy || 0;
    } else if (action.type === 'gather') {
        entity.moveTo(action.target_x, action.target_y, 1.2);
    } else if (action.type === 'fight') {
        entity.moveTo(action.target_x, action.target_y, 1.3);
    } else if (action.type === 'mate') {
        entity.moveTo(action.target_x, action.target_y, 0.9);
    } else if (action.type === 'wander') {
        
        //continous movement for entitites not moving.
        const currentSpeed = Math.sqrt(entity.vx * entity.vx + entity.vy * entity.vy);
        if (currentSpeed < 0.4) {
            const angle = Math.random() * Math.PI * 2;
            entity.vx += Math.cos(angle) * 0.6;
            entity.vy += Math.random(angle) * 0.6;
        }else{
            const turn = Math.random() < 0.05;
            const vx = entity.vx;
            const vy = entity.vy;

            //rotate velocity vector slightly
            entity.vx = vx * Math.cos(turn) - vy * Math.sin(0.1);
            entity.vy = vx * Math.sin(turn) + vy * Math.cos(0.1);
        }
    }
}

// Initialize world
async function initWorld() {
    entities = [];
    resources.length = 0;
    signals.length = 0;
    simulationTime = 0;
    maxGeneration = 1;
    entityIdCounter = 0;
    selectedEntity = null;
    
    // Reset simulation via API
    try {
        await fetch(`${API_BASE_URL}/api/simulation/reset`, {
            method: 'POST'
        });
    } catch (error) {
        console.error('Error resetting simulation:', error);
    }
    
    // Create initial populations
    for (let society of Object.values(societies)) {
        for (let i = 0; i < 5; i++) {
            const x = society.territory.x + Math.random() * society.territory.width;
            const y = society.territory.y + Math.random() * society.territory.height;
            const entity = new Entity(x, y, society);
            entity.id = entityIdCounter++;
            entities.push(entity);
            
            // Register entity with backend
            try {
                await fetch(`${API_BASE_URL}/api/entities/`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        x: x,
                        y: y,
                        society_name: society.name,
                        generation: 1
                    })
                });
            } catch (error) {
                console.error('Error creating entity:', error);
            }
        }
    }
    
    // Spawn resources based on territories
    for (let society of Object.values(societies)) {
        const t = society.territory;
        const foodType = society.preferredFood[0];
        
        // Spawn preferred food in their territory
        for (let i = 0; i < 30; i++) {
            resources.push(new Resource(
                t.x + Math.random() * t.width,
                t.y + Math.random() * t.height,
                foodType
            ));
        }
        
        // Spawn some universal food
        for (let i = 0; i < 100; i++) {
            resources.push(new Resource(
                t.x + Math.random() * t.width,
                t.y + Math.random() * t.height,
                'universal'
            ));
        }
    }
    
    // Add random resources
    for (let i = 0; i < 500; i++) {
        const types = ['meat', 'plant', 'mineral', 'universal'];
        resources.push(new Resource(
            Math.random() * 1600 - 800,
            Math.random() * 1200 - 600,
            types[Math.floor(Math.random() * types.length)]
        ));
    }
}

// Update entities 
function updateEntities(deltaTime) {
    const newEntities = [];
    
    for (let entity of entities) {
        entity.age += deltaTime;
        
        // Energy drain based on efficiency and environment
        const envPenalty = entity.society.environment.harshness;
        const energyDrain = (0.2 + envPenalty * 0.1) * (1 - entity.brain.genes.efficiency * 0.4);
        entity.energy -= deltaTime * energyDrain;
        
        // Diet bonus decay
        entity.dietBonus *= 0.99;
        
        entity.reproductionCooldown = Math.max(0, entity.reproductionCooldown - deltaTime);
        entity.communicationCooldown = Math.max(0, entity.communicationCooldown - deltaTime);
        
        if (entity.energy <= 0) {
            continue; // Entity dies
        }
        
        entity.energy = Math.min(150, entity.energy);
        
        entity.decisionTimer -= deltaTime;

        
        if (entity.decisionTimer <= 0) {
            entity.decisionTimer = 0.3 + Math.random() * 0.5;

            if (backend && backend.ws && backend.ws.readyState === WebSocket.OPEN) {
            
                backend.getEntityDecision(entity, entities, resources).then(result => {
                    if (result && result.action) {
                        // Store the decision 
                        entity.currentAction = result.action;
                    }
                }).catch(err => {
                    // If request fails, default to local AI
                    localAI(entity, entities, resources, signals);
                });
            } else {
            
                localAI(entity, entities, resources, signals);
            }
        }

        if (entity.currentAction) {
            applyAction(entity, entity.currentAction);
        } else if (!backend || backend.ws.readyState !== WebSocket.OPEN) {
             
        }
        
        

        // Move with speed influenced by diet
        const speedBonus = 1 + entity.dietBonus * 0.3;
        const speed = 10 * (0.5 + entity.brain.genes.speed * 0.5) * speedBonus;
        entity.x += entity.vx * deltaTime * speed;
        entity.y += entity.vy * deltaTime * speed;
        
        // Friction
        entity.vx *= 0.95;
        entity.vy *= 0.95;
        
        // Stay in or near territory (Soft boundaries)
        const territory = entity.society.territory;
        const margin = 100;
        if (entity.x < territory.x - margin) entity.vx += 0.5;
        if (entity.x > territory.x + territory.width + margin) entity.vx -= 0.5;
        if (entity.y < territory.y - margin) entity.vy += 0.5;
        if (entity.y > territory.y + territory.height + margin) entity.vy -= 0.5;
        
        // Check for resource gathering (Collision detection)
        for (let resource of resources) {
            if (resource.amount > 0 && entity.canEatResource(resource)) {
                const dist = entity.distanceTo(resource);
                if (dist < 15) {
                    const value = getResourceValue(entity, resource);
                    const taken = Math.min(value, resource.amount);
                    resource.amount -= taken;
                    entity.energy += taken;
                    entity.lastMeal = resource.type;
                }
            }
        }
        
        newEntities.push(entity);
    }
    
    entities = newEntities;
}

function getResourceValue(entity, resource) {
    const preferredFood = entity.society.preferredFood;
    let value = 15;
    
    if (resource.type === 'universal') {
        value = 20;
    } else if (preferredFood.includes(resource.type)) {
        value = 25;
        
        if (resource.type === 'meat') {
            entity.dietBonus = 0.3;
        } else if (resource.type === 'plant') {
            entity.energy += 5;
        } else if (resource.type === 'mineral') {
            entity.brain.genes.efficiency = Math.min(1, entity.brain.genes.efficiency + 0.01);
        }
    }
    
    return value;
}

// Local AI fallback (Used when Backend is disconnected or between frames)
function localAI(entity, entities, resources, signals) {
    const nearbyFood = resources.filter(r => {
        if (r.amount <= 0) return false;
        const dist = entity.distanceTo(r);
        return dist < 250 && entity.canEatResource(r);
    }).length;
    
    const nearbyAllies = entities.filter(e => 
        e.society === entity.society && entity.distanceTo(e) < 150
    ).length;
    
    const nearbyEnemies = entities.filter(e => 
        e.society !== entity.society && entity.distanceTo(e) < 150
    ).length;
    
    // Logic determines intended action, then sets entity.currentAction implicitly 
    // by calling helper functions that set vx/vy or targets.
    // To make this compatible with the new system, we should ideally update entity.currentAction
    // but since localAI calls 'gatherResources' which calls 'moveTo', it works directly on Physics.
    
    if (entity.energy < 40) {
        gatherResources(entity, resources, signals);
        entity.currentAction = { type: 'gather' }; 
    } else if (nearbyEnemies > 0 && entity.brain.genes.aggression > 0.4) {
        fight(entity, entities, signals);
        entity.currentAction = { type: 'fight' };
    } else if (entity.energy > 80 && entity.reproductionCooldown === 0) {
        seekMate(entity, entities);
        entity.currentAction = { type: 'mate' };
    } else if (nearbyFood > 0 && entity.energy < 90) {
        gatherResources(entity, resources, signals);
        entity.currentAction = { type: 'gather' };
    } else if (entity.brain.genes.cooperation > 0.5) {
        socialize(entity, entities);
        entity.currentAction = { type: 'socialize' };
    } else {
        wander(entity);
        entity.currentAction = { type: 'wander' };
    }
}

function gatherResources(entity, resources, signals) {
    const available = resources.filter(r => 
        r.amount > 0 && entity.canEatResource(r)
    ).sort((a, b) => entity.distanceTo(a) - entity.distanceTo(b));
    
    if (available.length === 0) {
        if (entity.energy < 30) {
            communicate(entity, 'help', '!', signals);
        }
        return;
    }
    
    const nearest = available[0];
    entity.moveTo(nearest.x, nearest.y, 1.2);
    
    if (entity.brain.genes.communication > 0.3 && available.length > 1 && Math.random() < 0.1) {
        communicate(entity, 'food', '🍃', signals);
    }
}

function fight(entity, entities, signals) {
    const enemies = entities.filter(e => 
        e.society !== entity.society && entity.distanceTo(e) < 150
    );
    
    if (enemies.length > 0) {
        const target = enemies[0];
        entity.moveTo(target.x, target.y, 1.3);
        
        if (entity.distanceTo(target) < 20) {
            const damage = 0.4 * entity.brain.genes.aggression;
            target.energy -= damage;
            entity.energy -= 0.15;
            
            if (Math.random() < 0.3) {
                communicate(entity, 'alert', '⚠', signals);
            }
        }
    }
}

function seekMate(entity, entities) {
    if (entity.energy < 70 || entity.reproductionCooldown > 0) return;
    
    const range = 180 * (1 + entity.brain.genes.socialDistance);
    const mates = entities.filter(e => 
        e !== entity && 
        e.energy > 70 && 
        e.reproductionCooldown === 0 &&
        entity.distanceTo(e) < range
    );
    
    if (mates.length > 0) {
        const mate = mates[0];
        entity.moveTo(mate.x, mate.y, 0.9);
        
        if (entity.distanceTo(mate) < 25 && Math.random() < 0.1) {
            communicate(entity, 'mate', '❤', signals);
            
            // Try to reproduce
            if (Math.random() < 0.05) {
                reproduce(entity, mate);
            }
        }
    }
}

function socialize(entity, entities) {
    const allies = entities.filter(e => 
        e.society === entity.society && 
        e !== entity && 
        entity.distanceTo(e) < 200
    );
    
    if (allies.length > 0) {
        const target = allies[Math.floor(Math.random() * allies.length)];
        const targetDist = 60 * entity.brain.genes.socialDistance;
        const currentDist = entity.distanceTo(target);
        
        if (currentDist > targetDist + 20) {
            entity.moveTo(target.x, target.y, 0.6);
        } else if (currentDist < targetDist - 20) {
            const dx = entity.x - target.x;
            const dy = entity.y - target.y;
            const dist = Math.sqrt(dx * dx + dy * dy);
            if (dist > 0) {
                entity.vx += (dx / dist) * 0.3;
                entity.vy += (dy / dist) * 0.3;
            }
        }
    }
}

function wander(entity) {
    if (Math.random() < 0.03) {
        entity.vx = (Math.random() - 0.5) * 0.6;
        entity.vy = (Math.random() - 0.5) * 0.6;
    }
}

function communicate(entity, type, message, signals) {
    if (entity.communicationCooldown > 0) return;
    if (entity.brain.genes.communication < 0.3) return;
    
    signals.push(new Signal(entity.x, entity.y, type, message));
    entity.communicationCooldown = 5;
}

function reproduce(parent1, parent2) {
    if (parent1.reproductionCooldown > 0 || parent2.reproductionCooldown > 0) return;
    if (parent1.energy < 70 || parent2.energy < 70) return;
    
    parent1.energy -= 30;
    parent2.energy -= 30;
    parent1.reproductionCooldown = 12;
    parent2.reproductionCooldown = 12;
    
    const x = (parent1.x + parent2.x) / 2;
    const y = (parent1.y + parent2.y) / 2;
    
    let childSociety;
    if (parent1.society === parent2.society) {
        childSociety = parent1.society;
    } else {
        childSociety = Math.random() < 0.5 ? parent1.society : parent2.society;
    }
    
    const generation = Math.max(parent1.generation, parent2.generation) + 1;
    maxGeneration = Math.max(maxGeneration, generation);
    
    const child = new Entity(
        x + (Math.random() - 0.5) * 40, 
        y + (Math.random() - 0.5) * 40, 
        childSociety,
        parent1,
        parent2,
        generation
    );
    child.id = entityIdCounter++;
    child.energy = 80;
    entities.push(child);
    
    // Notify backend of reproduction 
    if (backend) {
        backend.reproduceEntities(parent1, parent2, child.id);
    }
}

// Mouse interaction
canvas.addEventListener('click', (e) => {
    const rect = canvas.getBoundingClientRect();
    const mouseX = e.clientX - rect.left;
    const mouseY = e.clientY - rect.top;
    
    const worldX = (mouseX - canvas.width / 2) / camera.zoom + camera.x;
    const worldY = (mouseY - canvas.height / 2) / camera.zoom + camera.y;
    
    selectedEntity = null;
    let minDist = 20 / camera.zoom;
    
    for (let entity of entities) {
        const dist = Math.sqrt((entity.x - worldX) ** 2 + (entity.y - worldY) ** 2);
        if (dist < minDist) {
            selectedEntity = entity;
            minDist = dist;
        }
    }
});

canvas.addEventListener('mousemove', (e) => {
    if (selectedEntity) {
        const rect = canvas.getBoundingClientRect();
        const infoDiv = document.getElementById('entityInfo');
        infoDiv.style.left = (e.clientX + 15) + 'px';
        infoDiv.style.top = (e.clientY + 15) + 'px';
        infoDiv.style.display = 'block';
        
        const genes = selectedEntity.brain.genes;
        let html = `
            <div style="color: ${selectedEntity.society.color}; font-weight: bold; margin-bottom: 8px;">
                ${selectedEntity.society.name} #${selectedEntity.id}
            </div>
            <div style="font-size: 10px; margin-bottom: 5px;">
                Gen: ${selectedEntity.generation} | Age: ${selectedEntity.age.toFixed(1)}s<br>
                Energy: ${selectedEntity.energy.toFixed(1)} | Children: ${selectedEntity.children.length}
                ${selectedEntity.isHybrid ? '<br><span style="color: #ffff00;">⚡ HYBRID</span>' : ''}
                ${selectedEntity.lastMeal ? `<br>Last meal: ${selectedEntity.lastMeal}` : ''}
                ${selectedEntity.currentAction ? `<br>Action: ${selectedEntity.currentAction.type}` : ''}
            </div>
            <div style="font-size: 9px; margin-top: 8px;">
                <b>Genetic Traits:</b><br>
        `;
        
        for (let [trait, value] of Object.entries(genes)) {
            const percent = (value * 100).toFixed(0);
            html += `
                ${trait}: ${percent}%
                <div class="trait-bar">
                    <div class="trait-fill" style="width: ${percent}%"></div>
                </div>
            `;
        }
        
        if (selectedEntity.parent1) {
            html += `<br><b>Parents:</b> #${selectedEntity.parent1.id}`;
            if (selectedEntity.parent2) {
                html += ` & #${selectedEntity.parent2.id}`;
            }
        }
        
        html += `</div>`;
        infoDiv.innerHTML = html;
    } else {
        document.getElementById('entityInfo').style.display = 'none';
    }
});

// Controls
const keys = {};
window.addEventListener('keydown', (e) => {
    keys[e.key] = true;
    if (e.key === ' ') {
        e.preventDefault();
        isPaused = !isPaused;
    }
});
window.addEventListener('keyup', (e) => keys[e.key] = false);

canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    camera.zoom = Math.max(0.3, Math.min(2.5, camera.zoom + (e.deltaY < 0 ? 0.1 : -0.1)));
});

document.getElementById('restart').addEventListener('click', initWorld);

let speedLevel = 0;
const speeds = [1, 2, 5, 10];
document.getElementById('speedUp').addEventListener('click', function() {
    speedLevel = (speedLevel + 1) % speeds.length;
    timeSpeed = speeds[speedLevel];
    this.textContent = `Speed: ${timeSpeed}x`;
});

function updateCamera() {
    const speed = 8 / camera.zoom;
    if (keys['w'] || keys['ArrowUp']) camera.y -= speed;
    if (keys['s'] || keys['ArrowDown']) camera.y += speed;
    if (keys['a'] || keys['ArrowLeft']) camera.x -= speed;
    if (keys['d'] || keys['ArrowRight']) camera.x += speed;
}

function update() {
    const now = Date.now();
    let deltaTime = Math.min((now - lastTime) / 1000, 0.1);
    lastTime = now;
    
    if (!isPaused) {
        deltaTime *= timeSpeed;
        simulationTime += deltaTime;
        
        // Update signals
        const activeSignals = [];
        for (let signal of signals) {
            if (signal.update(deltaTime)) {
                activeSignals.push(signal);
            }
        }
        signals.length = 0;
        signals.push(...activeSignals);
        
        // Update entities
        updateEntities(deltaTime);
        
        // Reproduction check
        const checkedPairs = new Set();
        for (let i = 0; i < entities.length; i++) {
            for (let j = i + 1; j < entities.length; j++) {
                const e1 = entities[i];
                const e2 = entities[j];
                const pairKey = `${Math.min(e1.id, e2.id)}-${Math.max(e1.id, e2.id)}`;
                
                if (!checkedPairs.has(pairKey) && 
                    e1.distanceTo(e2) < 30 &&
                    e1.energy > 70 && e2.energy > 70 &&
                    e1.reproductionCooldown === 0 && e2.reproductionCooldown === 0) {
                    reproduce(e1, e2);
                    checkedPairs.add(pairKey);
                }
            }
        }
        
        // Respawn resources in territories
        for (let society of Object.values(societies)) {
            const t = society.territory;
            const foodInTerritory = resources.filter(r => 
                r.x >= t.x && r.x <= t.x + t.width &&
                r.y >= t.y && r.y <= t.y + t.height &&
                r.amount > 0
            ).length;
            
            if (foodInTerritory < 20 && Math.random() < 0.2 * timeSpeed) {
                const foodType = Math.random() < 0.7 ? society.preferredFood[0] : 'universal';
                resources.push(new Resource(
                    t.x + Math.random() * t.width,
                    t.y + Math.random() * t.height,
                    foodType
                ));
            }
        }
    }
}

function draw() {
    ctx.fillStyle = '#0a0a12';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    
    ctx.save();
    ctx.translate(canvas.width / 2, canvas.height / 2);
    ctx.scale(camera.zoom, camera.zoom);
    ctx.translate(-camera.x, -camera.y);
    
    //territories with environment effects
    for (let society of Object.values(societies)) {
        const t = society.territory;
        const centerX = t.x + t.width / 2;
        const centerY = t.y + t.height / 2;
        const radius = Math.max(t.width, t.height) * 0.8;

        const gradient = ctx.createRadialGradient(centerX, centerY, 0, centerX, centerY, radius);

        if (society.name === "Triangles") {
            gradient.addColorStop(0, 'rgba(60, 20, 20, 0.6)');
            gradient.addColorStop(1, 'rgba(60, 20, 20, 0)');
        } else if (society.name === "Circles") {
            gradient.addColorStop(0, 'rgba(20, 60, 30, 0.6)');
            gradient.addColorStop(1, 'rgba(20, 60, 20, 0)');
        } else {//squares
            gradient.addColorStop(0, 'rgba(20, 40, 60, 0.6)');
            gradient.addColorStop(1, 'rgba(20, 40, 60, 0)');
        }
        //soft glow
        ctx.fillStyle = gradient;
        ctx.fillRect(t.x - 200, t.y - 200, t.width + 400, t.height + 400);

        //faint border to show boundaries
        ctx.strokeStyle = society.color;
        ctx.globalAlpha = 0.2;
        ctx.lineWidth = 2;
        ctx.strokeRect(t.x, t.y, t.width, t.height);
        ctx.globalAlpha = 1.0;

        ctx.fillStyle = 'rgba(255, 255, 255, 0.5)';
        ctx.font = `bold ${30}px Arial`;
        ctx.textAlign = 'center';
        ctx.fillText(society.name.toUpperCase(), centerX, centerY);
                // Environment background
        const envColors = {
            'Volcanic Wasteland': 'rgba(255, 100, 50, 0.08)',
            'Lush Gardens': 'rgba(100, 255, 150, 0.08)',
            'Crystal Caverns': 'rgba(150, 255, 200, 0.08)'
        };
        
        ctx.fillStyle = envColors[society.environment.name];
        ctx.fillRect(t.x, t.y, t.width, t.height);
        
        ctx.strokeStyle = society.color + '40';
        ctx.lineWidth = 3 / camera.zoom;
        ctx.strokeRect(t.x, t.y, t.width, t.height);
        
        // Territory label
        ctx.fillStyle = society.color;
        ctx.font = `bold ${20 / camera.zoom}px Arial`;
        ctx.textAlign = 'center';
        ctx.fillText(society.name, t.x + t.width / 2, t.y - 20 / camera.zoom);
        
        // Environment info
        ctx.font = `${12 / camera.zoom}px Arial`;
        ctx.fillStyle = 'rgba(0, 0, 0, 0.6)';
        ctx.fillText(society.environment.name, t.x + t.width / 2, t.y - 5 / camera.zoom);
    }
    
    // Draw resources
    for (let resource of resources) {
        resource.draw(ctx, camera);
    }
    
    // Draw communication signals
    for (let signal of signals) {
        signal.draw(ctx, camera);
    }
    
    // Draw entities
    for (let entity of entities) {
        entity.draw(ctx, camera);
        
        if (entity === selectedEntity) {
            ctx.strokeStyle = '#ffff00';
            ctx.lineWidth = 3 / camera.zoom;
            ctx.beginPath();
            ctx.arc(entity.x, entity.y, 18 / camera.zoom, 0, Math.PI * 2);
            ctx.stroke();
        }
    }
    
    ctx.restore();
    
    // Update UI
    const minutes = Math.floor(simulationTime / 60);
    const seconds = Math.floor(simulationTime % 60);
    document.getElementById('timer').textContent = 
        `${minutes}:${seconds.toString().padStart(2, '0')}`;
    document.getElementById('generation').textContent = 
        `Max Generation: ${maxGeneration} | Total: ${entities.length}`;
    
    // Stats
    let statsHTML = '<div style="font-size: 13px; font-weight: bold; margin-bottom: 10px;">SOCIETIES</div>';
    for (let society of Object.values(societies)) {
        const pop = entities.filter(e => e.society === society);
        const hybrids = pop.filter(e => e.isHybrid).length;
        const avgGen = pop.length > 0 ? (pop.reduce((sum, e) => sum + e.generation, 0) / pop.length).toFixed(1) : 0;
        const avgEnergy = pop.length > 0 ? (pop.reduce((sum, e) => sum + e.energy, 0) / pop.length).toFixed(1) : 0;
        const children = pop.reduce((sum, e) => sum + e.children.length, 0);
        
        statsHTML += `
            <div class="society">
                <div class="society-name" style="color: ${society.color}">${society.name}</div>
                <div class="stat">Pop: ${pop.length} (${hybrids} hybrids)</div>
                <div class="stat">Avg Gen: ${avgGen} | Avg Energy: ${avgEnergy}</div>
                <div class="stat">Children: ${children}</div>
                <div class="stat" style="font-size: 9px; opacity: 0.7; margin-top: 3px;">
                    ${society.environment.name}<br>
                    Diet: ${society.preferredFood.join(', ')}
                </div>
            </div>
        `;
    }
    document.getElementById('stats').innerHTML = statsHTML;
}

function gameLoop() {
    updateCamera();
    update();
    draw();
    requestAnimationFrame(gameLoop);
}

// Initialize
initBackend();
initWorld().then(() => {
    gameLoop();
}).catch(error => {
    console.error('Error initializing world:', error);
    gameLoop(); // Start with empty world
});