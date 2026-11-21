#!/usr/bin/env python3
"""Analyze an Evolving Societies telemetry CSV for emergent evolution signals.

Usage:
    python3 tools/analyze_run.py data/world_states/run_<seed>.csv
"""

import csv
import sys
from collections import defaultdict
from pathlib import Path


def f(row, key):
    return float(row[key])


def main():
    if len(sys.argv) < 2:
        runs = sorted(Path("data/world_states").glob("run_*.csv"), key=lambda p: p.stat().st_mtime)
        if not runs:
            raise SystemExit("Usage: python3 tools/analyze_run.py <path/to/run.csv>")
        path = runs[-1]
        print(f"Analyzing latest run: {path}\n")
    else:
        path = Path(sys.argv[1])

    by_soc = defaultdict(list)
    with path.open() as fh:
        for row in csv.DictReader(fh):
            by_soc[row["society"]].append(row)

    for soc, rows in by_soc.items():
        first = rows[0]
        alive = [r for r in rows if int(r["pop"]) > 0]
        last = alive[-1] if alive else rows[-1]
        end = rows[-1]

        storm_rows = [r for r in alive if r["phase"] == "storm"]
        calm_rows = [r for r in alive if r["phase"] != "storm"]
        storm_hud = sum(f(r, "huddled_frac") for r in storm_rows) / max(len(storm_rows), 1)
        calm_hud = sum(f(r, "huddled_frac") for r in calm_rows) / max(len(calm_rows), 1)

        print(f"=== {soc} ===")
        print(
            f"  Duration: {f(end, 'time')/60:.1f} min | Final pop: {end['pop']} "
            f"(peak {max(int(r['pop']) for r in rows)}) | Max gen: {end['max_gen']} | "
            f"Active lineages: {end['active_lineages']}"
        )
        print(
            f"  Totals: births={end['births']} starved={end['starved']} "
            f"old_age={end['old_age']} killed={end['killed']} hybrids={end['hybrids']}"
        )
        print("  Trait drift (start -> last alive):")
        for k, label in [
            ("avg_efficiency", "efficiency"),
            ("avg_adaptability", "adaptability"),
            ("avg_fertility", "fertility"),
            ("avg_territoriality", "territoriality"),
            ("avg_aggression", "aggression"),
            ("avg_trail_output", "trail_output"),
        ]:
            a, b = f(first, k), f(last, k)
            print(f"    {label:<15} {a:.3f} -> {b:.3f} ({b - a:+.3f})")
        print("  Learned skills & cognitive brain (start -> last alive):")
        for k, label in [
            ("avg_foraging", "foraging"),
            ("avg_navigation", "navigation"),
            ("avg_combat", "combat"),
            ("avg_care", "care"),
        ]:
            print(f"    {label:<15} {f(first, k)*100:5.1f}% -> {f(last, k)*100:5.1f}%")
        print(
            f"    {'cog neurons':<15} {f(first, 'avg_neurons'):5.1f}  -> {f(last, 'avg_neurons'):5.1f}  "
            f"| synapses {f(first, 'avg_synapses'):5.1f} -> {f(last, 'avg_synapses'):5.1f}"
        )
        print(
            f"  Spatial & storm response: outside_home={f(last, 'outside_home_frac')*100:.0f}% | "
            f"huddling calm={calm_hud*100:.0f}% vs storm={storm_hud*100:.0f}%"
        )
        print(
            f"  Final roles: foragers={last['foragers']} scouts={last['scouts']} "
            f"guards={last['guards']} caretakers={last['caretakers']} elders={last['elders']}\n"
        )


if __name__ == "__main__":
    main()
