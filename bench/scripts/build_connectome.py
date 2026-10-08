#!/usr/bin/env python3
"""Build the canonical Ciona connectome from the Ryan et al. 2016 matrices.

Reads the Figure 16 workbooks and the Figure 1 cell key, writes:

  research/reconcile.csv       one row per source label
  research/signs.csv           one row per canonical cell
  research/connectome.v1.json  cells, edges, roles, provenance
  research/connectome.v1.bin   canonical binary; its blake2b256 is data_hash

The benchmark graph (research/graph.json, built by build_graph.py) is left
untouched. This file is the graph a frozen Connectome object will store.

Weights match build_graph.py: contact depth in µm ÷ 0.06, rounded, minimum 1.
Gap junctions are symmetrized by taking the max of the two directions.
"""
import csv, hashlib, json, re, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_graph import load

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "research"
CHEM_XLSX = "elife-fig16-data1.xlsx"
GAP_XLSX = "elife-fig16-data2.xlsx"
FIG1_XLSX = "elife-fig1-data1.xlsx"

MUSCLE = {"mul", "mulm", "mur", "murm"}
# Not neurons. The paper excludes basal lamina and ependymal cells from the
# neuron matrix ("synapses onto the basal lamina (bm), synapses onto ependymal
# cells (Ep)"). Muscle columns are pooled neuromuscular targets.
DROP = {
    "bm": ("basal lamina", "Ryan et al. 2016 exclude synapses onto the basal lamina from the neuron matrix."),
    "bm-noto": ("basal lamina", "Basal lamina over the notochord. Same exclusion as bm."),
    "Ep": ("ependymal", "Ryan et al. 2016 define ependymal cells as ciliated cells on the canal that lack an axon, and exclude them from the neuron matrix."),
}
DROP_REASON_MUSCLE = "Pooled muscle column. Kept as a neuromuscular-junction target, not as a cell."


def expand(spec):
    """'pr1-pr23' or a list of ids -> [id, ...]."""
    if isinstance(spec, (list, tuple)):
        return list(spec)
    m = re.fullmatch(r"([A-Za-z]+)(\d+)-\1(\d+)", spec)
    if m:
        a, b = int(m.group(2)), int(m.group(3))
        return [f"{m.group(1)}{i}" for i in range(a, b + 1)]
    m = re.fullmatch(r"([A-Za-z]+)(\d+)-\1(\d+)", spec.replace(" ", ""))
    if m:
        a, b = int(m.group(2)), int(m.group(3))
        return [f"{m.group(1)}{i}" for i in range(a, b + 1)]
    return spec.split()


# Priority, class, member ids. Later (higher) priority wins when Figure 1
# lists a cell in more than one row. Cross-cutting rows (prIN, antIN) stay
# in also_classes and do not override a structural class.
# Member ids are canonical ids, after the aliases below.
CLASSES = [
    (10, "RTEN-a", "pns1 pns2 pns5 pns6 pns9 pns13".split()),
    (10, "RTEN-b", "pns3 pns4 pns7 pns10 pns11 pns12".split()),
    (10, "aATEN", expand("ATEN1-ATEN4")),
    (10, "pATEN", "pna pnb pnc pnf".split()),
    (10, "DCEN", "pnh pnu pnx".split()),
    (20, "PR-I", expand("pr1-pr23")),
    (20, "PR-II", "pra prb prc prd pre prf prg".split()),
    (20, "PR-III", "lens6 lens7 84 101 110 113 114".split()),
    (20, "vacIN", ["vacIN1", "vacIN2"]),
    (20, "trIN", ["trIN"]),
    (20, "Ant", ["Ant1", "Ant2"]),
    (20, "ambiguous", ["107", "177"]),
    (20, "Cor", [f"coronet{i}" for i in range(1, 17)]),
    (20, "aaIN", ["aaIN1", "aaIN2", "aaIN3"]),
    (30, "cor-ass BVIN", "1 2 15 23 38 55 59 60 62 65 68 70 73 78 79".split()),
    (30, "cil-BVIN", "3 13 17 18 21 22 24 20 33 41 42 43 48 50 61 65 85 88 92".split()),
    (30, "BVIN", ["ukn", "ukn2"]),
    (40, "PNIN", "4 6 20 25 29 30 61 65 85 88".split()),
    (40, "PBV PNIN", "160 162 163 164".split()),
    (45, "BPIN", ["90", "92"]),
    (50, "prRN", "80 86 96 100 121 126".split()),
    (60, "pr-AMG RN", "74 94 108 116 124 127 140 157".split()),
    (60, "pr-BTN RN", "123 130".split()),
    (60, "pr-cor RN", "105 112 119".split()),
    (60, "ant1 RN", "147 152 161".split()),
    (60, "ant2 RN", "135 153 159".split()),
    (55, "ant1/2 RN", "120 134 142 143 152".split()),
    (70, "ant-cor RN", ["120"]),
    (60, "2 RN", "93 103 106 122 125".split()),
    (60, "PN RN", ["131"]),
    (60, "Em", ["Em1", "Em2"]),
    (60, "Neck", ["NeckNL", "NeckNR"]),
    (60, "AMG", expand("AMG1-AMG7")),
    (60, "ddN", ["ddNL", "ddNR"]),
    (60, "MGIN", [f"MGIN{i}{s}" for i in (1, 2, 3) for s in "LR"]),
    (60, "MN", [f"MN{i}{s}" for i in range(1, 6) for s in "LR"]),
    (60, "PMGN", ["PMGN1", "PMGN2"]),
    (60, "ACIN", ["ACIN1L", "ACIN2L", "ACIN2R"]),
    (60, "MTN", ["midtail1", "midtail2", "midtail4", "midtail7"]),
    (60, "BTN", expand("BTN1-BTN4")),
]
# Rows that describe an input pattern, not a cell type. Recorded, not primary.
CROSS = [
    ("prIN", "13 16 17 22 42 50 68 70 78 138".split()),
    ("antIN", "16 24 33 38 60 68 70 73 79 138".split()),
]

# Inhibitory presynaptic cells. Everyone else is an explicit default.
INHIB_BASIS = {}
for c in "pra prb prc prd pre prf prg".split():
    INHIB_BASIS[c] = "Kourakis et al. 2019: PR-II photoreceptors are GABAergic."
for c in "74 94 108 116 124 127 140 157".split():
    INHIB_BASIS[c] = "Kourakis et al. 2019: pr-AMG relay neurons are GABAergic. Class from Ryan et al. 2016 Figure 1."
for c in "147 152 161 135 153 159 120 134 142 143".split():
    INHIB_BASIS[c] = "Bostwick et al. 2020: antenna relay neurons are inhibitory. Class from Ryan et al. 2016 Figure 1."
for c in ("ACIN1L", "ACIN2L", "ACIN2R"):
    INHIB_BASIS[c] = "Ryan et al. 2016 Figure 1 cell key: ACIN is the ascending contralateral inhibitory neuron."
DEFAULT_BASIS = "Default excitatory. No transmitter identity for this cell in Ryan 2016, Kourakis 2019, or Bostwick 2020."


def canonical(label):
    """Return (canonical_id or None, decision, confidence, reason).

    None means the label is not a neuron.
    """
    if label in MUSCLE:
        return None, "drop", "high", DROP_REASON_MUSCLE
    if label in DROP:
        cls, why = DROP[label]
        return None, "drop", "high", why
    m = re.fullmatch(r"Cor(\d+)", label)
    if m:
        n = int(m.group(1))
        return (f"coronet{n}", "merge", "high",
                "Gap matrix abbreviates coronet cells as Cor. Figure 1 uses Cor for coronet1–coronet16 and the chemical matrix spells them coronet. Same number, one cell.")
    if label == "165":
        return ("NeckNL", "merge", "medium",
                "Figure 1 lists neck neurons as '165, 166' beside 'NeckNL and NeckNR'. The chemical matrix uses the names and the gap matrix uses the numbers. Paired in that listed order.")
    if label == "166":
        return ("NeckNR", "merge", "medium",
                "Figure 1 lists neck neurons as '165, 166' beside 'NeckNL and NeckNR'. Paired in that listed order.")
    if label == "BPN1":
        return ("90", "merge", "medium",
                "The paper identifies two bipolar neurons, cells 90 and 92. The gap matrix calls them BPN1 and BPN2; the chemical matrix uses 90 and 92. Paired in listed order (BPN1=90, BPN2=92). Which number is which is not stated in the source files.")
    if label == "BPN2":
        return ("92", "merge", "medium",
                "Paired in listed order with cell 92. See BPN1.")
    extra = {
        "vacIN1": "Figure 1 names this class lens1 and lens2. The matrices name them vacIN1 and vacIN2. The matrix name is canonical; lens1 is not a second cell.",
        "vacIN2": "Figure 1 name lens2. The matrix name vacIN2 is canonical; lens2 is not a second cell.",
        "trIN": "Figure 1 cell id 36. One cell. The matrix name trIN is canonical.",
        "aaIN1": "Figure 1 numbers the three aaINs 95, 102 and 115, and does not say which matrix index that is. aaIN1–aaIN3 stay canonical. Those numbers are not extra cells.",
        "aaIN2": "See aaIN1. Pairing to 95, 102, 115 is not stated.",
        "aaIN3": "See aaIN1. Pairing to 95, 102, 115 is not stated.",
        "Em1": "Figure 1 cell id 109. Distinct from ACIN1L, which the same key marks '109*'.",
        "Em2": "Figure 1 cell id 99.",
        "PMGN1": "Figure 1 also calls this tail8.",
        "PMGN2": "Figure 1 also calls this tail15.",
        "pnw": "Present in both matrices. Figure 1 lists DCEN ids pnh, pnu, pnx, pnz and does not list pnw. pnz is absent from both matrices. pnw is kept as its own cell and is not merged into pnz.",
        "midtail3": "Gap matrix only. Figure 1 midtail subtypes are 1, 2, 4 and 7. Not merged into those.",
        "tail5": "Gap matrix only. Figure 1 does not list a tail5 neuron (PMGN alternates are tail8 and tail15). Kept as its own cell.",
        "pns14": "Chemical matrix only. Not in the Figure 1 RTEN id lists.",
    }
    if label in extra:
        return label, "keep", "high" if label not in ("pnw", "midtail3", "tail5", "pns14") else "low", extra[label]
    return label, "keep", "high", "Same label in the matrix and the canonical id."


def class_index():
    """Map canonical id -> (primary class, other Figure 1 classes)."""
    best = {}
    also = {}
    for pri, name, ids in CLASSES:
        for i in ids:
            if i not in best or pri >= best[i][0]:
                best[i] = (pri, name)
            also.setdefault(i, [])
            if name not in also[i]:
                also[i].append(name)
    for name, ids in CROSS:
        for i in ids:
            # Input-pattern rows fill in only when no structural class exists.
            if i not in best:
                best[i] = (15, name)
            also.setdefault(i, [])
            if name not in also[i]:
                also[i].append(name)
    return {i: (name, [c for c in also.get(i, []) if c != name]) for i, (_pri, name) in best.items()}


def side_of(cid, cls):
    if cid.endswith("NL"):
        return "L"
    if cid.endswith("NR"):
        return "R"
    if cid.endswith("L"):
        return "L"
    if cid.endswith("R"):
        return "R"
    if cls == "Cor":
        return "L"  # the coronet cluster sits on the left (Ryan et al. 2016)
    return ""


def nat(s):
    # (0, n) for numbers and (1, text) for words, so mixed keys still order.
    return [(0, int(t)) if t.isdigit() else (1, t.lower()) for t in re.findall(r"\d+|\D+", s or "")]


def weight(v):
    return max(1, round(v / 0.06))


def sheet_labels(path):
    """Every row and column label, including cells with no positive entry."""
    import openpyxl
    ws = openpyxl.load_workbook(path, data_only=True).active
    rows = list(ws.iter_rows(values_only=True))
    out, seen = [], set()
    hdr = [str(x).strip() if x is not None else "" for x in rows[0]]
    names = []
    for r in rows[1:]:
        if r[0] is not None:
            names.append(str(r[0]).strip())
    for lab in names + hdr[1:]:
        if not lab or "total" in lab.lower() or lab in seen:
            continue
        seen.add(lab)
        out.append(lab)
    return out


# Figure 1 accessory cells and ids that are not neurons in the synapse matrices.
ABSENT_EXTRA = [
    ("lens4", "lens", "Accessory lens cell in Figure 1. Not a neuron in the synapse matrices."),
    ("lens5", "lens", "Accessory lens cell in Figure 1. Not a neuron in the synapse matrices."),
    ("lens8", "lens", "Accessory lens cell in Figure 1. Not a neuron in the synapse matrices."),
    ("oacc1", "oacc", "Otolith-associated ciliated cell in Figure 1. Accessory, not in the synapse matrices."),
    ("oacc2", "oacc", "Otolith-associated ciliated cell in Figure 1 (also numbered 45). Accessory, not in the synapse matrices."),
    ("Otolith", "otolith", "Accessory gravity organ in Figure 1. Not a neuron."),
    ("Ocellus", "ocellus", "Accessory pigment cup in Figure 1. Not a neuron."),
    ("pnz", "DCEN", "Figure 1 lists pnz as a DCEN. Neither matrix contains pnz. Not merged with pnw."),
]


def sha256(path):
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def build():
    chem = load(RES / CHEM_XLSX)
    gap = load(RES / GAP_XLSX)
    classes = class_index()
    edged = set()
    edged_canon = set()
    for a, b, _v in chem + gap:
        edged.add(a)
        edged.add(b)
        for lab in (a, b):
            cid, _decision, _conf, _reason = canonical(lab)
            if cid:
                edged_canon.add(cid)
    labels = []
    for src in (CHEM_XLSX, GAP_XLSX):
        for lab in sheet_labels(RES / src):
            cid, decision, conf, reason = canonical(lab)
            cls, also = ("", [])
            if cid:
                cls, also = classes.get(cid, ("unassigned", []))
                if lab not in edged and decision == "merge":
                    reason += " This label has no positive matrix entry, so the alias moves no edges."
                    conf = "high"
                elif lab not in edged and decision == "keep" and cid in edged_canon:
                    reason = "Listed in this sheet with no positive entry. Its synapses are in the other matrix."
                elif lab not in edged and decision == "keep":
                    decision = "absent"
                    conf = "high"
                    reason = "Listed in this sheet with no positive entry, and it has no synapse in the other matrix either. Not added as an empty cell."
                elif cls == "unassigned" and decision == "keep" and conf == "high":
                    conf = "low"
                    reason = "In a synapse matrix, not named in Figure 1 source data 1. Kept, so its synapses are not dropped."
            labels.append(dict(source_file=src, source_label=lab, canonical_id=cid or "",
                               klass=cls if cid else (DROP[lab][0] if lab in DROP else "muscle pool"),
                               also=" ".join(also), side=side_of(cid, cls) if cid else "",
                               decision=decision, confidence=conf, reason=reason))

    # neuron set: cells that actually touch a kept synapse
    neurons = {}
    for row in labels:
        if row["decision"] in ("drop", "absent") or row["canonical_id"] not in edged_canon:
            continue
        neurons.setdefault(row["canonical_id"], row)

    # absent Figure 1 ids
    present = set(neurons)
    absent_rows = []
    for _pri, name, ids in CLASSES:
        for i in ids:
            if i not in present:
                absent_rows.append(dict(
                    source_file=FIG1_XLSX, source_label=i, canonical_id=i, klass=name,
                    also="", side=side_of(i, name), decision="absent", confidence="high",
                    reason="Named in Figure 1 source data 1 and has no positive entry in either Figure 16 matrix. Not given empty edges.",
                ))
    for cid, cls, why in ABSENT_EXTRA:
        if cid in present:
            continue
        absent_rows.append(dict(
            source_file=FIG1_XLSX, source_label=cid, canonical_id=cid, klass=cls,
            also="", side=side_of(cid, cls), decision="absent", confidence="high", reason=why,
        ))

    cells = []
    for cid in sorted(neurons, key=nat):
        row = neurons[cid]
        sign = "inhibitory" if cid in INHIB_BASIS else "excitatory"
        basis = INHIB_BASIS.get(cid, DEFAULT_BASIS)
        # Gap edges on 90 and 92 arrived through the BPN order pairing.
        # 165 and 166 have no positive gap entries, so the neck alias moves nothing.
        confidence = "medium" if cid in {"90", "92"} else row["confidence"]
        cells.append({
            "id": cid,
            "class": row["klass"],
            "also_classes": row["also"].split() if row["also"] else [],
            "side": row["side"],
            "sign": sign,
            "sign_basis": basis,
            "confidence": confidence,
        })
    index = {c["id"]: i for i, c in enumerate(cells)}

    dropped_edges = []
    chem_edges = {}
    nmj = {}
    for a, b, v in chem:
        ca, da, _, _ = canonical(a)
        cb, db, _, _ = canonical(b)
        w = weight(v)
        if cb is None and b in MUSCLE and ca is not None:
            nmj[(index[ca], b)] = nmj.get((index[ca], b), 0) + w
            continue
        if ca is None or cb is None:
            dropped_edges.append((a, b, "chem"))
            continue
        key = (index[ca], index[cb])
        chem_edges[key] = chem_edges.get(key, 0) + w

    # directed gap weights, then symmetrize by max
    directed = {}
    for a, b, v in gap:
        ca, _, _, _ = canonical(a)
        cb, _, _, _ = canonical(b)
        if ca is None or cb is None or ca == cb:
            if ca is None or cb is None:
                dropped_edges.append((a, b, "gap"))
            continue
        key = (index[ca], index[cb])
        directed[key] = max(directed.get(key, 0), weight(v))
    gap_undirected = {}
    for (i, j), w in directed.items():
        a, b = (i, j) if i < j else (j, i)
        gap_undirected[(a, b)] = max(gap_undirected.get((a, b), 0), w, directed.get((j, i), 0))

    chem_list = [[i, j, w] for (i, j), w in sorted(chem_edges.items())]
    gap_list = [[i, j, w] for (i, j), w in sorted(gap_undirected.items())]
    nmj_list = [[i, m, w] for (i, m), w in sorted(nmj.items(), key=lambda kv: (kv[0][0], kv[0][1]))]

    def role(pred):
        return [i for i, c in enumerate(cells) if pred(c)]

    roles = {
        "pr1": role(lambda c: c["class"] == "PR-I"),
        "pr2": role(lambda c: c["class"] == "PR-II"),
        "antenna": role(lambda c: c["class"] == "Ant"),
        "mn_left": role(lambda c: c["class"] == "MN" and c["side"] == "L"),
        "mn_right": role(lambda c: c["class"] == "MN" and c["side"] == "R"),
    }
    for name, want in (("pr1", 23), ("pr2", 7), ("antenna", 2), ("mn_left", 5), ("mn_right", 5)):
        if len(roles[name]) != want:
            raise SystemExit(f"role {name} has {len(roles[name])} cells, expected {want}")

    blob = canonical_binary(cells, chem_list, gap_list, nmj_list)
    data_hash = hashlib.blake2b(blob, digest_size=32).hexdigest()
    doc = {
        "format": "ocellus-connectome-v1",
        "source": "Ryan K, Lu Z, Meinertzhagen IA (2016) eLife 5:e16962, CC BY 4.0",
        "source_sha256": {
            CHEM_XLSX: sha256(RES / CHEM_XLSX),
            GAP_XLSX: sha256(RES / GAP_XLSX),
            FIG1_XLSX: sha256(RES / FIG1_XLSX),
        },
        "weight": "contact depth µm / 0.06, rounded, minimum 1 (60-nm section count)",
        "data_hash": data_hash,
        "hash_of": "connectome.v1.bin (see canonical_binary in build_connectome.py)",
        "n": len(cells),
        "cells": cells,
        "chem": chem_list,
        "gap": gap_list,
        "nmj": nmj_list,
        "roles": roles,
        "class_gain": {cls: 1 for cls in sorted({c["class"] for c in cells})},
        "gain_note": "Every class gain is 1. Per-class retuning was not applied. Dimming and antenna drive still do not reach motor neurons; the body integrator uses PR-II and antenna spike counts for those two paths.",
        "dropped_edge_count": len(dropped_edges),
        "counts": {
            "cells": len(cells),
            "inhibitory": sum(1 for c in cells if c["sign"] == "inhibitory"),
            "unassigned": sum(1 for c in cells if c["class"] == "unassigned"),
            "chem_edges": len(chem_list),
            "gap_undirected": len(gap_list),
            "nmj_edges": len(nmj_list),
            "absent_fig1": len(absent_rows),
            "merged_labels": sum(1 for r in labels if r["decision"] == "merge"),
        },
    }
    return labels, absent_rows, cells, doc, blob


def canonical_binary(cells, chem, gap, nmj):
    """Little-endian listing. Edges are by cell index in `cells` order.

    magic b'OCELLUS1'
    u16 n
    for each cell: u8 name_len, name bytes, u8 sign (1 inhibitory), u8 class_len, class bytes
    u32 chem_count, then u16 pre, u16 post, u16 weight
    u32 gap_count, then u16 a, u16 b, u16 weight (a < b)
    u32 nmj_count, then u16 cell, u8 muscle_len, muscle bytes, u16 weight
    """
    def u16(n):
        return int(n).to_bytes(2, "little")

    def u32(n):
        return int(n).to_bytes(4, "little")

    buf = bytearray(b"OCELLUS1")
    buf += u16(len(cells))
    for c in cells:
        name = c["id"].encode()
        cls = c["class"].encode()
        buf += bytes([len(name)]) + name
        buf += bytes([1 if c["sign"] == "inhibitory" else 0])
        buf += bytes([len(cls)]) + cls
    buf += u32(len(chem))
    for i, j, w in chem:
        buf += u16(i) + u16(j) + u16(w)
    buf += u32(len(gap))
    for i, j, w in gap:
        buf += u16(i) + u16(j) + u16(w)
    buf += u32(len(nmj))
    for i, m, w in nmj:
        mb = m.encode()
        buf += u16(i) + bytes([len(mb)]) + mb + u16(w)
    return bytes(buf)


def write_csv(path, rows, fields):
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow(r)


def main():
    labels, absent, cells, doc, blob = build()
    fields = ["source_file", "source_label", "canonical_id", "class", "also_classes", "side", "decision", "confidence", "reason"]
    rec_rows = []
    for r in labels + absent:
        rec_rows.append({
            "source_file": r["source_file"], "source_label": r["source_label"],
            "canonical_id": r["canonical_id"], "class": r["klass"], "also_classes": r["also"],
            "side": r["side"], "decision": r["decision"], "confidence": r["confidence"], "reason": r["reason"],
        })
    rec_rows.sort(key=lambda r: (r["decision"], r["source_file"], nat(r["source_label"] or r["canonical_id"])))
    write_csv(RES / "reconcile.csv", rec_rows, fields)
    write_csv(RES / "signs.csv", [
        {"canonical_id": c["id"], "class": c["class"], "sign": c["sign"], "basis": c["sign_basis"]}
        for c in cells
    ], ["canonical_id", "class", "sign", "basis"])
    (RES / "connectome.v1.bin").write_bytes(blob)
    (RES / "connectome.v1.json").write_text(json.dumps(doc, indent=1) + "\n")
    c = doc["counts"]
    print(f"cells {c['cells']}  inhibitory {c['inhibitory']}  unassigned {c['unassigned']}")
    print(f"chem {c['chem_edges']}  gap undirected {c['gap_undirected']}  nmj {c['nmj_edges']}")
    print(f"merged labels {c['merged_labels']}  absent fig1 {c['absent_fig1']}  dropped edges {doc['dropped_edge_count']}")
    print("data_hash", doc["data_hash"])
    uns = [c["id"] for c in cells if c["class"] == "unassigned"]
    print("unassigned:", " ".join(uns))


if __name__ == "__main__":
    main()
