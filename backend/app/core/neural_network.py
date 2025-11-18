import torch
import torch.nn as nn
import numpy as np

class EntityBrain(nn.Module):
    """Neural network model for entity decision making."""

    def __init__(self, input_size: int = 20, hidden_size: int = 64, output_size: int = 5):
        super(EntityBrain, self).__init__()

        
        self.fc1 = nn.Linear(input_size, 128)     
        self.ln1 = nn.LayerNorm(128)
        self.fc2 = nn.Linear(128, 256)    
        self.ln2 = nn.LayerNorm(256)
        self.fc3 = nn.Linear(256, 512)    
        self.ln3 = nn.LayerNorm(512)
        self.fc4 = nn.Linear(512, 256)    
        self.ln4 = nn.LayerNorm(256)
        self.fc5 = nn.Linear(256, 128)    
        self.ln5 = nn.LayerNorm(128)
        self.fc6 = nn.Linear(128, 5)      

        self.relu = nn.ReLU()
        self.dropout = nn.Dropout(p=0.2)
        self.softmax = nn.Softmax(dim=-1)

    def forward(self, x):
        """Process inputs and return action probabilities."""
        x = self.relu(self.ln1(self.fc1(x)))
        x = self.relu(self.ln2(self.fc2(x)))
        x = self.dropout(x)
        x = self.relu(self.ln3(self.fc3(x)))
        x = self.relu(self.ln4(self.fc4(x)))
        x = self.dropout(x)
        x = self.relu(self.ln5(self.fc5(x)))
        x = self.softmax(self.fc6(x))
        return x

    def mutate(self, mutation_rate: float = 0.1, mutation_strength: float = 0.05):
        with torch.no_grad():
            for param in self.parameters():
                if np.random.random() < mutation_rate:
                    noise = torch.randn_like(param) * mutation_strength
                    param.add_(noise)

    @staticmethod
    def crossover(parent1: 'EntityBrain', parent2: 'EntityBrain') -> 'EntityBrain':
        """
        Create a child brain from two parents via crossover.
        Randomly selects weights from each parent.
        """
        child = EntityBrain()
        with torch.no_grad():
            for child_param, p1_param, p2_param in zip(
                child.parameters(), parent1.parameters(), parent2.parameters()
            ):
                mask = torch.rand_like(p1_param) > 0.5
                child_param.copy_(torch.where(mask, p1_param, p2_param))
        return child


