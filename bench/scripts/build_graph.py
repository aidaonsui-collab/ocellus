#!/usr/bin/env python3
"""Parse the Ryan et al. 2016 (eLife 5:e16962, CC BY 4.0) Figure 16 source-data
matrices into a simple edge list.

Inputs  (research/): elife-fig16-data1.xlsx (chemical synapses, pre x post)
                     elife-fig16-data2.xlsx (putative gap junctions)
Outputs (research/): graph.json        {cells, chem, gap, nmj}  (indices + integer weights)
                     matrix_stats.json  raw non-zero entry counts

Weight = cumulative contact depth (um) / 0.06 um, rounded, min 1  (=> number of 60-nm sections).
NOTE: labels are NOT reconciled (e.g. Cor1 vs coronet1). This graph is the
benchmark. The canonical connectome is research/connectome.v1.json, built by
build_connectome.py.
Requires: pip install openpyxl
"""
import json, re, sys
from pathlib import Path
import openpyxl

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "research"
MUSCLE = {"mul", "mulm", "mur", "murm"}
DROP = {"bm", "bm-noto"}


def load(path):
    ws = openpyxl.load_workbook(path, data_only=True).active
    rows = list(ws.iter_rows(values_only=True))
    hdr = [str(x).strip() if x is not None else "" for x in rows[0]]
    out = []
    for r in rows[1:]:
        n = str(r[0]).strip() if r[0] is not None else ""
        if not n or "total" in n.lower():
            continue
        for j, v in enumerate(r[1:], 1):
            h = hdr[j] if j < len(hdr) else ""
            if not h or "total" in h.lower():
                continue
            if isinstance(v, (int, float)) and v > 0:
                out.append((n, h, v))
    return out


def main():
    chem = load(RES / "elife-fig16-data1.xlsx")
    gap = load(RES / "elife-fig16-data2.xlsx")

    stats = {}
    for name, edges in (("elife-fig16-data1.xlsx", chem), ("elife-fig16-data2.xlsx", gap)):
        cells = {a for a, b, v in edges} | {b for a, b, v in edges}
        cells -= MUSCLE | DROP
        stats[name] = dict(
            cells=len(cells),
            edges=sum(1 for a, b, v in edges if b not in MUSCLE | DROP),
            edges_to_muscle_or_bm=sum(1 for a, b, v in edges if b in MUSCLE | DROP),
            pns_like=len([c for c in cells if re.match(r"(?i)(pns|aten|pn[a-z]$|btn)", c)]),
        )

    cells = sorted({a for a, b, v in chem + gap} | {b for a, b, v in chem + gap if b not in MUSCLE | DROP})
    idx = {c: i for i, c in enumerate(cells)}
    w = lambda v: max(1, round(v / 0.06))
    E = [(idx[a], idx[b], w(v)) for a, b, v in chem if b in idx]
    G = [(idx[a], idx[b], w(v)) for a, b, v in gap if a in idx and b in idx]
    M = [(idx[a], b, w(v)) for a, b, v in chem if b in MUSCLE]
    json.dump(dict(cells=cells, chem=E, gap=G, nmj=M), open(RES / "graph.json", "w"))
    json.dump(stats, open(RES / "matrix_stats.json", "w"), indent=1)
    print(f"cells {len(cells)}  chem edges {len(E)}  gap entries {len(G)}  NMJ edges {len(M)}  max w {max(x for *_, x in E)}")


if __name__ == "__main__":
    sys.exit(main())
