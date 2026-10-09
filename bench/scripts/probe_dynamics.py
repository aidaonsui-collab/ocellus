#!/usr/bin/env python3
"""Behavioural probe for the on-chain brain model (DESIGN.md §9.3, docs/BRAIN_MODES_PLAN.md phase 0).

  python3 bench/scripts/probe_dynamics.py            # everything below; writes bench/results/dynamics.json
  python3 bench/scripts/probe_dynamics.py --phase0   # phase 0 acceptance on the reconciled graph only, no write
  python3 bench/scripts/probe_dynamics.py --model v1 --trace

Two graphs. The 237-label bench graph (research/graph.json) compares models v0
and v1, as PR #2 did. The reconciled 224-cell graph (research/connectome.v1.json,
the one the chain runs) gets the phase 0 acceptance tests, a 3-hop pathway trace
from PR-II and the antenna cells, and the ablations, one hypothesis at a time.
The run exits non-zero while the shipped graph fails any phase 0 test.

Motor output each tick = sum over spiking motor neurons of their neuromuscular
weights. On the reconciled graph it is split into left (mul*) and right (mur*)
muscle columns. PR-I drive is jittered per cell so cells don't fire in lockstep.
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


# ---------------------------------------------------------------------------
# Phase 0 (docs/BRAIN_MODES_PLAN.md): the reconciled 224-cell graph the chain runs.
#
# Inputs mirror dynamics.sensor_drives for a larva facing the light. PR-I gets
# `intensity` (8,000 is the lure at distance 0 under light 256), the antenna
# cells get ANT_TONIC plus the tilt term, and a shadow quarters the PR-I shade
# and puts PR2_DRIVE on every PR-II cell. Motor output is split into left and
# right neuromuscular weight (mul* and mur* muscle columns), as integrate() uses.
# ---------------------------------------------------------------------------
from dynamics import CONST, load_connectome

TILT = CONST["tilt_cap"]
ONSETS = (80, 85, 90, 95, 100, 105)  # dimming onsets, spread over bout phase
SWEEP = [0, 1500, 2500, 4000, 6000, 8000, 10000, 15000, 20000]
MOTOR_CLASSES = ("MN", "MGIN")


def inputs(intensity=0, tilt=0, shadow=False, pr2=True):
    """The 32 sensor drives in dynamics.step order: PR-I (23), Ant1, Ant2, PR-II (7).

    Same integers as dynamics.sensor_drives with the neutral genome (gains 1000,
    every class gain 1) for a larva facing the light."""
    c = CONST
    shade = c["shade_floor"] + c["shade_span"]
    if shadow:
        shade //= c["shadow_div"]
    cap = c["drive_cap"]
    d = [min(cap, intensity * shade * (780 + 440 * ((k * 7919) % 23) // 22) // (256 * 1000)) for k in range(23)]
    d.append(min(cap, c["ant_tonic"] + c["ant_gain"] * max(tilt, 0) // 256))
    d.append(min(cap, c["ant_tonic"] + c["ant_gain"] * max(-tilt, 0) // 256))
    d += [c["pr2_drive"] if shadow and pr2 else 0] * 7
    return d


class Net:
    """connectome.v1 plus at most one hypothesis. No edge is added or removed.

    flip:   classes or cell ids whose sign becomes inhibitory
    tonic:  {cell index: drive added every tick}
    leak:   {class: leak shift}
    adapt:  {class: adaptation increment per spike}
    """

    def __init__(self, view, flip=(), tonic=None, leak=None, adapt=None):
        self.view = view
        cells = view["doc"]["cells"]
        self.cls = [c["class"] for c in cells]
        g = dict(view["graph"])
        if flip:
            g["inhib"] = [b or c["class"] in flip or c["id"] in flip for b, c in zip(g["inhib"], cells)]
        self.g = g
        self.tonic = sorted((tonic or {}).items())
        self.leak = [leak.get(k, 3) for k in self.cls] if leak else None
        self.adapt = [adapt.get(k, 8192) for k in self.cls] if adapt else None
        self.order = view["pr1"] + view["ant"] + view["pr2"]
        self.nl, self.nr = view["nmj_l"], view["nmj_r"]

    def run(self, schedule, ticks, all_spiking=False):
        """schedule(t) -> 32 drives, or None for no sensor input at all.
        Returns per tick (left, right, fired)."""
        b = Brain(self.g, "v1", all_spiking)
        out = []
        for t in range(ticks):
            drv = schedule(t)
            idx = (self.order if drv is not None else []) + [i for i, _ in self.tonic]
            val = (drv or []) + [x for _, x in self.tonic]
            f = b.step(idx, val, leak=self.leak, adapt_inc=self.adapt)
            out.append((sum(self.nl[i] for i in f), sum(self.nr[i] for i in f), f))
        return out


def motor(seq):
    return mean([l + r for l, r, _ in seq])


def silent_from(seq, start, hold=20):
    for t in range(start, len(seq) - hold + 1):
        if all(l + r == 0 for l, r, _ in seq[t:t + hold]):
            return t - start
    return None


def bout_stats(seq, gap=5):
    """(bouts, mean swimming ticks per bout), with bouts counted as in bouts()."""
    n = bouts([(l + r, f) for l, r, f in seq], gap)
    on = sum(1 for l, r, _ in seq if l + r)
    return n, (round(on / n, 1) if n else 0.0)


def class_spikes(net, seq):
    out = {}
    for _, _, f in seq:
        for i in f:
            out[net.cls[i]] = out.get(net.cls[i], 0) + 1
    return dict(sorted(out.items(), key=lambda kv: -kv[1]))


def dimming(net, tilt=0, pr2=True, intensity=8000):
    """Light, then a 30-tick shadow, then dark. Pooled over ONSETS; per-onset runs returned too."""
    acc = {"before": [], "first10": [], "burst": [], "dark": []}
    per = []
    for t0 in ONSETS:
        def sched(t, t0=t0):
            if t < t0:
                return inputs(intensity, tilt)
            if t < t0 + 30:
                return inputs(intensity, tilt, True, pr2)
            return inputs(0, tilt)
        s = net.run(sched, t0 + 70)
        acc["before"] += s[t0 - 30:t0]
        acc["first10"] += s[t0:t0 + 10]
        acc["burst"] += s[t0:t0 + 30]
        acc["dark"] += s[t0 + 40:t0 + 70]
        per.append(s)
    return acc, per


def phase0_probe(net, base=None):
    """The plan's acceptance tests. `base` is the as-is result, for the regression checks."""
    r, ok = {}, {}
    dim, per = dimming(net)
    ctl, per_ctl = dimming(net, pr2=False)
    # Bout phase makes single runs noisy, so PR-II has to raise output at most onsets, not just on average.
    raised = sum(1 for t0, a, b in zip(ONSETS, per, per_ctl) if motor(a[t0:t0 + 10]) > motor(b[t0:t0 + 10]))
    left = sum(l for l, _, _ in dim["burst"])
    right = sum(r_ for _, r_, _ in dim["burst"])
    r["dimming_step"] = {
        "onsets": list(ONSETS), "intensity": 8000, "shadow_ticks": 30,
        "motor_mean_before": motor(dim["before"]),
        "motor_mean_first_10_after": motor(dim["first10"]),
        "motor_mean_first_10_after_without_pr2": motor(ctl["first10"]),
        "motor_mean_dark": motor(dim["dark"]),
        "onsets_where_pr2_raised_first_10": raised,
        "burst_left_nmj": left, "burst_right_nmj": right,
        "spikes_by_class_before": class_spikes(net, dim["before"]),
        "spikes_by_class_first_10": class_spikes(net, dim["first10"]),
    }
    d = r["dimming_step"]
    ok["dimming_step"] = (d["motor_mean_first_10_after"] > d["motor_mean_before"]
                          and d["motor_mean_first_10_after"] > d["motor_mean_first_10_after_without_pr2"]
                          and 3 * raised >= 2 * len(ONSETS)
                          and d["motor_mean_dark"] == 0)
    ok["dimming_left_bias"] = left > right

    # Antenna alone: constant light, no dimming, tilt at the cap either way.
    steady = {}
    for tilt in (0, TILT, -TILT):
        s = net.run(lambda t, tilt=tilt: inputs(8000, tilt), 400)[100:]
        steady[tilt] = (motor(s), sum(l for l, _, _ in s), sum(r_ for _, r_, _ in s))
    dark = {tilt: motor(net.run(lambda t, tilt=tilt: inputs(0, tilt), 200)[50:]) for tilt in (TILT, -TILT)}
    r["antenna_alone"] = {
        "intensity": 8000, "tilt": TILT,
        "motor_mean_tilt_0": steady[0][0], "motor_mean_tilt_up": steady[TILT][0], "motor_mean_tilt_down": steady[-TILT][0],
        "left_minus_right_tilt_0": steady[0][1] - steady[0][2],
        "left_minus_right_tilt_up": steady[TILT][1] - steady[TILT][2],
        "left_minus_right_tilt_down": steady[-TILT][1] - steady[-TILT][2],
        "motor_mean_dark_tilt_up": dark[TILT], "motor_mean_dark_tilt_down": dark[-TILT],
    }
    ok["antenna_alone"] = steady[TILT][0] <= steady[0][0] and steady[-TILT][0] <= steady[0][0] and dark[TILT] == 0 and dark[-TILT] == 0

    # Antenna steers a dimming swim: the sign of tilt picks the dominant side.
    lr = {}
    for tilt in (TILT, -TILT):
        a, _ = dimming(net, tilt)
        lr[tilt] = (sum(l for l, _, _ in a["burst"]), sum(r_ for _, r_, _ in a["burst"]), motor(a["first10"]))
    r["antenna_steers_dimming"] = {
        "tilt": TILT,
        "burst_left_right_tilt_0": [left, right],
        "burst_left_right_tilt_up": list(lr[TILT][:2]), "burst_left_right_tilt_down": list(lr[-TILT][:2]),
        "motor_mean_first_10_tilt_up": lr[TILT][2], "motor_mean_first_10_tilt_down": lr[-TILT][2],
    }
    du, dd = lr[TILT][0] - lr[TILT][1], lr[-TILT][0] - lr[-TILT][1]
    ok["antenna_steers_dimming"] = du != 0 and dd != 0 and (du > 0) != (dd > 0)

    # PR-I regression: drive sweep and light-then-dark.
    sweep, share, nb, blen = [], [], [], []
    for lvl in SWEEP:
        s = net.run(lambda t, lvl=lvl: inputs(lvl), 500)[100:]
        sweep.append(motor(s))
        share.append(round(sum(1 for l, r_, _ in s if l + r_) / len(s), 2))
        n_b, m_b = bout_stats(s)
        nb.append(n_b)
        blen.append(m_b)
    rho = spearman(sweep)
    s = net.run(lambda t: inputs(8000) if t < 400 else inputs(0), 500)
    r["pr1_regression"] = {
        "drive": SWEEP, "motor_mean": sweep, "spearman_rho_motor_mean": rho,
        "motor_mean_light": motor(s[100:400]), "motor_mean_dark": motor(s[440:]),
        "ticks_to_silence_after_off": silent_from(s, 400),
    }
    p = r["pr1_regression"]
    ok["pr1_regression"] = (p["ticks_to_silence_after_off"] is not None and p["motor_mean_dark"] == 0
                            and (base is None or (rho >= base["pr1_regression"]["spearman_rho_motor_mean"]
                                                  and p["ticks_to_silence_after_off"] <= base["pr1_regression"]["ticks_to_silence_after_off"])))
    r["sustained_swimming"] = {"drive": SWEEP, "share_of_ticks_swimming": share,
                               "swim_bouts_per_400_ticks": nb, "mean_bout_ticks": blen}

    # Seizure, silence from rest, coverage.
    s = net.run(lambda t: inputs(0), 120, all_spiking=True)
    r["seizure"] = {"ticks_to_silence": silent_from(s, 0, hold=10), "spikes_last_50": sum(len(f) for _, _, f in s[70:])}
    ok["seizure"] = r["seizure"]["ticks_to_silence"] is not None
    s0 = net.run(lambda t: None, 60)
    s1 = net.run(lambda t: inputs(0), 60)
    r["no_input_from_rest"] = {"spikes": sum(len(f) for _, _, f in s0), "motor_spikes_dark": sum(l + r_ for l, r_, _ in s1),
                               "spikes_dark": sum(len(f) for _, _, f in s1)}
    ok["no_input_from_rest"] = r["no_input_from_rest"]["motor_spikes_dark"] == 0

    def census(t):
        if t < 100:
            return inputs(8000, TILT)
        if t < 130:
            return inputs(8000, TILT, True)
        if t < 230:
            return inputs(8000, -TILT)
        return inputs(8000, -TILT, True)
    fired = set(i for _, _, f in net.run(census, 260) for i in f)
    r["coverage"] = {"cells_fired_once_or_more": len(fired), "of": len(net.cls)}

    # The raw-drive probes from test_course.py (PR #2), kept so the numbers line up with
    # the "probe" block of research/phase0_behavior.json.
    def raw(pr1_d=0, ant_d=0, pr2_d=0):
        return [pr1_d * (780 + 440 * ((k * 7919) % 23) // 22) // 1000 for k in range(23)] + [ant_d] * 2 + [pr2_d] * 7
    s = net.run(lambda t: raw(6000) if t < 80 else raw(pr2_d=6500) if t < 110 else None, 150)
    r["test_course_probes"] = {
        "pr1_drive_8000_motor_mean": motor(net.run(lambda t: raw(8000), 200)[50:]),
        "dimming_motor_mean": motor(s[80:]),
        "antenna_only_motor_mean": motor(net.run(lambda t: raw(ant_d=6000), 120)[30:]),
    }
    r["pass"] = ok
    r["all_pass"] = all(ok.values())
    return r


def hop_trace(view, hops=3):
    """Every cell reachable in 1..hops chemical hops from PR-II and from the antenna cells.

    Per hop: the newly reached cells by class, with sign, how many are excitatory
    only by default, and how many are contested (kept excitatory although a cited
    paper reports an inhibitory transmitter; see research/signs.csv). Per route of at most `hops` hops that ends on an
    MN or MGIN: the relay classes, the position of the first inhibitory relay, and
    the route's net sign (source and relays multiplied; a net-excitatory route is
    the only kind that can raise motor output). Weights are the bottleneck (the
    smallest hop), in 60-nm sections.
    """
    cells = view["doc"]["cells"]
    out = {}
    for i, j, w in view["doc"]["chem"]:
        out.setdefault(i, []).append((j, w))
    inh = [c["sign"] == "inhibitory" for c in cells]
    default = [not inh[i] and c["sign_basis"].startswith("Default") for i, c in enumerate(cells)]
    contested = [c["sign_basis"].startswith("Contested") for c in cells]
    motor_idx = {i for i, c in enumerate(cells) if c["class"] in MOTOR_CLASSES}
    res = {}
    for name, srcs in (("pr2", view["pr2"]), ("antenna", view["ant"])):
        seen, frontier, layers = set(srcs), set(srcs), []
        for _h in range(hops):
            nxt = {j for i in frontier for j, _w in out.get(i, []) if j not in seen}
            seen |= nxt
            by = {}
            for j in nxt:
                e = by.setdefault(cells[j]["class"], {"cells": 0, "sign": cells[j]["sign"], "default_excitatory": 0, "contested": 0})
                e["cells"] += 1
                e["default_excitatory"] += default[j]
                e["contested"] += contested[j]
            layers.append({"new_cells": len(nxt), "motor_cells": sorted(cells[j]["id"] for j in nxt & motor_idx),
                           "by_class": dict(sorted(by.items(), key=lambda kv: -kv[1]["cells"]))})
            frontier = nxt
        pats, totals = {}, {}

        def walk(path, bottleneck):
            for j, w in out.get(path[-1], []):
                if j in path:
                    continue
                p, bw = path + [j], min(bottleneck, w)
                if j in motor_idx:
                    relays = p[1:-1]
                    net = "excitatory" if (inh[p[0]] + sum(inh[x] for x in relays)) % 2 == 0 else "inhibitory"
                    hop_n = len(p) - 1
                    t = totals.setdefault(f"{hop_n} hops", {}).setdefault(net, {"routes": 0, "weight": 0})
                    t["routes"] += 1
                    t["weight"] += bw
                    key = " > ".join(cells[x]["class"] for x in relays) or "(direct)"
                    e = pats.setdefault(key, {"routes": 0, "weight": 0, "net_sign": net,
                                              "default_excitatory_relays": sum(default[x] for x in relays),
                                              "contested_relays": sum(contested[x] for x in relays),
                                              "first_inhibitory_relay": next((n + 1 for n, x in enumerate(relays) if inh[x]), None)})
                    e["routes"] += 1
                    e["weight"] += bw
                elif len(p) - 1 < hops:
                    walk(p, bw)
        for s0 in srcs:
            walk([s0], 1 << 30)
        top = sorted(pats.items(), key=lambda kv: -kv[1]["weight"])
        res[name] = {"layers": layers, "routes_to_motor_by_net_sign": dict(sorted(totals.items())),
                     "top_route_patterns_by_weight": dict(top[:20])}
    return res


def by_class(view, *classes):
    return [i for i, c in enumerate(view["doc"]["cells"]) if c["class"] in classes]


def by_id(view, *ids):
    return [i for i, c in enumerate(view["doc"]["cells"]) if c["id"] in ids]


def hypotheses(view):
    """Phase 0 ablations, one hypothesis per entry (docs/BRAIN_MODES_PLAN.md, investigation step 2)."""
    out = []
    for k in ("prRN", "MGIN", "AMG", "Em", "PNIN", "ddN", "Cor"):
        out.append({"name": f"flip {k} to inhibitory", "kind": "sign", "net": {"flip": [k]}})
    # Kourakis 2019's own registration: VGAT in AMGs 1-4, 6, 7 (AMG5 is VACHT) and in the eminens cells.
    amg_vgat = ["AMG1", "AMG2", "AMG3", "AMG4", "AMG6", "AMG7"]
    out.append({"name": "flip AMG1-4, AMG6, AMG7 to inhibitory (Kourakis 2019 VGAT)", "kind": "sign", "net": {"flip": amg_vgat}})
    out.append({"name": "flip AMG1-4, AMG6, AMG7 and Em to inhibitory (Kourakis 2019 VGAT)", "kind": "sign", "net": {"flip": amg_vgat + ["Em"]}})
    pram = by_class(view, "pr-AMG RN")
    mgin_t = by_id(view, "MGIN1L", "MGIN1R", "MGIN2L")
    for lvl in (4096, 8192):
        out.append({"name": f"Kourakis 2019 VGAT signs + tonic {lvl} on pr-AMG RN", "kind": "sign+tonic",
                    "net": {"flip": amg_vgat + ["Em"], "tonic": {i: lvl for i in pram}}})
        for b in (2048, 3072):
            t = {i: lvl for i in pram}
            t.update({i: b for i in mgin_t})
            out.append({"name": f"Kourakis 2019 VGAT signs + tonic {lvl} on pr-AMG RN + {b} on its MGIN targets",
                        "kind": "sign+tonic+baseline", "net": {"flip": amg_vgat + ["Em"], "tonic": t}})
    for lvl in (1024, 2048, 3072, 4096, 6144, 8192):
        out.append({"name": f"tonic {lvl} on pr-AMG RN", "kind": "tonic", "net": {"tonic": {i: lvl for i in pram}}})
    ant_rn = by_class(view, "ant1 RN", "ant2 RN", "ant1/2 RN", "ant-cor RN")
    for lvl in (2048, 3072, 4096):
        out.append({"name": f"tonic {lvl} on antenna relay neurons", "kind": "tonic", "net": {"tonic": {i: lvl for i in ant_rn}}})
    # The review's combination: a release needs the released cells to have drive of their own.
    released = {
        "pr-AMG RN's MN/MGIN targets": by_id(view, "MGIN1L", "MGIN1R", "MGIN2L", "MN1L", "MN1R"),
        "AMG": by_class(view, "AMG"),
        "all MN and MGIN": by_class(view, "MN", "MGIN"),
    }
    for lvl in (4096, 6144, 8192, 12288, 16384):
        for label, cells in released.items():
            for b in (2048, 2560, 3072, 4096):
                t = {i: lvl for i in pram}
                for i in cells:
                    t[i] = t.get(i, 0) + b
                out.append({"name": f"tonic {lvl} on pr-AMG RN + {b} on {label}", "kind": "tonic+baseline", "net": {"tonic": t}})
    for lk in (4, 5):
        out.append({"name": f"leak shift {lk} on MN and MGIN", "kind": "leak", "net": {"leak": {"MN": lk, "MGIN": lk}}})
    for ad in (4096, 2048, 0):
        out.append({"name": f"adaptation {ad} on MN and MGIN", "kind": "adaptation", "net": {"adapt": {"MN": ad, "MGIN": ad}}})
    return out


def pr2_in_dark(net):
    """Diagnostic, not a pass criterion: dark, then PR-II drive alone for 30 ticks, then dark."""
    s0 = net.run(lambda t: inputs(0), 140)
    s1 = net.run(lambda t: inputs(0, shadow=60 <= t < 90), 140)
    return {"motor_mean_without_pr2": motor(s0[60:90]), "motor_mean_with_pr2": motor(s1[60:90]), "motor_mean_after": motor(s1[100:])}


def compact(r):
    d, a, st, p = r["dimming_step"], r["antenna_alone"], r["antenna_steers_dimming"], r["pr1_regression"]
    return {
        "dimming_before_first10_without_pr2_dark": [d["motor_mean_before"], d["motor_mean_first_10_after"],
                                                     d["motor_mean_first_10_after_without_pr2"], d["motor_mean_dark"]],
        "onsets_where_pr2_raised_first_10": d["onsets_where_pr2_raised_first_10"],
        "dimming_burst_left_right": [d["burst_left_nmj"], d["burst_right_nmj"]],
        "motor_mean_light_8000": p["motor_mean_light"],
        "pr2_in_dark_without_with_after": list(r["pr2_in_dark"].values()),
        "antenna_light_motor_tilt_0_up_down": [a["motor_mean_tilt_0"], a["motor_mean_tilt_up"], a["motor_mean_tilt_down"]],
        "antenna_dimming_left_right_up_down": [st["burst_left_right_tilt_up"], st["burst_left_right_tilt_down"]],
        "spearman_rho": p["spearman_rho_motor_mean"], "ticks_to_silence_after_off": p["ticks_to_silence_after_off"],
        "seizure_ticks_to_silence": r["seizure"]["ticks_to_silence"],
        "motor_spikes_dark_from_rest": r["no_input_from_rest"]["motor_spikes_dark"],
        "cells_fired": r["coverage"]["cells_fired_once_or_more"],
        "pass": r["pass"],
    }


def phase0(ablate=True):
    view = load_connectome()
    base_net = Net(view)
    base = phase0_probe(base_net)
    base["pr2_in_dark"] = pr2_in_dark(base_net)
    out = {"graph": "research/connectome.v1.json", "data_hash": view["doc"]["data_hash"],
           "inputs": "dynamics.sensor_drives for a larva facing the light; shadow quarters PR-I shade and drives PR-II at PR2_DRIVE",
           "trace": hop_trace(view), "as_is": base}
    if ablate:
        rows = []
        for h in hypotheses(view):
            net = Net(view, **h["net"])
            r = phase0_probe(net, base)
            r["pr2_in_dark"] = pr2_in_dark(net)
            rows.append({"name": h["name"], "kind": h["kind"], **compact(r), "all_pass": r["all_pass"]})
            print(f"  {'PASS' if r['all_pass'] else 'fail'}  {h['name']}", flush=True)
        out["ablations"] = rows
    return out


def print_phase0(r):
    print("phase 0 acceptance on research/connectome.v1.json (as shipped)")
    for k, v in r["pass"].items():
        print(f"  {'pass' if v else 'FAIL'}  {k}")
    d = r["dimming_step"]
    print(f"  dimming: before {d['motor_mean_before']}, first 10 {d['motor_mean_first_10_after']}"
          f" (without PR-II {d['motor_mean_first_10_after_without_pr2']}), dark {d['motor_mean_dark']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", choices=sorted(PARAMS), help="bench graph: probe one model only")
    ap.add_argument("--trace", action="store_true", help="bench graph: print motor output per tick for light-then-dark")
    ap.add_argument("--phase0", action="store_true", help="reconciled graph only: acceptance tests and trace, no ablations, no write")
    args = ap.parse_args()
    models = [args.model] if args.model else sorted(PARAMS)
    if args.trace:
        for m in models:
            seq = run(m, lambda t: light(6000) if t < 40 else ([], []), 70)
            print(m, " ".join(str(x) for x, _ in seq))
        return
    if args.phase0:
        r = phase0(ablate=False)
        print(json.dumps(r["as_is"], indent=1))
        print_phase0(r["as_is"])
        sys.exit(0 if r["as_is"]["all_pass"] else 1)
    res = {m: probe(m) for m in models}
    for scen in res[models[0]]:
        print(scen)
        for k in res[models[0]][scen]:
            print(f"  {k:32}" + "".join(f"{str(res[m][scen][k]):>40}" for m in models))
    if args.model:
        return
    print("phase 0 ablations (one hypothesis each)")
    p0 = phase0()
    dest = ROOT / "bench" / "results" / "dynamics.json"
    json.dump({"params": {m: PARAMS[m] for m in models}, "results": res, "phase0": p0}, open(dest, "w"), indent=1)
    print("wrote", dest.relative_to(ROOT))
    print_phase0(p0["as_is"])
    # The plan's rule: the run fails until the shipped graph passes every phase 0 test.
    sys.exit(0 if p0["as_is"]["all_pass"] else 1)


if __name__ == "__main__":
    main()
