# Evolving Societies

A native, real-time artificial-life sandbox where societies — starting as **Triangles**, **Circles**, and **Squares** and capable of speciating into **up to 16 distinct clades** — live, learn, speak, trade, fight disease, build settlements, and evolve across generations in a closed-loop 2D miniverse.

Built in Zig with raylib as a fast, standalone desktop app with zero external runtime dependencies.

![Evolving Societies](docs/screenshot.png)

## What It's About

Instead of scripting fixed rules for every behavior, *Evolving Societies* gives creatures senses, chemical fields, biological immunity, physical needs, and plastic neural networks — then lets survival, learning, and natural selection shape what happens next.

You can sit back with the **Auto-Director (`V`)** documentary camera and watch lineages adapt over hours, click any individual to inspect its mind, diet, antibodies, and memories live, run deep-time headless evolutions saved to `.esav` snapshots, or step in as an experimenter to trigger storms, outbreaks, famine, predators, or seed new tribes.

## Key Features

- **Pure Neural Mode & Live Online Learning:** Every individual runs a growing, double-buffered leaky-recurrent neural network (36 inputs, 9 discrete actions + 7 continuous motor/vocal outputs) with NEAT innovation-aligned crossover and multi-layer neurogenesis. Through exploratory motor babbling, temporal-difference bootstrapping, and dopamine-modulated ABCD Hebbian plasticity, individuals adapt *during* their lifetime while evolution grows new circuits across generations. Runs in **Pure Neural** mode by default (zero steering autopilot), with a live **Assisted** toggle in Experiment Controls (`E`).
- **Closed-Loop Biogeochemical Miniverse:** Rather than spawning food from arbitrary timers, biomass cycles like a miniature Earth: **soil nutrients** and **soil moisture** drive living **plant photosynthesis** and organic seed spread, storms recharge moisture and weather **stone outcrops** into **mineral** crystals, living metabolism returns diffusing organic **waste** (driving crowding stress & migrations before decomposing microbially back into rich soil), **Wild Prey** graze plants and reproduce calves, and every **corpse** either feeds scavengers or rots directly back into fertile loam.
- **Unlimited Dynamic Speciation & Honest Morphology:** Starting from 3 founder societies, lineages can evolve their own **digestive specialization** (meat/plant/mineral simplex), **Wyatt 4-channel chemical signatures**, and **Kleiber-scaled body sizes** across 6 physical body shapes (`triangle`, `circle`, `square`, `diamond`, `pentagon`, `hexagon`) with real speed, agility, energy-capacity, and storm-insulation trade-offs. Diverged lineages bud new clades automatically (up to 16) with reproductive isolation, or you can drop fresh tribes live with **`Seed New Tribe (+10)`**.
- **Emergent Language & Evolving Dialects:** Pure Neural vocalizations use an unscripted 3-channel continuous acoustic space (`call_out` volume + 3 formants rendered as RGB speech ripples) with directional hearing, cross-society eavesdropping, and joint-attention-gated youth imitation — allowing distinct regional dialects and context-specific calls to diverge organically.
- **Individual Immune System, Pathogens & Medicinal Herbs:** Every creature carries polymorphic 8-locus innate **MHC genes** and 4 cross-reactive **adaptive antibody** slots, passing 40% passive immunity to newborns. Mutating pathogens emerge from unsanitary overcrowding and spread faster inside shelters (`2.2×`), creating a real evolutionary trade-off against storm warmth and predator safety. Rare frontier **Medicinal Herbs** trigger sick-state self-medication, boosting antibody synthesis `3.2×`.
- **Emergent Gift & Barter Economy:** An unscripted `offer` action lets creatures hand portable **food packs**, **medicinal herbs**, **wood**, **stone**, or surplus energy to kin or neighboring clades under Axelrod/Riolo reciprocity payoffs ($c/b \le 0.30$), tracked via social trust bonds, direct-reciprocity defection penalties, and glowing gold-cyan transfer arcs.
- **Episodic Mental Maps, Culture, Tools & Ruins:** Creatures remember up to 6 spatial landmarks, clear stale beliefs on empty arrival, share memories on contact, and pass down skills and multi-step crafts (**Baskets**, **Spears**, **Shelters**, **Food Caches**) through juvenile observational imitation and elder mentoring. Unrepaired settlements decay into **abandoned ruins** that migrating clades can rediscover and reclaim.
- **Deep-Time Workbench (`--save` / `--load`), Auto-Director (`V`) & Analytics:** Save and resume complete binary `.esav` world snapshots (`K`/`O` in-app or `--save`/`--load` via CLI), follow live ecological drama automatically with **Auto-Director (`V`)**, experiment in the **Specimen Lab (`T`)** and **Experiment Controls (`E`)**, and analyze CSV telemetry with information-theoretic dialect metrics and zero-dependency **SVG Muller plots** (`tools/analyze_run.py --svg`).

## Download & Run (macOS)

Grab the latest **`Evolving-Societies-macOS.dmg`** from the [Releases](https://github.com/nevil-ing/evolving-societies/releases) page:

1. Open `Evolving-Societies-macOS.dmg` and drag **Evolving Societies** into **Applications**.
2. Launch it from **Applications**, **Spotlight**, or **Launchpad**.
   *(Because the app is ad-hoc signed without an Apple Developer certificate, on first launch macOS may ask you to right-click the app → **Open**, or allow it once under **System Settings → Privacy & Security**.)*

When launched as a macOS app, run telemetry CSVs are saved automatically to `~/Library/Application Support/Evolving Societies/runs/`.

## Building from Source

Requires [Zig 0.17.0](https://ziglang.org/download/). `raylib 6.2` is fetched automatically by the build system.

```bash
cd sim
zig build run -Doptimize=ReleaseFast
```

### Build the Native macOS `.app` & `.dmg`

```bash
./tools/package_macos_app.sh --install --dmg
```

This compiles a `ReleaseFast` binary, generates the Retina `AppIcon.icns`, assembles `dist/Evolving Societies.app`, installs it into `/Applications/Evolving Societies.app`, and creates `dist/Evolving-Societies-macOS.dmg`.

### Headless Runs, Snapshots, Screenshots & Tests

```bash
# Headless 10-minute evolution with binary snapshot + SVG Muller plot
./sim/zig-out/bin/evolving-societies --headless 600 --seed 8080 --out run.csv --save world.esav
python3 tools/analyze_run.py run.csv --svg muller.svg

# Load an evolved binary snapshot live into the interactive desktop app
./sim/zig-out/bin/evolving-societies --load world.esav

# Capture a Retina screenshot after simulating 180s
./sim/zig-out/bin/evolving-societies --seed 8080 --shot docs/screenshot.png 180 1.05

# Run the test suite
cd sim
zig build test -Doptimize=ReleaseFast              # 31 fast unit, immunity, economy & snapshot checks
zig build test -Doptimize=ReleaseFast -Dslow=true  # all 33 tests incl. chemotaxis & 6-seed 10-min worlds
```

<details>
<summary>macOS troubleshooting: build fails fetching <code>xcode_frameworks</code></summary>

If Zig's HTTP client fails the TLS handshake with `pkg.machengine.org`, download the package with `curl` into the Zig global cache:

```bash
H=N-V-__8AALShqgXkvqYU6f__FrA22SMWmi2TXCJjNTO1m8XJ
curl -L -o xf.tar.gz https://pkg.machengine.org/xcode-frameworks/8a1cfb373587ea4c9bb1468b7c986462d8d4e10e.tar.gz
mkdir -p $H && tar xzf xf.tar.gz -C $H --strip-components=1
CACHE=$(zig env | sed -n 's/.*\.global_cache_dir = "\(.*\)",/\1/p')
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf "$CACHE/p/$H.tar.gz" $H
```

</details>

## Controls

| Input | Action |
| --- | --- |
| `WASD` / arrows, right-drag | Pan camera |
| Mouse wheel / `[` `]` / `0` | Zoom / fit whole world |
| Left-click | Select & inspect an individual (genes, diet, health/antibodies, skills, live mind graph, mental map) |
| `V` | Toggle **Auto-Director** documentary camera (smoothly tracks live ecological drama) |
| `K` / `O` | Quick-save / quick-load binary world snapshot (`world_snapshot.esav`) |
| `C` | Follow selected individual |
| `B` | Toggle live brain visualization in Inspector |
| `E` | Open **Experiment Controls** (Pure Neural toggle, Seed New Tribe, Trigger Outbreak, spawning, food, weather, wildlife) |
| `T` | Open **Specimen Lab** (capture, compare, edit traits/skills, mutate, clone) |
| `G` | Open **History & Generations** panel |
| `H` | Toggle territory corner brackets |
| `L` | Toggle world legend / key |
| `P` | Cycle chemical overlays (trails & alarm / food scent / off) |
| `F` | Cycle food scarcity (`feast` / `abundant` / `normal` / `scarce` / `famine`) |
| `+` / `-` | Simulation speed (`1×` up to `64×`) |
| `Space` | Pause / resume |
| `R` | Start a new world |

## Project Layout

```text
sim/
  src/world.zig        societies, ecology, physics, wildlife, structures, tools, memory & learning
  src/genome.zig       traits, growing recurrent CognitiveBrain, node-perturbation & ABCD plasticity
  src/pheromone.zig    diffusing chemical fields (scent, trails, alarm)
  src/flybrain.zig     embedded sensorimotor brainstem circuit rate model
  src/logger.zig       automatic CSV telemetry exporter
  src/life_view.zig    2D renderer, HUD, Inspector, Specimen Lab, Experiment Controls & History
  src/ui.zig           Retina HiDPI helpers, font loading, camera & screenshot capture
  src/main.zig         CLI entry point (interactive, --headless, --shot)
  src/tests.zig        unit, online-learning, chemotaxis & multi-seed survival tests
  assets/flybrain.bin  pre-built binary sensorimotor circuit
tools/
  package_macos_app.sh builds native macOS .app bundle, /Applications install & .dmg
  make_icon.py         generates Retina AppIcon.icns
  analyze_run.py       summarizes CSV run telemetry (trait drift, skills, brain growth, roles)
  extract_circuit.py   rebuilds sim/assets/flybrain.bin from source connectivity tables
```

## Credits & License

The bundled low-level sensorimotor brainstem data (`sim/assets/flybrain.bin`) is derived from [FlyWire](https://flywire.ai) connectome release v783 (Dorkenwald et al. 2024; Schlegel et al. 2024; Shiu et al. 2024) and is distributed under [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) — see [`sim/assets/DATA_LICENSE.md`](sim/assets/DATA_LICENSE.md) for full citations.
