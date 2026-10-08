#!/usr/bin/env python3
"""Behavioural probe for the on-chain brain model (DESIGN.md §9.3).

  python3 bench/scripts/probe_dynamics.py            # compare v0 and v1, write bench/results/dynamics.json
  python3 bench/scripts/probe_dynamics.py --model v1 --trace

Motor output each tick = sum over spiking motor neurons of their neuromuscular
weights (muscle columns in research/graph.json). PR-I drive is jittered per cell
(deterministic 0.78x..1.22x) so cells don't fire in lockstep.
"""
import argparse, json, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lif_model import Brain, PARAMS, ROOT, load_graph

G, RG = load_graph()
CELLS = RG["cells"]
N = G["n"]
MW = [0] * N
for i, _m, w in RG["nmj"]:
    MW[i] += w
PR1 = G["sens"][:23]
ANT = G["sens"][23:]
PR2 = [CELLS.index(c) for c in "pra prb prc prd pre prf prg".split()]
JIT = [0.78 + 0.44 * ((k * 7919) % 23) / 22 for k in range(23)]


def light(d):
    return PR1, [int(d * JIT[k]) for k in range(23)]


def run(model, schedule, ticks, all_spiking=False):
    """schedule(t) -> (indices, drives). Returns per-tick (motor output, fired list)."""
    b = Brain(G, model, all_spiking)
    out = []
    for t in range(ticks):
        idx, drv = schedule(t)
        f = b.step(idx, drv)
        out.append((sum(MW[i] for i in f), f))
    return out


def mean(xs):
    return round(sum(xs) / len(xs), 1) if xs else 0.0


def spearman(xs):
    """Rank correlation of motor output with drive level; ties get average ranks."""
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    rank, i = [0.0] * len(xs), 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and xs[order[j + 1]] == xs[order[i]]:
            j += 1
        for k in range(i, j + 1):
            rank[order[k]] = (i + j) / 2
        i = j + 1
    idx = list(range(len(xs)))
    ma, mb = sum(rank) / len(rank), sum(idx) / len(idx)
    num = sum((a - ma) * (b - mb) for a, b in zip(rank, idx))
    den = (sum((a - ma) ** 2 for a in rank) * sum((b - mb) ** 2 for b in idx)) ** 0.5
    return round(num / den, 3) if den else 0.0


def bouts(seq, gap=5):
    """Count swim bouts: motor output after at least `gap` silent ticks (or at the start)."""
    out, quiet = 0, gap
    for m, _ in seq:
        if m and quiet >= gap:
            out += 1
        quiet = 0 if m else quiet + 1
    return out


def first_silent(seq, start, hold=20):
    for t in range(start, len(seq) - hold + 1):
        if all(m == 0 for m, _ in seq[t:t + hold]):
            return t - start
    return None


def probe(model):
    r = {}
    # (a) light on for 400 ticks, then dark for 100
    seq = run(model, lambda t: light(8000) if t < 400 else ([], []), 500)
    r["light_then_dark"] = {
        "motor_mean_light": mean([m for m, _ in seq[100:400]]),
        "swim_bouts_in_light": bouts(seq[100:400]),
        "motor_mean_dark": mean([m for m, _ in seq[440:500]]),
        "ticks_to_silence_after_off": first_silent(seq, 400),
    }
    # (b) drive sweep, steady light for 500 ticks (statistics over ticks 100-500)
    levels = [0, 1500, 2500, 4000, 6000, 8000, 10000, 15000, 20000]
    sweep, nb, active = [], [], []
    for d in levels:
        s = run(model, lambda t, d=d: light(d), 500)[100:]
        sweep.append(mean([m for m, _ in s]))
        nb.append(bouts(s))
        active.append(round(sum(1 for m, _ in s if m) / len(s), 2))
    r["drive_sweep"] = {"drive": levels, "motor_mean": sweep, "swim_bouts_per_400_ticks": nb, "share_of_ticks_swimming": active,
                        "spearman_rho_motor_mean": spearman(sweep)}
    # (c) pulsed light: 15 ticks on, 15 off
    seq = run(model, lambda t: light(10000) if (t // 15) % 2 == 0 else ([], []), 240)
    on = [m for t, (m, _) in enumerate(seq[30:], 30) if ((t - 3) // 15) % 2 == 0]
    off = [m for t, (m, _) in enumerate(seq[30:], 30) if ((t - 3) // 15) % 2 == 1]
    r["pulsed_light"] = {"motor_mean_on_phase": mean(on), "motor_mean_off_phase": mean(off)}
    # (d) dimming: steady light, then a step down with PR-II drive (the escape pathway)
    def dim(t):
        if t < 80:
            return light(6000)
        if t < 110:
            return PR2, [6500] * 7
        return [], []
    seq = run(model, dim, 150)
    r["dimming_step"] = {
        "motor_mean_before": mean([m for m, _ in seq[50:80]]),
        "motor_mean_first_10_after": mean([m for m, _ in seq[80:90]]),
        "motor_mean_dark": mean([m for m, _ in seq[120:150]]),
    }
    # (e) gravity only (antenna cells), (f) quiet start, (g) seizure recovery, (h) activity census
    seq = run(model, lambda t: (ANT, [6000, 6000]), 120)
    r["antenna_only"] = {"motor_mean": mean([m for m, _ in seq[30:120]])}
    seq = run(model, lambda t: ([], []), 60)
    r["no_input_from_rest"] = {"spikes": sum(len(f) for _, f in seq)}
    seq = run(model, lambda t: ([], []), 120, all_spiking=True)
    r["all_spiking_start_no_input"] = {"ticks_to_silence": first_silent(seq, 0, hold=10), "spikes_last_50": sum(len(f) for _, f in seq[70:])}
    seq = run(model, lambda t: (PR1 + ANT, light(8000)[1] + [6000, 6000]), 200)
    fired = set(i for _, f in seq for i in f)
    r["activity_census"] = {"cells_fired_once_or_more": len(fired), "of": N}
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", choices=sorted(PARAMS), help="probe one model only")
    ap.add_argument("--trace", action="store_true", help="print MN L/R per tick for light-then-dark")
    args = ap.parse_args()
    models = [args.model] if args.model else sorted(PARAMS)
    if args.trace:
        for m in models:
            seq = run(m, lambda t: light(6000) if t < 40 else ([], []), 70)
            print(m, " ".join(str(x) for x, _ in seq))
        return
    res = {m: probe(m) for m in models}
    for scen in res[models[0]]:
        print(scen)
        for k in res[models[0]][scen]:
            print(f"  {k:32}" + "".join(f"{str(res[m][scen][k]):>40}" for m in models))
    if not args.model:
        dest = ROOT / "bench" / "results" / "dynamics.json"
        json.dump({"params": {m: PARAMS[m] for m in models}, "results": res}, open(dest, "w"), indent=1)
        print("wrote", dest.relative_to(ROOT))


if __name__ == "__main__":
    main()
