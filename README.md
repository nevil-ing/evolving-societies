# Evolving Societies

An artificial life simulation where three societies (Triangles, Circles and Squares) compete for scarce food. Each creature thinks with a small piece of a real fruit fly brain.

Every entity runs its own copy of a smell → steer → feed circuit taken from the [FlyWire](https://flywire.ai) whole-brain connectome of *Drosophila melanogaster*: 1,597 real neurons and 31,714 real connections. On top of that sits a small evolved network for social choices: forage, fight, mate, socialize or flee. Food is scarce and keeps moving, so everyone has to find it, compete for it and leave chemical signals for their own kind.

Written in Zig with raylib.

![Evolving Societies](docs/screenshot.png)

## What we're trying to do

The goal is behaviour that **emerges** instead of being scripted. Nothing in the code tells an entity to follow a trail, guard a food patch or avoid where others died. What exists:

- **A real nervous system.** Odour and taste neurons feed into the fly's own wiring, and the steering, walking and feeding neurons drive the body. The connections and their signs (excitatory or inhibitory) come straight from the connectome.
- **Chemistry.** Food gives off scent. After eating, an entity lays a trail for its society. Fights and deaths release alarm pheromone. All of it spreads and fades over time.
- **Scarcity.** Food grows in patches that run out and reappear somewhere else. You can push the world from abundant down to famine.
- **Evolution.** Children inherit a mix of their parents' genes with mutations: body traits, social-network weights, and a gain for each of the 417 fly cell types. Evolution tunes the circuit without rewiring it.

The question is what kinds of societies come out of that. Do trail-followers win? Do aggressive lineages take over neighbouring land? Do hybrids between societies do better? Run it and watch.

## How the fly circuit is wired in

- **Sensing.** Two antennae sample the chemical fields on either side of the head. Their signals drive attractive odour receptor neurons (glomeruli DM1, DM2, DM4, VA2, VM2) and aversive ones (V for CO₂, DA2 for geosmin). Touching food drives sugar or bitter taste neurons, depending on whether that society can digest it. Receptor input adapts to the background smell level, as real olfactory neurons do.
- **Acting.** The left/right balance of the DNa01/DNa02 descending neurons steers. DNp09 drives walking, MDN backs up, and the giant fibre triggers escape bursts. An entity only eats while the MN9 proboscis motor neuron fires.
- **Dynamics.** Each copy is simulated as a rate model at 20 Hz, spread across CPU cores.

In a controlled test (a food patch 150 units away, social behaviour switched off), entities steered by the fly circuit reached the food more than twice as often as entities that wandered.

## Building

Requires [Zig 0.17.0](https://ziglang.org/download/). raylib 6.2 is fetched by the build.

```bash
cd sim
zig build run -Doptimize=ReleaseFast
```

Tests:

```bash
zig build test -Doptimize=ReleaseFast              # circuit and world checks
zig build test -Doptimize=ReleaseFast -Dslow=true  # plus chemotaxis and long multi-seed runs
```

`zig-out/bin/evolving-societies --shot out.png 120` simulates 120 seconds, saves a screenshot and exits.

<details>
<summary>macOS: build fails fetching <code>xcode_frameworks</code></summary>

raylib depends on a macOS frameworks package hosted at `pkg.machengine.org`, and Zig's HTTP client fails the TLS handshake with that server on some machines. Download it with curl and place it in the Zig cache under the hash raylib pins:

```bash
H=N-V-__8AALShqgXkvqYU6f__FrA22SMWmi2TXCJjNTO1m8XJ
curl -L -o xf.tar.gz https://pkg.machengine.org/xcode-frameworks/8a1cfb373587ea4c9bb1468b7c986462d8d4e10e.tar.gz
mkdir -p $H && tar xzf xf.tar.gz -C $H --strip-components=1
CACHE=$(zig env | sed -n 's/.*\.global_cache_dir = "\(.*\)",/\1/p')
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf "$CACHE/p/$H.tar.gz" $H
```

Zig still checks the hash when it unpacks the package.
</details>

## Controls

| Input | Action |
| --- | --- |
| WASD / arrows, right-drag | Pan |
| Mouse wheel | Zoom |
| Click | Inspect an entity: senses, fly motor output, genes, live neuron activity |
| C | Follow the selected entity |
| B | Toggle the neuron view |
| P | Overlay: trails and alarm / food scent / off |
| F | Food level |
| + / − | Speed (1–16×) |
| Space | Pause |
| R | New world |

## Project layout

```
sim/
  src/flybrain.zig     fly circuit loader and rate model
  src/genome.zig       genes, social network, crossover and mutation
  src/pheromone.zig    diffusing chemical fields
  src/world.zig        societies, food, sensing, behaviour, reproduction
  src/main.zig         rendering, camera, UI
  src/tests.zig
  assets/flybrain.bin  extracted circuit (see below)
tools/
  extract_circuit.py   builds flybrain.bin from the FlyWire data
```

## Rebuilding the circuit

`sim/assets/flybrain.bin` is checked in. To regenerate it, download the source tables (about 135 MB) and run the extractor:

```bash
mkdir -p data/flywire && cd data/flywire
curl -LO https://raw.githubusercontent.com/philshiu/Drosophila_brain_model/main/Connectivity_783.parquet
curl -LO https://raw.githubusercontent.com/philshiu/Drosophila_brain_model/main/Completeness_783.csv
curl -L -o neuron_annotations.tsv https://raw.githubusercontent.com/flyconnectome/flywire_annotations/main/supplemental_files/Supplemental_file1_neuron_annotations.tsv
cd ../..
uv run --no-project --with numpy --with scipy --with pandas --with pyarrow python tools/extract_circuit.py
```

The extractor keeps the neurons on the strongest paths from the chosen sensory neurons to the chosen motor and descending neurons. Before writing the file, it runs a quick check that sugar drives feeding, bitter doesn't, and odour steers.

## Data and credits

The circuit is derived from FlyWire connectome release v783 and is distributed under [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) (see [`sim/assets/DATA_LICENSE.md`](sim/assets/DATA_LICENSE.md)). Please cite:

- Dorkenwald et al. (2024). Neuronal wiring diagram of an adult brain. *Nature*.
- Schlegel et al. (2024). Whole-brain annotation and multi-connectome cell typing of *Drosophila*. *Nature*.
- Shiu et al. (2024). A *Drosophila* computational brain model reveals sensorimotor processing. *Nature*. The connectivity table and the MN9 and sugar-neuron identities come from [philshiu/Drosophila_brain_model](https://github.com/philshiu/Drosophila_brain_model).
- Cell-type annotations: [flyconnectome/flywire_annotations](https://github.com/flyconnectome/flywire_annotations).
