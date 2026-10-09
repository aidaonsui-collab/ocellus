"""Exact Python reference of the Move LIF step in bench/sources/brain.move.

Two parameter sets:
  v0  the first benchmark model (as published on 2026-10-07)
  v1  the current model: inhibitory reversal floor, stability-normalized gap
      coupling, spike-frequency adaptation, recalibrated synaptic gain

Integer arithmetic only, mirroring Move's u32 math, so spike counts from this
file must match `sui move test` exactly (see gen_bench.py golden values).
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REST = 1 << 20

PARAMS = {
    "v0": dict(thresh=REST + 16384, reset=REST - 4096, leak_shift=3, w_scale=64,
               gap_shift=6, gap_mode="raw", v_floor=0, v_ceil=None, adapt_inc=0, adapt_shift=0),
    "v1": dict(thresh=REST + 16384, reset=REST - 4096, leak_shift=3, w_scale=320,
               gap_shift=12, gap_mode="normalized", v_floor=REST - 16384, v_ceil=REST + 65536,
               adapt_inc=8192, adapt_shift=4),
}


def load_graph():
    g = json.load(open(ROOT / "bench" / "graph_csr.json"))
    r = json.load(open(ROOT / "research" / "graph.json"))
    return g, r


def gap_coefficients(g):
    """v1 gap coupling, integer-exact.

    The raw coupling per tick is gw/64 of the voltage difference. 37 cells have a
    summed coupling above 1 per tick (MN2R: 14.5), which makes the explicit update
    oscillate with period 2. Each edge is scaled so every cell's total coupling is
    at most 0.5 per tick; weakly coupled cells keep their original strength.
    Encoded with GAP_SHIFT = 12: coef = gw * 2048 / max(32, sum_i, sum_j).
    """
    n = g["n"]
    gsum = [sum(g["gw"][k] for k in range(g["gptr"][i], g["gptr"][i + 1])) for i in range(n)]
    out = []
    for i in range(n):
        for k in range(g["gptr"][i], g["gptr"][i + 1]):
            j = g["gcol"][k]
            out.append(g["gw"][k] * 2048 // max(32, gsum[i], gsum[j]))
    return out


class Brain:
    def __init__(self, g, model="v1", all_spiking=False, params=None):
        self.p = {"refractory": 0, **(params or PARAMS[model])}
        self.n = g["n"]
        self.inhib = g["inhib"]
        self.chem = [[(g["col"][k], g["w"][k]) for k in range(g["ptr"][i], g["ptr"][i + 1])] for i in range(self.n)]
        coef = g["gw"] if self.p["gap_mode"] == "raw" else gap_coefficients(g)
        self.gap = [[(g["gcol"][k], coef[k]) for k in range(g["gptr"][i], g["gptr"][i + 1])] for i in range(self.n)]
        self.v = [REST] * self.n
        self.a = [0] * self.n
        self.r = [0] * self.n
        self.spiked = [all_spiking] * self.n
        self.tick = 0
        self.spikes_total = 0

    def step(self, sensor_idx=(), sensor_drive=(), force_all=False, leak=None, theta=None, adapt_inc=None):
        """leak, theta and adapt_inc are optional per-cell overrides (probe only)."""
        p, n, v = self.p, self.n, self.v
        exc, inh = [0] * n, [0] * n
        for i in range(n):
            if force_all or self.spiked[i]:
                tgt = inh if self.inhib[i] else exc
                for j, w in self.chem[i]:
                    tgt[j] += w * p["w_scale"]
        raw = p["gap_mode"] == "raw"
        for i in range(n):
            vi = v[i]
            for j, c in self.gap[i]:
                vj = v[j]
                if raw:
                    if vj > vi: exc[i] += ((vj - vi) >> p["gap_shift"]) * c
                    else: inh[i] += ((vi - vj) >> p["gap_shift"]) * c
                else:
                    if vj > vi: exc[i] += ((vj - vi) * c) >> p["gap_shift"]
                    else: inh[i] += ((vi - vj) * c) >> p["gap_shift"]
        for s, d in zip(sensor_idx, sensor_drive):
            exc[s] += d
        fired = []
        for i in range(n):
            x = v[i]
            shift = p["leak_shift"] if leak is None else leak[i]
            x = x - ((x - REST) >> shift) if x > REST else x + ((REST - x) >> shift)
            x += exc[i]
            x = x - inh[i] if x > inh[i] else 0
            if x < p["v_floor"]: x = p["v_floor"]
            if p["v_ceil"] is not None and x > p["v_ceil"]: x = p["v_ceil"]
            a = self.a[i]
            if p["adapt_shift"]: a -= a >> p["adapt_shift"]
            if self.r[i]:
                self.r[i] -= 1
                f = False
            else:
                extra = 0 if theta is None else theta[i]
                f = x >= p["thresh"] + a + extra
            if f:
                self.r[i] = p["refractory"]
                x = p["reset"]
                a += p["adapt_inc"] if adapt_inc is None else adapt_inc[i]
                fired.append(i)
                self.spikes_total += 1
            v[i] = x
            self.a[i] = a
            self.spiked[i] = f
        self.tick += 1
        return fired
