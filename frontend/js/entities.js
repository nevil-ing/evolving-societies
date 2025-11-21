// Signal class for communication
class Signal {
    constructor(x, y, type, message) {
        this.x = x;
        this.y = y;
        this.type = type; // 'alert', 'food', 'help', 'mate'
        this.message = message;
        this.radius = 0;
        this.maxRadius = 150;
        this.lifetime = 2;
        this.age = 0;
    }
    
    update(dt) {
        this.age += dt;
        this.radius = (this.age / this.lifetime) * this.maxRadius;
        return this.age < this.lifetime;
    }
    
    draw(ctx, camera) {
        const screenX = this.x - camera.x;
        const screenY = this.y - camera.y;
        const alpha = 1 - (this.age / this.lifetime);
        
        const colors = {
            'alert': '#ff0000',
            'food': '#00ff00',
            'help': '#ffff00',
            'mate': '#ff00ff'
        };
        
        ctx.strokeStyle = colors[this.type] + Math.floor(alpha * 100).toString(16).padStart(2, '0');
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(screenX, screenY, this.radius * camera.zoom, 0, Math.PI * 2);
        ctx.stroke();
        
        if (alpha > 0.5) {
            ctx.fillStyle = colors[this.type];
            ctx.font = `${10 * camera.zoom}px Arial`;
            ctx.textAlign = 'center';
            ctx.fillText(this.message, screenX, screenY - this.radius * camera.zoom - 5);
        }
    }
}

// Resource class
class Resource {
    constructor(x, y, type) {
        this.x = x;
        this.y = y;
        this.type = type; // 'meat', 'plant', 'mineral', 'universal'
        this.amount = 100;
        this.respawnTime = 0;
    }
    
    draw(ctx, camera) {
        if (this.amount <= 0) return;
        const screenX = this.x - camera.x;
        const screenY = this.y - camera.y;
        const size = 6 * camera.zoom * (this.amount / 100);
        
        const colors = {
            'meat': '#ff6b6b',
            'plant': '#4ecdc4',
            'mineral': '#95e1d3',
            'universal': '#ffeb3b'
        };
        
        ctx.fillStyle = colors[this.type];
        ctx.beginPath();
        ctx.arc(screenX, screenY, size, 0, Math.PI * 2);
        ctx.fill();
        
        ctx.strokeStyle = 'rgba(0, 0, 0, 0.3)';
        ctx.lineWidth = 1;
        ctx.stroke();
    }
    
    distanceTo(entity) {
        const dx = this.x - entity.x;
        const dy = this.y - entity.y;
        return Math.sqrt(dx * dx + dy * dy);
    }
}

// Neural Network class (Client-side simplified version)
class NeuralNetwork {
    constructor(parent1Genes, parent2Genes) {
        if (parent1Genes && parent2Genes) {
            this.genes = {
                aggression: this.inherit(parent1Genes.aggression, parent2Genes.aggression),
                cooperation: this.inherit(parent1Genes.cooperation, parent2Genes.cooperation),
                resourceGathering: this.inherit(parent1Genes.resourceGathering, parent2Genes.resourceGathering),
                reproductionDrive: this.inherit(parent1Genes.reproductionDrive, parent2Genes.reproductionDrive),
                speed: this.inherit(parent1Genes.speed, parent2Genes.speed),
                efficiency: this.inherit(parent1Genes.efficiency, parent2Genes.efficiency),
                socialDistance: this.inherit(parent1Genes.socialDistance, parent2Genes.socialDistance),
                communication: this.inherit(parent1Genes.communication, parent2Genes.communication),
                adaptability: this.inherit(parent1Genes.adaptability, parent2Genes.adaptability),
                territoriality: this.inherit(parent1Genes.territoriality || 0.5, parent2Genes.territoriality || 0.5)
            };
        } else {
            this.genes = {
                aggression: Math.random(),
                cooperation: Math.random(),
                resourceGathering: Math.random(),
                reproductionDrive: Math.random(),
                speed: Math.random(),
                efficiency: Math.random(),
                socialDistance: Math.random(),
                communication: Math.random(),
                adaptability: Math.random(),
                territoriality: Math.random()
            };
        }
    }
    
    inherit(gene1, gene2) {
        const avg = (gene1 + gene2) / 2;
        const mutation = (Math.random() - 0.5) * 0.15;
        return Math.max(0, Math.min(1, avg + mutation));
    }
}

// Entity class
class Entity {
    constructor(x, y, society, parent1 = null, parent2 = null, generation = 1) {
        this.id = null; // Will be set by backend
        this.x = x;
        this.y = y;
        this.society = society;
        this.vx = 0;
        this.vy = 0;
        this.energy = 100;
        this.age = 0;
        this.generation = generation;
        this.parent1 = parent1;
        this.parent2 = parent2;
        this.children = [];
        this.reproductionCooldown = 0;
        this.communicationCooldown = 0;
        this.lastMeal = null;
        this.dietBonus = 0;

        
        // Initialize with random offset so they don't all ping server at once
        this.decisionTimer = Math.random() * 1.0; 
        // Store the last decision to persist action between server calls
        this.currentAction = null;
        
        
        if (parent1 && parent2) {
            this.brain = new NeuralNetwork(parent1.brain.genes, parent2.brain.genes);
            this.isHybrid = parent1.society !== parent2.society;
        } else {
            this.brain = new NeuralNetwork();
            this.isHybrid = false;
        }
        
        if (parent1) parent1.children.push(this);
        if (parent2 && parent2 !== parent1) parent2.children.push(this);
    }
    
    distanceTo(other) {
        const dx = this.x - other.x;
        const dy = this.y - other.y;
        return Math.sqrt(dx * dx + dy * dy);
    }
    
    moveTo(x, y, speed) {
        const dx = x - this.x;
        const dy = y - this.y;
        const dist = Math.sqrt(dx * dx + dy * dy);
        if (dist > 0) {
            this.vx = (dx / dist) * speed;
            this.vy = (dy / dist) * speed;
        }
    }
    
    canEatResource(resource) {
        const preferredFood = this.society.preferredFood;
        if (resource.type === 'universal') return true;
        if (preferredFood.includes(resource.type)) return true;
        
        if (this.isHybrid || this.brain.genes.adaptability > 0.7) {
            return Math.random() < 0.5;
        }
        
        return false;
    }
    
    draw(ctx, camera) {
        const screenX = this.x - camera.x;
        const screenY = this.y - camera.y;
        const size = 9 * camera.zoom;
        
        ctx.save();
        ctx.translate(screenX, screenY);
        
        if (this.isHybrid) {
            ctx.shadowBlur = 10;
            ctx.shadowColor = '#ffff00';
        }
        
        this.society.drawShape(ctx, size, this.energy / 100);
        ctx.shadowBlur = 0;
        
        if (this.generation > 1) {
            ctx.fillStyle = 'rgba(255, 255, 255, 0.9)';
            ctx.font = `${7 * camera.zoom}px Arial`;
            ctx.textAlign = 'center';
            ctx.fillText(`G${this.generation}`, 0, size + 10);
        }
        
        ctx.fillStyle = 'rgba(0, 0, 0, 0.3)';
        ctx.fillRect(-size, -size - 6, size * 2, 3);
        ctx.fillStyle = this.energy > 50 ? '#00ff00' : this.energy > 25 ? '#ffff00' : '#ff0000';
        ctx.fillRect(-size, -size - 6, size * 2 * (Math.min(this.energy, 100) / 100), 3);
        
        ctx.restore();
    }
}