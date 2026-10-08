#!/usr/bin/env python3
"""Turn research/graph.json into the benchmark inputs:
  bench/graph_csr.json          CSR arrays used by run_localnet.py
  bench/tests/bench_tests.move  unit tests embedding the same graph

Inhibitory cells (Dale's law, one sign per presynaptic cell), seeded from:
  PR-II photoreceptors pra..prg and pr-AMG relay neurons (GABAergic; Kourakis et al. 2019),
  antenna relay neurons (inhibitory; Bostwick et al. 2020), ACINs (Ryan et al. 2016 cell key).
Everything else defaults to excitatory. Gap junctions are symmetrized (max of both directions).
Sensory inputs: PR-I photoreceptors pr1..pr23 + antenna cells Ant1, Ant2.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
g = json.load(open(ROOT / "research" / "graph.json"))
cells = g["cells"]
n = len(cells)
assert n <= 255, "col indices are u8"

INHIB = set("pra prb prc prd pre prf prg ACIN1L ACIN2L ACIN2R".split()) | set(
    "74 94 108 116 124 127 140 157 147 152 161 135 153 159 120 134 142 143".split()
)


def csr(edges):
    rows = [[] for _ in range(n)]
    for a, b, w in edges:
        rows[a].append((b, min(w, 65535)))
    ptr, col, ws = [0], [], []
    for r in rows:
        for b, w in r:
            col.append(b)
            ws.append(w)
        ptr.append(len(col))
    return ptr, col, ws


ptr, col, w = csr(g["chem"])
gs = {}
for a, b, x in g["gap"]:
    if a == b:
        continue
    gs[(a, b)] = max(gs.get((a, b), 0), x)
    gs[(b, a)] = max(gs.get((b, a), 0), x)
gptr, gcol, gw = csr([(a, b, x) for (a, b), x in gs.items()])
inhib = [c in INHIB for c in cells]
sens = [cells.index(c) for c in cells if c.startswith("pr") and c[2:].isdigit()] + [cells.index("Ant1"), cells.index("Ant2")]

L = lambda xs, suf: "[" + ", ".join(f"{x}{suf}" for x in xs) + "]"
B = lambda xs: "[" + ", ".join("true" if x else "false" for x in xs) + "]"
test = f"""#[test_only]
module ciona_bench::bench_tests;
use ciona_bench::brain;
use std::unit_test::destroy;

fun conn(ctx: &mut TxContext): brain::Connectome {{
    brain::new_connectome({n},
        vector{L(ptr,'u16')}, vector{L(col,'u8')}, vector{L(w,'u16')},
        vector{B(inhib)},
        vector{L(gptr,'u16')}, vector{L(gcol,'u8')}, vector{L(gw,'u16')}, ctx)
}}
fun sensors(): (vector<u8>, vector<u32>) {{
    (vector{L(sens,'u8')}, vector[{', '.join(['20000u32']*len(sens))}])
}}
"""
for name, allsp, ticks in [("typical_1_tick", False, 1), ("typical_10_ticks", False, 10), ("worst_all_spiking_1_tick", True, 1)]:
    test += f"""
#[test] fun {name}() {{
    let mut ctx = tx_context::dummy();
    let c = conn(&mut ctx);
    let mut b = brain::new_brain(&c, {str(allsp).lower()}, &mut ctx);
    let (si, sd) = sensors();
    brain::step(&c, &mut b, si, sd, {ticks}, false);
    std::debug::print(&brain::spikes_total(&b));
    destroy(b); destroy(c);
}}
"""
test += """
#[test] fun setup_only() {
    let mut ctx = tx_context::dummy();
    let c = conn(&mut ctx);
    let b = brain::new_brain(&c, false, &mut ctx);
    destroy(b); destroy(c);
}
"""
(ROOT / "bench" / "tests" / "bench_tests.move").write_text(test)
json.dump(dict(n=n, ptr=ptr, col=col, w=w, gptr=gptr, gcol=gcol, gw=gw, inhib=inhib, sens=sens),
          open(ROOT / "bench" / "graph_csr.json", "w"))
print(f"n {n}  chem {len(col)}  gap directed {len(gcol)}  sensors {len(sens)}  inhibitory {sum(inhib)}")
