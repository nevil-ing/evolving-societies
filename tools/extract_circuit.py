"""Extract a smell -> steer -> feed sub-circuit from the FlyWire connectome.

Inputs (sensors) and outputs (motor/descending neurons) are picked by cell
type, then every neuron that sits on a strong path between them is kept.
"Strong" is scored by propagating influence forward from the sensors and
backward from the outputs through the synapse-share-normalised graph, and
keeping the neurons with the highest product of both.

The result is written as a compact binary the Zig app loads at start-up.

Data (download to data/flywire, see README):
  Connectivity_783.parquet, Completeness_783.csv  - Shiu et al. 2024
  neuron_annotations.tsv                          - Schlegel et al. 2024

Run:
  uv run --no-project --with numpy --with scipy --with pandas --with pyarrow \
      python tools/extract_circuit.py
"""

import argparse
import json
import struct
from pathlib import Path

import numpy as np
import pandas as pd
import scipy.sparse as sp

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data" / "flywire"
OUT = ROOT / "sim" / "assets"

# Attractive food-odour glomeruli (vinegar / fruit / yeast volatiles).
ATTRACTIVE_ORNS = ["ORN_DM1", "ORN_DM2", "ORN_DM4", "ORN_VA2", "ORN_VM2"]
# Aversive glomeruli: V is the CO2 stress-odour channel, DA2 is geosmin.
ALARM_ORNS = ["ORN_V", "ORN_DA2"]

INPUT_GROUPS = ["orn_attr", "orn_alarm", "sugar", "bitter"]
OUTPUT_GROUPS = ["turn", "fwd", "back", "escape", "feed"]

# Which input -> output pairs the circuit has to carry.
PATHWAYS = [
    ("orn_attr", "turn"), ("orn_attr", "fwd"),
    ("orn_alarm", "turn"), ("orn_alarm", "back"), ("orn_alarm", "escape"),
    ("sugar", "feed"), ("bitter", "feed"), ("sugar", "fwd"),
]


def load():
    comp = pd.read_csv(DATA / "Completeness_783.csv", index_col=0)
    con = pd.read_parquet(DATA / "Connectivity_783.parquet")
    ann = pd.read_csv(DATA / "neuron_annotations.tsv", sep="\t", low_memory=False)
    ann = ann.drop_duplicates("root_id").set_index("root_id").reindex(comp.index)
    return comp, con, ann


def io_neurons(ann):
    """Return {group: {"L": [idx...], "R": [idx...]}} in model index space."""
    idx = pd.Series(np.arange(len(ann)), index=ann.index)
    side = ann.side.fillna("center").str[0].str.upper()  # L / R / C

    def by_side(mask):
        out = {"L": [], "R": []}
        for rid in ann.index[mask.fillna(False).values]:
            s = side.loc[rid]
            out["R" if s == "R" else "L"].append(int(idx.loc[rid]))
        return out

    ct, sub = ann.cell_type, ann.cell_sub_class
    groups = {
        "orn_attr": by_side(ct.isin(ATTRACTIVE_ORNS)),
        "orn_alarm": by_side(ct.isin(ALARM_ORNS)),
        "sugar": by_side(sub.isin(["sugar", "sugar/low_salt"]) & (ann.cell_class == "gustatory")),
        "bitter": by_side(sub.eq("bitter") & (ann.cell_class == "gustatory")),
        # DNa01/DNa02 steer: ipsilateral activity turns the fly to that side.
        "turn": by_side(ct.isin(["DNa01", "DNa02"])),
        # DNp09 (P9) drives forward walking.
        "fwd": by_side(ct.eq("DNp09")),
        # Moonwalker descending neurons drive backward walking.
        "back": by_side(ct.eq("MDN")),
        # Giant fibre: escape take-off.
        "escape": by_side(ct.eq("DNp01")),
        # MN9 proboscis motor neuron (Shiu et al. 2024), labelled CB0701.
        "feed": by_side(ct.eq("CB0701")),
    }
    for g, s in groups.items():
        if not s["L"] and not s["R"]:
            raise SystemExit(f"no neurons found for group {g}")
    return groups


def influence(P, seeds, steps):
    """Sum of k-step propagated influence, k = 1..steps."""
    v = np.zeros(P.shape[0])
    v[seeds] = 1.0 / len(seeds)
    total = np.zeros_like(v)
    for _ in range(steps):
        v = P @ v
        total += v
    return total


def select(con, groups, n, per_path, steps):
    A = sp.csr_matrix(
        (con.Connectivity.values.astype(np.float64),
         (con.Postsynaptic_Index.values, con.Presynaptic_Index.values)),
        shape=(n, n),
    )
    # forward: share of each post's input coming from pre
    in_tot = np.asarray(A.sum(axis=1)).ravel()
    Pf = sp.diags(1.0 / np.maximum(in_tot, 1)) @ A
    # backward: share of each pre's output going to post
    out_tot = np.asarray(A.sum(axis=0)).ravel()
    Pb = (A @ sp.diags(1.0 / np.maximum(out_tot, 1))).T.tocsr()

    flat = {g: s["L"] + s["R"] for g, s in groups.items()}
    fwd = {g: influence(Pf, flat[g], steps) for g in INPUT_GROUPS}
    bwd = {g: influence(Pb, flat[g], steps) for g in OUTPUT_GROUPS}

    keep = set()
    for g in flat.values():
        keep.update(g)
    for i, o in PATHWAYS:
        score = fwd[i] * bwd[o]
        top = np.argsort(score)[::-1][:per_path]
        top = top[score[top] > 0]
        keep.update(int(t) for t in top)
        print(f"  {i:>9} -> {o:<6} kept {len(top)} (best score {score[top[0]]:.2e})")
    return np.array(sorted(keep))


def rate_sim(n_sel, rows, cols, w, stim, gain, steps=200, dt=0.005, tau=0.02):
    """Threshold-linear rate model; same dynamics the Zig app runs."""
    W = sp.csr_matrix((w * gain, (rows, cols)), shape=(n_sel, n_sel))
    v = np.zeros(n_sel)
    r = np.zeros(n_sel)
    for _ in range(steps):
        I = W @ r + stim
        v += dt / tau * (-v + I)
        r = np.clip(v, 0.0, 1.0)
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-path", type=int, default=220)
    ap.add_argument("--steps", type=int, default=5)
    ap.add_argument("--gain", type=float, default=1 / 200)
    args = ap.parse_args()

    print("loading FlyWire data ...")
    comp, con, ann = load()
    n = len(comp)
    groups = io_neurons(ann)
    for g, s in groups.items():
        print(f"  {g:<9} L={len(s['L']):>3} R={len(s['R']):>3}")

    print("selecting sub-circuit ...")
    sel = select(con, groups, n, args.per_path, args.steps)
    remap = -np.ones(n, dtype=np.int64)
    remap[sel] = np.arange(len(sel))

    inside = (remap[con.Presynaptic_Index.values] >= 0) & (remap[con.Postsynaptic_Index.values] >= 0)
    sub = con[inside]
    rows = remap[sub.Postsynaptic_Index.values]
    cols = remap[sub.Presynaptic_Index.values]
    w = sub["Excitatory x Connectivity"].values.astype(np.float32)
    print(f"  {len(sel)} neurons, {len(sub)} connections, {int(np.abs(w).sum())} synapses")

    io = {f"{g}_{s}": [int(remap[i]) for i in groups[g][s]] for g in groups for s in "LR"}

    # cell-type groups: evolution tunes one gain per type (left/right share it)
    types = ann.cell_type.iloc[sel].fillna(ann.hemibrain_type.iloc[sel]).fillna("")
    types = [t if t else f"id{rid}" for t, rid in zip(types, ann.index[sel])]
    type_names = sorted(set(types))
    type_idx = np.array([type_names.index(t) for t in types], dtype=np.uint32)
    print(f"  {len(type_names)} cell-type groups")

    print("sanity check (rate model) ...")
    m = len(sel)

    def stim(*names, level=1.0):
        s = np.zeros(m)
        for nm in names:
            s[io[nm]] = level
        return s

    def mean(r, nm):
        return float(r[io[nm]].mean()) if io[nm] else 0.0

    report = {}
    for label, s in [
        ("food odour LEFT", stim("orn_attr_L")),
        ("food odour RIGHT", stim("orn_attr_R")),
        ("alarm odour LEFT", stim("orn_alarm_L")),
        ("sugar taste", stim("sugar_L", "sugar_R")),
        ("bitter taste", stim("bitter_L", "bitter_R")),
        ("sugar + bitter", stim("sugar_L", "sugar_R", "bitter_L", "bitter_R")),
    ]:
        r = rate_sim(m, rows, cols, w, s, args.gain)
        out = {o: (mean(r, f"{o}_L"), mean(r, f"{o}_R")) for o in OUTPUT_GROUPS}
        report[label] = out
        print(f"  {label:<17} " + "  ".join(f"{o}={a:.2f}/{b:.2f}" for o, (a, b) in out.items())
              + f"  active={int((r > 0.01).sum())}")

    OUT.mkdir(parents=True, exist_ok=True)
    order = np.lexsort((cols, rows))
    rows, cols, w = rows[order], cols[order], w[order]
    row_ptr = np.zeros(m + 1, dtype=np.uint32)
    np.add.at(row_ptr, rows + 1, 1)
    row_ptr = np.cumsum(row_ptr).astype(np.uint32)

    io_names = [f"{g}_{s}" for g in INPUT_GROUPS + OUTPUT_GROUPS for s in "LR"]
    with open(OUT / "flybrain.bin", "wb") as f:
        f.write(b"FLYB")
        f.write(struct.pack("<6I", 1, m, len(w), len(type_names), len(io_names), 0))
        f.write(struct.pack("<f", args.gain))
        f.write(type_idx.astype("<u4").tobytes())
        f.write(row_ptr.astype("<u4").tobytes())
        f.write(cols.astype("<u4").tobytes())
        f.write(w.astype("<f4").tobytes())
        for nm in io_names:
            ids = io[nm]
            f.write(nm.encode().ljust(16, b"\0"))
            f.write(struct.pack("<I", len(ids)))
            f.write(np.array(ids, dtype="<u4").tobytes())

    meta = {
        "source": "FlyWire FAFB v783 (Dorkenwald et al. 2024; Schlegel et al. 2024); "
                  "connectivity table from Shiu et al. 2024",
        "neurons": m, "connections": int(len(w)), "gain": args.gain,
        "attractive_orns": ATTRACTIVE_ORNS, "alarm_orns": ALARM_ORNS,
        "io": {k: len(v) for k, v in io.items()},
        "cell_types": type_names,
        "root_ids": [str(r) for r in ann.index[sel]],
        "sanity_check": report,
    }
    (OUT / "flybrain.json").write_text(json.dumps(meta, indent=1))
    print(f"wrote {OUT / 'flybrain.bin'} ({(OUT / 'flybrain.bin').stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
