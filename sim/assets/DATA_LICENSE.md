# flybrain.bin / flybrain.json

These files contain a sub-circuit (1,597 neurons, 31,714 connections) extracted from the FlyWire connectome of an adult female *Drosophila melanogaster* (FAFB, materialization v783). They were produced by `tools/extract_circuit.py`, which:

- selects neurons on the strongest paths between chosen sensory neurons and chosen motor/descending neurons;
- keeps synapse counts and neurotransmitter-derived signs;
- groups neurons by annotated cell type.

FlyWire data is licensed under [Creative Commons Attribution-NonCommercial 4.0](https://creativecommons.org/licenses/by-nc/4.0/). These derived files carry the same licence: you may share and adapt them for non-commercial purposes, with attribution.

Sources:

- FlyWire Consortium. Dorkenwald et al. (2024), *Nature* 634, 124–138. Schlegel et al. (2024), *Nature* 634, 139–152. https://flywire.ai
- Connectivity table: Shiu et al. (2024), *Nature* 634, 210–219. https://github.com/philshiu/Drosophila_brain_model
- Annotations: https://github.com/flyconnectome/flywire_annotations
