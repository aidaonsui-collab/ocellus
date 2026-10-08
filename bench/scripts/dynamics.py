"""Integer body integrator for connectome v1.

The brain step is model v1 from lif_model.py. Sensor drives are computed here
from the lure and the pose. Nothing in this file accepts a per-cell drive from
the caller.

PR-II dimming and antenna-only drive do not move the motor neurons (see
research/phase0_behavior.json). Escape displacement is therefore a function of
PR-II spike counts, and pitch righting is a function of antenna spike counts.
Thrust and the small yaw term still come from neuromuscular-junction weights.

Every number in CONST and the two trig tables is part of the contract the Move
package will copy. Angle units: 65536 = one full turn, 0 faces +x.
"""
import hashlib, json
from pathlib import Path

from lif_model import Brain

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "research"

# sin(i/256 * pi/2) * 256, i = 0..256. Generated once; do not recompute in Move.
SIN = (
    0, 2, 3, 5, 6, 8, 9, 11, 13, 14, 16, 17,
    19, 20, 22, 24, 25, 27, 28, 30, 31, 33, 34, 36,
    38, 39, 41, 42, 44, 45, 47, 48, 50, 51, 53, 55,
    56, 58, 59, 61, 62, 64, 65, 67, 68, 70, 71, 73,
    74, 76, 77, 79, 80, 82, 83, 85, 86, 88, 89, 91,
    92, 94, 95, 97, 98, 99, 101, 102, 104, 105, 107, 108,
    109, 111, 112, 114, 115, 117, 118, 119, 121, 122, 123, 125,
    126, 128, 129, 130, 132, 133, 134, 136, 137, 138, 140, 141,
    142, 144, 145, 146, 147, 149, 150, 151, 152, 154, 155, 156,
    157, 159, 160, 161, 162, 164, 165, 166, 167, 168, 170, 171,
    172, 173, 174, 175, 177, 178, 179, 180, 181, 182, 183, 184,
    185, 186, 188, 189, 190, 191, 192, 193, 194, 195, 196, 197,
    198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 207, 208,
    209, 210, 211, 212, 213, 214, 215, 215, 216, 217, 218, 219,
    220, 220, 221, 222, 223, 224, 224, 225, 226, 227, 227, 228,
    229, 229, 230, 231, 231, 232, 233, 233, 234, 235, 235, 236,
    237, 237, 238, 238, 239, 239, 240, 241, 241, 242, 242, 243,
    243, 244, 244, 245, 245, 245, 246, 246, 247, 247, 248, 248,
    248, 249, 249, 249, 250, 250, 250, 251, 251, 251, 252, 252,
    252, 252, 253, 253, 253, 253, 254, 254, 254, 254, 254, 255,
    255, 255, 255, 255, 255, 255, 256, 256, 256, 256, 256, 256,
    256, 256, 256, 256, 256,
)
# atan(i/256) in the same angle units, i = 0..256. atan(1) = 8192.
ATAN = (
    0, 41, 81, 122, 163, 204, 244, 285, 326, 367, 407, 448,
    489, 529, 570, 610, 651, 692, 732, 773, 813, 854, 894, 935,
    975, 1015, 1056, 1096, 1136, 1177, 1217, 1257, 1297, 1337, 1377, 1417,
    1457, 1497, 1537, 1577, 1617, 1656, 1696, 1736, 1775, 1815, 1854, 1894,
    1933, 1973, 2012, 2051, 2090, 2129, 2168, 2207, 2246, 2285, 2324, 2363,
    2401, 2440, 2478, 2517, 2555, 2594, 2632, 2670, 2708, 2746, 2784, 2822,
    2860, 2897, 2935, 2973, 3010, 3047, 3085, 3122, 3159, 3196, 3233, 3270,
    3307, 3344, 3380, 3417, 3453, 3490, 3526, 3562, 3599, 3635, 3670, 3706,
    3742, 3778, 3813, 3849, 3884, 3920, 3955, 3990, 4025, 4060, 4095, 4129,
    4164, 4199, 4233, 4267, 4302, 4336, 4370, 4404, 4438, 4471, 4505, 4539,
    4572, 4605, 4639, 4672, 4705, 4738, 4771, 4803, 4836, 4869, 4901, 4933,
    4966, 4998, 5030, 5062, 5094, 5125, 5157, 5188, 5220, 5251, 5282, 5313,
    5344, 5375, 5406, 5437, 5467, 5498, 5528, 5559, 5589, 5619, 5649, 5679,
    5708, 5738, 5768, 5797, 5826, 5856, 5885, 5914, 5943, 5972, 6000, 6029,
    6058, 6086, 6114, 6142, 6171, 6199, 6227, 6254, 6282, 6310, 6337, 6365,
    6392, 6419, 6446, 6473, 6500, 6527, 6554, 6580, 6607, 6633, 6660, 6686,
    6712, 6738, 6764, 6790, 6815, 6841, 6867, 6892, 6917, 6943, 6968, 6993,
    7018, 7043, 7068, 7092, 7117, 7141, 7166, 7190, 7214, 7238, 7262, 7286,
    7310, 7334, 7358, 7381, 7405, 7428, 7451, 7475, 7498, 7521, 7544, 7566,
    7589, 7612, 7635, 7657, 7679, 7702, 7724, 7746, 7768, 7790, 7812, 7834,
    7856, 7877, 7899, 7920, 7942, 7963, 7984, 8005, 8026, 8047, 8068, 8089,
    8110, 8131, 8151, 8172, 8192,
)

CONST = dict(
    drive=8000,          # PR-I drive at distance 0, full shade, before per-cell jitter
    near2=4000 * 4000,   # distance falloff, in position units squared
    shade_floor=64,      # /256, photoreceptor still gets some light when the cup faces away
    shade_span=192,      # /256 added when the cup faces the lure
    shadow_div=4,        # shade is divided by this while a shadow is on
    ant_tonic=1500,
    ant_gain=6400,       # added across 256 tilt units
    pr2_drive=12000,     # onto each PR-II cell during a shadow
    pr2_window=6,
    pr2_trigger=3,
    escape_ticks=8,
    escape_cooldown=40,
    escape_thrust=250,
    bout_bridge=3,
    thrust_base=40,
    thrust_div=100,      # thrust += (left + right neuromuscular weight) // thrust_div
    yaw_div=800,
    yaw_cap=400,
    pr1_turn=180,        # heading units toward the lure, per PR-I spike, capped by the error
    tilt_step=40,
    tilt_cap=512,
    yolk0=100_000,
    burn_idle=12,
    burn_bout=26,
    burn_pulse=18,
    burn_escape=20,
    drive_cap=20000,
)


def check_tables():
    if len(SIN) != 257 or SIN[0] != 0 or SIN[256] != 256 or SIN[128] != 181:
        raise RuntimeError("SIN table does not match the frozen values")
    if len(ATAN) != 257 or ATAN[0] != 0 or ATAN[256] != 8192 or ATAN[128] != 4836:
        raise RuntimeError("ATAN table does not match the frozen values")


check_tables()


def isqrt(n):
    if n <= 0:
        return 0
    x = 1 << ((n.bit_length() + 1) // 2)
    while True:
        y = (x + n // x) // 2
        if y >= x:
            return x
        x = y


def sin_cos(heading):
    """Return (sin, cos) in -256..256. Heading 0 is +x, increasing counterclockwise."""
    q, r = divmod(heading & 65535, 16384)
    i = (r * 256) // 16384
    s = SIN[i]
    c = SIN[256 - i]
    if q == 0:
        return s, c
    if q == 1:
        return c, -s
    if q == 2:
        return -s, -c
    return -c, s


def atan2_u16(y, x):
    if x == 0 and y == 0:
        return 0
    ax, ay = abs(x), abs(y)
    if ax >= ay:
        ang = ATAN[(ay * 256) // ax] if ax else 0
    else:
        ang = 16384 - ATAN[(ax * 256) // ay]
    if x >= 0 and y >= 0:
        return ang
    if x < 0 and y >= 0:
        return 32768 - ang
    if x < 0 and y < 0:
        return 32768 + ang
    return (65536 - ang) & 65535


def ang_diff(src, dst):
    d = (dst - src) & 65535
    return d - 65536 if d >= 32768 else d


def load_connectome():
    doc = json.loads((RES / "connectome.v1.json").read_text())
    blob = (RES / "connectome.v1.bin").read_bytes()
    digest = hashlib.blake2b(blob, digest_size=32).hexdigest()
    if digest != doc["data_hash"]:
        raise RuntimeError("connectome.v1.bin does not match data_hash")
    n = doc["n"]
    cells = doc["cells"]
    inhib = [c["sign"] == "inhibitory" for c in cells]
    chem = doc["chem"]
    gap = []
    for a, b, w in doc["gap"]:
        gap.append((a, b, w))
        gap.append((b, a, w))
    graph = {
        "n": n,
        "inhib": inhib,
        "ptr": None,
        "sens": doc["roles"]["pr1"] + doc["roles"]["antenna"],
    }
    graph["ptr"], graph["col"], graph["w"] = _csr(n, chem)
    graph["gptr"], graph["gcol"], graph["gw"] = _csr(n, gap)
    nmj_l = [0] * n
    nmj_r = [0] * n
    for i, muscle, w in doc["nmj"]:
        if muscle.startswith("mul"):
            nmj_l[i] += w
        else:
            nmj_r[i] += w
    view = {
        "doc": doc,
        "graph": graph,
        "pr1": doc["roles"]["pr1"],
        "pr2": doc["roles"]["pr2"],
        "ant": doc["roles"]["antenna"],
        "nmj_l": nmj_l,
        "nmj_r": nmj_r,
        "gain": [doc["class_gain"].get(c["class"], 1) for c in cells],
    }
    if len(view["pr1"]) != 23 or len(view["ant"]) != 2 or len(view["pr2"]) != 7:
        raise RuntimeError("sensory role lists changed shape")
    return view


def _csr(n, edges):
    rows = [[] for _ in range(n)]
    for i, j, w in edges:
        rows[i].append((j, w))
    ptr, col, ws = [0], [], []
    for r in rows:
        for j, w in sorted(r):
            col.append(j)
            ws.append(w)
        ptr.append(len(col))
    return ptr, col, ws


def new_body():
    return dict(
        x=0, y=0, heading=0, tilt=0, yolk=CONST["yolk0"],
        bout=0, escape=0, escape_cd=0, pr2_hist=[],
        hash=bytes(32), tick=0,
        escape_thrust_total=0,
    )


def _clamp_drive(v):
    if v < 0:
        return 0
    if v > CONST["drive_cap"]:
        return CONST["drive_cap"]
    return v


def sensor_drives(body, view, lure, light_level, shadow, gains=None):
    """32 drives: PR-I (23), Ant1, Ant2, PR-II (7). light_level is 0..256."""
    lx, ly = lure
    dx, dy = lx - body["x"], ly - body["y"]
    dist2 = dx * dx + dy * dy
    dist = isqrt(dist2)
    intensity = CONST["drive"] * CONST["near2"] // (CONST["near2"] + dist2)
    intensity = intensity * light_level // 256
    s, c = sin_cos(body["heading"])
    dot = (c * dx + s * dy) // dist if dist else 256
    if dot > 256:
        dot = 256
    if dot < -256:
        dot = -256
    shade = CONST["shade_floor"] + CONST["shade_span"] * max(dot, 0) // 256
    if shadow:
        shade //= CONST["shadow_div"]
    g = view["gain"]
    drives = []
    for k, idx in enumerate(view["pr1"]):
        jit = 780 + 440 * ((k * 7919) % 23) // 22
        d = intensity * shade * jit // (256 * 1000) * g[idx]
        if gains is not None:
            d = d * gains[0] // 1000
        drives.append(_clamp_drive(d))
    tilt = body["tilt"]
    up = (CONST["ant_tonic"] + CONST["ant_gain"] * max(tilt, 0) // 256) * g[view["ant"][0]]
    dn = (CONST["ant_tonic"] + CONST["ant_gain"] * max(-tilt, 0) // 256) * g[view["ant"][1]]
    if gains is not None:
        up = up * gains[2] // 1000
        dn = dn * gains[2] // 1000
    drives.append(_clamp_drive(up))
    drives.append(_clamp_drive(dn))
    pr2 = CONST["pr2_drive"] if shadow else 0
    if gains is not None:
        pr2 = pr2 * gains[1] // 1000
    for idx in view["pr2"]:
        drives.append(_clamp_drive(pr2 * g[idx]))
    return drives


def _digest(drives):
    dig = 0
    for i, d in enumerate(drives):
        dig = (dig + d * (i + 1)) & 0xFFFFFFFF
    return dig


def _hash_tick(prev, tick, drives, fired, n):
    raw = bytearray(prev)
    raw += int(tick).to_bytes(8, "little")
    raw += _digest(drives).to_bytes(4, "little")
    bits = bytearray((n + 7) // 8)
    for i in fired:
        bits[i >> 3] |= 1 << (i & 7)
    raw += bits
    return hashlib.blake2b(raw, digest_size=32).digest()


def step(body, brain, view, lure, light_level=256, shadow=False, pulse=False, decoded=None):
    """One tick. Mutates body and brain. Returns the fired cell indices.

    `decoded` is the genome physiology from genome.decode. Omitted, the tick
    uses the neutral constants and matches the original course.
    """
    gains = leak = theta = None
    if decoded is not None:
        from genome import cell_physiology
        gains = decoded["gains"]
        leak, theta = cell_physiology(view, decoded)
    drives = sensor_drives(body, view, lure, light_level, shadow, gains)
    order = view["pr1"] + view["ant"] + view["pr2"]
    fired = brain.step(order, drives, leak=leak, theta=theta)
    fired_set = set(fired)
    left = sum(view["nmj_l"][i] for i in fired)
    right = sum(view["nmj_r"][i] for i in fired)
    if decoded is not None:
        from genome import apply_lr
        left, right = apply_lr(left, right, decoded["lr"][0])
    pr1_n = sum(1 for i in view["pr1"] if i in fired_set)
    pr2_n = sum(1 for i in view["pr2"] if i in fired_set)
    ant1 = view["ant"][0] in fired_set
    ant2 = view["ant"][1] in fired_set

    c = CONST
    if left + right > 0:
        body["bout"] = c["bout_bridge"]
    elif body["bout"] > 0:
        body["bout"] -= 1
    vigor = body["bout"] > 0

    hist = body["pr2_hist"]
    hist.append(pr2_n)
    if len(hist) > c["pr2_window"]:
        del hist[0]
    if body["escape_cd"] > 0:
        body["escape_cd"] -= 1
    elif body["escape"] == 0 and sum(hist) >= c["pr2_trigger"]:
        body["escape"] = c["escape_ticks"]
        body["escape_cd"] = c["escape_cooldown"]

    # Steer toward the lure in proportion to this tick's PR-I spikes.
    if pr1_n and light_level:
        bearing = atan2_u16(lure[1] - body["y"], lure[0] - body["x"])
        err = ang_diff(body["heading"], bearing)
        mag = abs(err) if abs(err) < pr1_n * c["pr1_turn"] else pr1_n * c["pr1_turn"]
        if err < 0:
            mag = -mag
        body["heading"] = (body["heading"] + mag) & 65535
    if vigor:
        yaw = (right - left) // c["yaw_div"]
        if yaw > c["yaw_cap"]:
            yaw = c["yaw_cap"]
        elif yaw < -c["yaw_cap"]:
            yaw = -c["yaw_cap"]
        body["heading"] = (body["heading"] + yaw) & 65535

    if ant1 and not ant2:
        body["tilt"] -= c["tilt_step"]
    elif ant2 and not ant1:
        body["tilt"] += c["tilt_step"]
    cap = c["tilt_cap"]
    if body["tilt"] > cap:
        body["tilt"] = cap
    elif body["tilt"] < -cap:
        body["tilt"] = -cap

    thrust = 0
    escaping = body["escape"] > 0
    if vigor:
        thrust = c["thrust_base"] + (left + right) // c["thrust_div"]
    if escaping:
        thrust += c["escape_thrust"]
        body["escape"] -= 1
        body["escape_thrust_total"] += c["escape_thrust"]
    s, cos = sin_cos(body["heading"])
    body["x"] += thrust * cos // 256
    body["y"] += thrust * s // 256

    burn = c["burn_idle"]
    if vigor:
        burn += c["burn_bout"]
    if pulse:
        burn += c["burn_pulse"]
    if escaping:
        burn += c["burn_escape"]
    body["yolk"] = body["yolk"] - burn if body["yolk"] > burn else 0

    body["tick"] += 1
    body["hash"] = _hash_tick(body["hash"], body["tick"], drives, fired, view["graph"]["n"])
    return fired


def fresh(view):
    return new_body(), Brain(view["graph"], "v1")


def run(view, schedule):
    """schedule: list of (ticks, lure, light_level, shadow, pulse, tilt0 or None)."""
    body, brain = fresh(view)
    trace = []
    for ticks, lure, level, shadow, pulse, tilt in schedule:
        if tilt is not None:
            body["tilt"] = tilt
        for _ in range(ticks):
            step(body, brain, view, lure, level, shadow, pulse)
            trace.append((body["x"], body["y"], body["heading"], body["tilt"], body["yolk"], body["escape_thrust_total"]))
    return body, brain, trace


def pose_key(body):
    return (body["x"], body["y"], body["heading"], body["tilt"], body["yolk"], body["hash"].hex(), body["escape_thrust_total"])
