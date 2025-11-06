# Evolving Societies

A neural network-based artificial life simulation with FastAPI backend and HTML5 canvas frontend.

## Setup

### Backend

1. Navigate to the backend directory:
```bash
cd backend
```

2. Install dependencies using uv (or pip):
```bash
uv sync
# or
pip install -r requirements.txt
```

3. Run the FastAPI server:
```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
# or
python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

The backend will be available at `http://localhost:8000`

### Frontend

1. Open `frontend/index.html` in a web browser, or serve it using a local web server:

```bash
# Using Python
cd frontend
python -m http.server 8080

# Using Node.js
npx http-server -p 8080
```

2. Open `http://localhost:8080` in your browser

## Features

- **Neural Network AI**: Entities use neural networks for decision-making
- **Evolution**: Entities reproduce and evolve over generations
- **Multiple Societies**: Three different societies with unique traits
- **Real-time Communication**: WebSocket connection for real-time updates
- **REST API**: Full REST API for entity management and simulation control

## API Endpoints

- `GET /` - API status
- `GET /health` - Health check
- `GET /api/entities/` - List all entities
- `POST /api/entities/` - Create new entity
- `GET /api/entities/{id}` - Get entity details
- `POST /api/entities/decision` - Make decision for entity
- `POST /api/entities/reproduce` - Reproduce entities
- `POST /api/simulation/reset` - Reset simulation
- `GET /api/simulation/status` - Get simulation status
- `GET /api/statistics/` - Get statistics
- `WebSocket /ws` - Real-time WebSocket connection

## Controls

- **WASD** or **Arrow Keys**: Move camera
- **Mouse Wheel**: Zoom in/out
- **Space**: Pause/Resume simulation
- **Click Entity**: View entity details
- **Restart Button**: Reset simulation
- **Speed Button**: Change simulation speed

## Architecture

- **Backend**: FastAPI with PyTorch for neural networks
- **Frontend**: Vanilla JavaScript with HTML5 Canvas
- **Communication**: WebSocket for real-time updates, REST API for state management

