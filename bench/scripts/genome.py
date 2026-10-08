"""Genome decode. Integer formulas match ocellus_brain::brain::decode."""

GROUP = {
    "PR-I": 0, "PR-II": 1, "Ant": 2, "PR-III": 3, "Cor": 4,
    "prRN": 5, "pr-AMG RN": 5, "pr-BTN RN": 5, "pr-cor RN": 5,
    "ant1 RN": 5, "ant2 RN": 5, "ant1/2 RN": 5, "ant-cor RN": 5,
    "2 RN": 5, "PN RN": 5, "Em": 5,
    "MGIN": 6, "MN": 7, "ACIN": 8, "AMG": 9,
    "BTN": 10, "pATEN": 10, "aATEN": 10, "RTEN-a": 10, "RTEN-b": 10, "DCEN": 10,
    "vacIN": 11, "trIN": 11, "aaIN": 12,
    "cor-ass BVIN": 12, "cil-BVIN": 12, "BVIN": 12, "PNIN": 12, "PBV PNIN": 12,
    "BPIN": 12, "prIN": 12, "antIN": 12, "ambiguous": 12,
    "Neck": 13, "ddN": 13, "PMGN": 13, "MTN": 14,
}


def neutral() -> bytes:
    out = bytearray(64)
    for i in range(64):
        if i < 16:
            out[i] = 128
        elif i < 24:
            out[i] = 64
        elif i < 32:
            out[i] = 85
        elif i < 38:
            out[i] = 128
    return bytes(out)


def _centered(base, b, scale, lo, hi):
    if b >= 128:
        v = base + (b - 128) * scale
    else:
        dec = (128 - b) * scale
        v = base - dec if base > dec else 0
    return min(hi, max(lo, v))


def decode(g: bytes) -> dict:
    if len(g) != 64:
        raise ValueError("genome must be 64 bytes")
    theta = []
    for b in g[:16]:
        mag = (b - 128) * 1966 // 128 if b >= 128 else (128 - b) * 1966 // 128
        if mag > 1966:
            mag = 1966
        theta.append(4096 + mag if b >= 128 else 4096 - mag)
    leaks = [2 + (b >> 6) for b in g[16:24]]
    gains = [500 + b * 1500 // 255 for b in g[24:32]]
    lr = []
    for b in g[32:36]:
        mag = (b - 128) * 100 // 128 if b >= 128 else (128 - b) * 100 // 128
        if mag > 100:
            mag = 100
        lr.append(100 + mag if b >= 128 else 100 - mag)
    return {
        "theta": theta,
        "leaks": leaks,
        "gains": gains,
        "lr": lr,
        "yolk0": _centered(100_000, g[36], 200, 80_000, 120_000),
        "competence": _centered(1_200, g[37], 4, 800, 1_600),
    }


def group_of(class_name: str) -> int:
    if class_name == "unassigned":
        return 15
    return GROUP[class_name]


def cell_physiology(view, decoded):
    leak, theta = [], []
    for cell in view["doc"]["cells"]:
        g = group_of(cell["class"])
        leak.append(decoded["leaks"][g % 8])
        theta.append(decoded["theta"][g] - 4096)
    return leak, theta


def apply_lr(left, right, lr):
    if lr >= 100:
        d = (lr - 100) * 10
        factor_l = 1000 + d
        factor_r = 1000 - d if 1000 >= d else 0
    else:
        d = (100 - lr) * 10
        factor_l = 1000 - d if 1000 >= d else 0
        factor_r = 1000 + d
    return left * factor_l // 1000, right * factor_r // 1000
