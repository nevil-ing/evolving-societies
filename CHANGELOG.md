# Changelog

All notable milestones in **Evolving Societies** are documented here.

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
