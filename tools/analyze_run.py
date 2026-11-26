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
        cann = f" cannibal={end['cannibal_kills']}" if "cannibal_kills" in end else ""
        print(
            f"  Totals: births={end['births']} starved={end['starved']} "
            f"old_age={end['old_age']} killed={end['killed']}{cann} hybrids={end['hybrids']}"
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
        skill_cols = [
            ("avg_foraging", "foraging"),
            ("avg_navigation", "navigation"),
            ("avg_combat", "combat"),
            ("avg_care", "care"),
        ]
        if "avg_building" in first:
            skill_cols.extend([("avg_building", "building"), ("avg_toolcraft", "toolcraft")])
        for k, label in skill_cols:
            print(f"    {label:<15} {f(first, k)*100:5.1f}% -> {f(last, k)*100:5.1f}%")
        rec_str = f" | recurrent {f(first, 'avg_recurrent'):.1f} -> {f(last, 'avg_recurrent'):.1f} | memories {f(last, 'avg_memories'):.2f}/6" if "avg_recurrent" in last else ""
        print(
            f"    {'cog neurons':<15} {f(first, 'avg_neurons'):5.1f}  -> {f(last, 'avg_neurons'):5.1f}  "
            f"| synapses {f(first, 'avg_synapses'):5.1f} -> {f(last, 'avg_synapses'):5.1f}{rec_str}"
        )
        if "avg_digest_m" in last:
            print(
                f"  Diet & morphology: meat={f(last, 'avg_digest_m')*100:.0f}% "
                f"plant={f(last, 'avg_digest_p')*100:.0f}% mineral={f(last, 'avg_digest_x')*100:.0f}% "
                f"| body_scale=x{f(last, 'avg_scale'):.2f} | active_clades={end.get('active_clades', '?')}"
            )
        if "infections_cleared" in end:
            print(
                f"  Immunity: disease_deaths={end['disease_deaths']} | sick_now={end['sick_now']} "
                f"| cleared={end['infections_cleared']} | avg_antibodies={f(last, 'avg_antibodies'):.2f}/4"
            )
        if "gifts_given" in end:
            print(
                f"  Economy: gifts_given={end['gifts_given']} | reciprocal_trades={end['reciprocal_trades']} "
                f"| cross_clade_trades={end['cross_clade_trades']}"
            )
        print(
            f"  Spatial & storm response: outside_home={f(last, 'outside_home_frac')*100:.0f}% | "
            f"huddling calm={calm_hud*100:.0f}% vs storm={storm_hud*100:.0f}%"
        )
        if "signals_sent" in end:
            voc_str = ""
            if "vocal_f0" in last:
                voc_str = (
                    f" | dialect=({f(last, 'vocal_f0'):+.2f},{f(last, 'vocal_f1'):+.2f},{f(last, 'vocal_f2'):+.2f})"
                    f" | context_sep={f(last, 'vocal_sep'):.2f}"
                )
            print(f"  Communication: signals_sent={end['signals_sent']} | kin_responses={end['signals_acted']}{voc_str}")
        if "structures_built" in end:
            pred_str = f" | predators_slain={end['predators_slain']} | raids_suffered={end['raids_suffered']}" if "predators_slain" in end else ""
            print(
                f"  Tools & building: tools_held={last['tools_held']} | "
                f"structures_built={end['structures_built']} | prey_hunted={end['prey_hunted']}{pred_str}"
            )
        extra_roles = f" builders={last['builders']} hunters={last['hunters']}" if "builders" in last else ""
        print(
            f"  Final roles: foragers={last['foragers']} scouts={last['scouts']} "
            f"guards={last['guards']} caretakers={last['caretakers']}{extra_roles} elders={last['elders']}\n"
        )


if __name__ == "__main__":
    main()
