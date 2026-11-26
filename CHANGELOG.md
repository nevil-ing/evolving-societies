# Changelog

All notable milestones in **Evolving Societies** are documented here.

## v0.2.0 — 2026-11-26

### Highlights
- **Closed-Loop Biogeochemical Miniverse:**
  - Replaced spontaneous relocating timer-based food patches in live worlds with a conserved Earth-like nutrient & matter cycle: `soil_nutrients` and `soil_moisture` grids (subtly rendered as living loam), diffusing organic `waste` that decomposes microbially back into soil fertility, living plant photosynthesis & seed spread, stone-outcrop geological mineral weathering, grazing/reproducing Wild Prey herds, and full corpse-to-soil biomass conservation.
- **Unlimited Dynamic Speciation, Honest Morphology & Wyatt $O(1)$ Pheromones:**
  - Unlocked dynamic clade budding up to 16 concurrent societies (`Clade 4+`) with cladogenesis recruiting nearby matching kin, reproductive isolation (`geneticDist > 0.68`), Bedau persistence filtering, dynamic Top-3 HUD ranking, and **`Seed New Tribe (+10)`** in Experiment Controls (`E`).
  - Added continuous evolvable digestive specialization (`digest[3]` simplex), Kleiber-scaled `body_scale` allometry, 6 body shapes (`triangle`, `circle`, `square`, `diamond`, `pentagon`, `hexagon`) with honest physical speed/agility/capacity/insulation trade-offs, and Wyatt (2010) 4-channel $O(1)$ chemical signature mixtures (`chem_sig[3]` + shared alarm).
- **Emergent Language & Evolving Dialects:**
  - Replaced scripted Pure Neural signal meanings with an unscripted 3-channel continuous vocal space (`call_out` + `call_f[0..3]`), directional acoustic bearing, cross-society eavesdropping, joint-attention-gated youth vocal imitation, RGB speech ripples, and live Voice/Heard swatches.
- **Individual Immune System, Mutating Pathogens, Medicinal Herbs & Ruins:**
  - Added polymorphic 8-locus innate `mhc` genes, 4-slot cross-reactive adaptive `Antibody` memory, 40% parental passive immunity, mutating pathogens (`12%` antigenic mutation on jump, `2.2×` contagion inside shelters), frontier **Medicinal Herbs** (`FoodType.herb`) with sick-state self-medication (`3.2×` antibody synthesis), **`Trigger Outbreak`** in `Exp (E)`, pulsing sickness halos, juvenile observational craft imitation, and reclaimable abandoned ruins.
- **Emergent Gift & Barter Economy:**
  - Added unscripted neural `SocialAction.offer`, `other_carrying` perception, and portable `food_pack`/`herb` cargo calibrated to Axelrod/Riolo reciprocity ($c/b \le 0.30$), with 45s `SocialBond` barter detection, cross-clade trade metrics, defection trust penalties, and glowing gold-cyan transfer arcs.
- **Plasticity Math Upgrades, 5× Speedup & Deep-Time Workbench:**
  - Fixed the negative-TD `hebb_d` sign-inversion bug, added TD bootstrapping, double-buffered the recurrent hidden layer, added lightweight NEAT innovation-aligned crossover and multi-layer neurogenesis, and accelerated core loops via CSC zero-skipping in `flybrain.zig` and `@Vector(8, f32)` SIMD diffusion in `pheromone.zig`.
  - Added deterministic binary world snapshots (`--save` / `--load`, plus `K`/`O` in-app), **Auto-Director (`V`)** documentary camera, and information-theoretic dialect analytics + zero-dependency **SVG Muller plots** (`tools/analyze_run.py --svg`).

## v0.1.0 — 2026-11-26

### Highlights
- **Pure Neural Mode (Default ON) & Live Online Learning:**
  - Replaced steering autopilots (`steerTo`), action speed floors, and hardcoded vocalization rules with continuous cortical outputs (`turn_out`, `speed_out`, `mod_out`, `call_out`) in a 28-input, 12-output growing recurrent `CognitiveBrain`.
  - Added songbird-LMAN-style exploratory motor babbling, Fiete-Seung node-perturbation eligibility traces, and Schultz-style anticipatory sensory dopamine so even blank-slate creatures learn online within seconds to turn toward visible/remembered food and evade predators.
  - Added a live **Pure Neural vs. Assisted** comparison toggle inside Experiment Controls (`E`).
- **Living Ecosystem, Wildlife & Territorial Stakes:**
  - Added solid mass-weighted wildlife collisions, hunting **Apex Predators** (radiating predator musk into alarm fields), roaming **Wild Prey**, physical **Shelter** barriers against predators, and cross-society **Food Cache** raiding & structure sieging.
  - Added renewable **Wood** & **Stone** deposits, emergent tool-making (**Baskets** & **Spears**), stigmergic building (**Shelters** & **Food Caches**), and dynamic 5-minute **Calm → Bloom → Storm** weather cycles.
- **Episodic Memory, Social Bonds & Culture:**
  - Added 6-slot episodic spatial memories (food, material, shelter, danger, prey) with belief updating on empty arrival, kin memory sharing, and 4-slot social trust bonds.
  - Added developmental life stages (**Infant → Juvenile → Adult → Elder**) paced to 1–2 hour lifespans, childhood learning windows, elder mentoring, communal childcare, inherited skills, and emergent colony roles.
- **Interactive Tools, Scaling & Native macOS App:**
  - Removed the 600-entity population cap with an $O(N)$ spatial hash grid.
  - Added the **Specimen Lab (`T`)** (capture, compare, edit traits/skills, mutate brains, release batches), **Experiment Controls (`E`)** (batch spawning, food floods/wipes, weather jumps, wildlife spawning), **History (`G`)** generation tracker, minimal corner-bracket territories (`H`), and automatic CSV telemetry (`tools/analyze_run.py`).
  - Added standalone native macOS `.app` bundling, Retina `AppIcon.icns`, `/Applications` installation, and drag-and-drop `.dmg` packaging (`./tools/package_macos_app.sh --install --dmg`).
