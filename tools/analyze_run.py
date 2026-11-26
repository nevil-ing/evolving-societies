#!/usr/bin/env python3
"""Analyze an Evolving Societies telemetry CSV for emergent evolution signals,
information-theoretic language metrics, and zero-dependency SVG Muller plots.

Usage:
    python3 tools/analyze_run.py data/world_states/run_<seed>.csv [--svg muller.svg]
"""

import argparse
import csv
import math
from collections import defaultdict
from pathlib import Path


def f(row, key, default=0.0):
    return float(row[key]) if key in row and row[key] != "" else default


def write_muller_svg(by_time, clades, out_path: Path):
    """Generate a zero-dependency dark-theme SVG Muller plot (clade population share over time)."""
    times = sorted(by_time.keys())
    if len(times) < 2 or not clades:
        return
    palette = [
        "#ff5a50", "#5a8cff", "#5ae678", "#5af5dc", "#ffd75a",
        "#c878ff", "#ff8c42", "#78e0ff", "#ff6eb4", "#a8e05f",
        "#ffa8a8", "#9bb7ff", "#9df0ad", "#a6faf0", "#ffe899", "#dfb0ff",
    ]
    w, h = 920, 420
    pad_l, pad_r, pad_t, pad_b = 58, 150, 42, 46
    pw = w - pad_l - pad_r
    ph = h - pad_t - pad_b
    t_min, t_max = times[0], max(times[-1], times[0] + 1.0)

    # Compute stacked normalized shares per timestamp.
    xs = [pad_l + (t - t_min) / (t_max - t_min) * pw for t in times]
    cum_lo = {c: [] for c in clades}
    cum_hi = {c: [] for c in clades}
    for t in times:
        row_map = by_time[t]
        tot = sum(row_map.get(c, 0) for c in clades)
        acc = 0.0
        for c in clades:
            frac = (row_map.get(c, 0) / tot) if tot > 0 else 0.0
            cum_lo[c].append(acc)
            acc += frac
            cum_hi[c].append(acc)

    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">',
        '<rect width="100%" height="100%" fill="#0f121d"/>',
        f'<text x="{pad_l}" y="26" fill="#e6eaf5" font-family="system-ui,sans-serif" font-size="15" font-weight="600">'
        f'Evolving Societies - Clade Muller Plot ({t_max/60:.1f} min, {len(clades)} clades)</text>',
        f'<rect x="{pad_l}" y="{pad_t}" width="{pw}" height="{ph}" fill="#161a2a" stroke="#2c334d"/>',
    ]
    for ci, c in enumerate(clades):
        col = palette[ci % len(palette)]
        top_pts = [f"{xs[i]:.1f},{pad_t + (1.0 - cum_hi[c][i]) * ph:.1f}" for i in range(len(times))]
        bot_pts = [f"{xs[i]:.1f},{pad_t + (1.0 - cum_lo[c][i]) * ph:.1f}" for i in range(len(times) - 1, -1, -1)]
        pts = " ".join(top_pts + bot_pts)
        lines.append(f'<polygon points="{pts}" fill="{col}" fill-opacity="0.82" stroke="#0f121d" stroke-width="0.7"/>')
        ly = pad_t + 14 + ci * 20
        if ly < h - pad_b:
            lines.append(f'<rect x="{w - pad_r + 14}" y="{ly - 9}" width="11" height="11" rx="2" fill="{col}"/>')
            lines.append(
                f'<text x="{w - pad_r + 30}" y="{ly}" fill="#cdd3e6" font-family="system-ui,sans-serif" font-size="11">{c}</text>'
            )
    # Time axis ticks.
    for k in range(6):
        frac = k / 5.0
        tx = pad_l + frac * pw
        tmin = (t_min + frac * (t_max - t_min)) / 60.0
        lines.append(f'<line x1="{tx:.1f}" y1="{pad_t + ph}" x2="{tx:.1f}" y2="{pad_t + ph + 5}" stroke="#5b6485"/>')
        lines.append(
            f'<text x="{tx:.1f}" y="{pad_t + ph + 20}" text-anchor="middle" fill="#9aa3be" '
            f'font-family="system-ui,sans-serif" font-size="11">{tmin:.1f}m</text>'
        )
    lines.append(
        f'<text x="{pad_l + pw/2:.1f}" y="{h - 8}" text-anchor="middle" fill="#8891ad" '
        f'font-family="system-ui,sans-serif" font-size="11">Simulated Time (minutes)</text>'
    )
    lines.append("</svg>")
    out_path.write_text("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description="Analyze Evolving Societies telemetry CSV.")
    parser.add_argument("csv_path", nargs="?", help="Path to run_<seed>.csv (defaults to latest)")
    parser.add_argument("--svg", help="Optional output path for a zero-dependency SVG Muller plot")
    args = parser.parse_args()

    if not args.csv_path:
        runs = sorted(Path("data/world_states").glob("run_*.csv"), key=lambda p: p.stat().st_mtime)
        if not runs:
            raise SystemExit("Usage: python3 tools/analyze_run.py <path/to/run.csv> [--svg muller.svg]")
        path = runs[-1]
        print(f"Analyzing latest run: {path}\n")
    else:
        path = Path(args.csv_path)

    by_soc = defaultdict(list)
    by_time = defaultdict(dict)
    clade_order = []
    with path.open() as fh:
        for row in csv.DictReader(fh):
            soc = row["society"]
            if soc not in by_soc:
                clade_order.append(soc)
            by_soc[soc].append(row)
            by_time[float(row["time"])][soc] = int(row["pop"])

    dialect_vecs = {}
    total_gifts = 0
    total_trades = 0
    total_cleared = 0
    total_built = 0
    for soc, rows in by_soc.items():
        first = rows[0]
        alive = [r for r in rows if int(r["pop"]) > 0]
        last = alive[-1] if alive else rows[-1]
        end = rows[-1]

        storm_rows = [r for r in alive if r["phase"] == "storm"]
        calm_rows = [r for r in alive if r["phase"] != "storm"]
        storm_hud = sum(f(r, "huddled_frac") for r in storm_rows) / max(len(storm_rows), 1)
        calm_hud = sum(f(r, "huddled_frac") for r in calm_rows) / max(len(calm_rows), 1)

        total_gifts += int(end.get("gifts_given", 0))
        total_trades += int(end.get("reciprocal_trades", 0))
        total_cleared += int(end.get("infections_cleared", 0))
        total_built += int(end.get("structures_built", 0))

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
                vec = (f(last, "vocal_f0"), f(last, "vocal_f1"), f(last, "vocal_f2"))
                sep = f(last, "vocal_sep")
                if int(end["signals_sent"]) >= 3:
                    dialect_vecs[soc] = vec
                # Gaussian channel effective mutual information proxy I(Context; Token) in bits.
                mi_bits = 0.5 * math.log2(1.0 + (sep * sep) / 0.5)
                voc_str = (
                    f" | dialect=({vec[0]:+.2f},{vec[1]:+.2f},{vec[2]:+.2f})"
                    f" | context_sep={sep:.2f} (I~{mi_bits:.2f} bits)"
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

    # Cross-clade ecosystem & dialect summary.
    if len(dialect_vecs) >= 2:
        names = list(dialect_vecs.keys())
        dists = []
        for i in range(len(names)):
            for j in range(i + 1, len(names)):
                va, vb = dialect_vecs[names[i]], dialect_vecs[names[j]]
                d = math.sqrt(sum((x - y) ** 2 for x, y in zip(va, vb)))
                dists.append((names[i], names[j], d))
        avg_div = sum(d for _, _, d in dists) / len(dists)
        print("=== Ecosystem Summary ===")
        print(
            f"  Clades observed: {len(clade_order)} | Structures built: {total_built} | "
            f"Infections cleared: {total_cleared} | Gifts/Trades: {total_gifts}/{total_trades}"
        )
        print(f"  Mean inter-clade dialect divergence: {avg_div:.2f}")
        for a, b, d in dists[:6]:
            print(f"    {a} <-> {b}: {d:.2f}")

    if args.svg:
        out_svg = Path(args.svg)
        write_muller_svg(by_time, clade_order, out_svg)
        print(f"\nWrote SVG Muller plot: {out_svg}")


if __name__ == "__main__":
    main()
