#!/usr/bin/env python3
"""Phase 0 exit check for the reconciled connectome and the body integrator.

  python3 bench/scripts/test_course.py

Writes research/phase0_behavior.json. The assertions are the ship gate for
this connectome: light carries the larva forward, darkness stops it, a shadow
adds an escape displacement, and the same inputs replay to the same hash.
"""
import json, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dynamics import CONST, load_connectome, fresh, run, step, pose_key, isqrt
from lif_model import Brain

RES = Path(__file__).resolve().parents[2] / "research"
LURE = (1500, 0)
DATA_HASH = "9004dac630dbed5d88438c892deab08bb3a927f75e6337301cc720eeac65cf16"


def motor(view, fired):
    return sum(view["nmj_l"][i] + view["nmj_r"][i] for i in fired)


def mean_motor(view, schedule, ticks, skip):
    brain = Brain(view["graph"], "v1")
    total = 0
    n = 0
    for t in range(ticks):
        idx, drv = schedule(t)
        fired = brain.step(idx, drv)
        if t >= skip:
            total += motor(view, fired)
            n += 1
    return round(total / n, 1)


def main():
    view = load_connectome()
    doc = view["doc"]
    assert doc["data_hash"] == DATA_HASH
    assert doc["n"] == 224
    assert doc["counts"]["inhibitory"] == 28
    assert doc["counts"]["chem_edges"] == 3010
    ids = [c["id"] for c in doc["cells"]]
    for name in ("90", "92", "coronet1", "NeckNL", "NeckNR"):
        assert name in ids
    i90 = ids.index("90")
    i_cor = ids.index("coronet1")
    assert any(a == i90 or b == i90 for a, b, _w in doc["gap"])
    assert any(a == i_cor or b == i_cor for a, b, _w in doc["gap"])

    # Silence, and the two pathways the motor neurons still do not express.
    brain = Brain(view["graph"], "v1")
    assert sum(len(brain.step([], [])) for _ in range(30)) == 0
    pr1, ant, pr2 = view["pr1"], view["ant"], view["pr2"]
    jit = [780 + 440 * ((k * 7919) % 23) // 22 for k in range(23)]

    def light(d):
        return pr1, [d * jit[k] // 1000 for k in range(23)]

    def dim(t):
        if t < 80:
            return light(6000)
        if t < 110:
            return pr2, [6500] * 7
        return [], []

    probe = {
        "pr1_drive_8000_motor_mean": mean_motor(view, lambda t: light(8000), 200, 50),
        "dimming_motor_mean": mean_motor(view, dim, 150, 80),
        "antenna_only_motor_mean": mean_motor(view, lambda t: (ant, [6000, 6000]), 120, 30),
        "integrator": "spike-count fallback for PR-II and antenna; thrust from neuromuscular weights",
    }
    assert probe["pr1_drive_8000_motor_mean"] > 0
    assert probe["dimming_motor_mean"] == 0
    assert probe["antenna_only_motor_mean"] == 0

    light_sched = [(100, LURE, 256, False, False, None)]
    body_a, _, trace = run(view, light_sched)
    body_b, _, _ = run(view, light_sched)
    assert pose_key(body_a) == pose_key(body_b)
    assert trace[99][0] > 500
    assert abs(trace[99][1]) * 3 < trace[99][0]
    assert trace[99][4] < CONST["yolk0"]

    _body, _, both = run(view, light_sched + [(50, LURE, 0, False, False, None)])
    # Position and heading hold. Yolk keeps burning, so the full trace does not.
    tail = [(x, y, h) for x, y, h, *_ in both[-15:]]
    assert len(set(tail)) == 1
    assert both[20][0] > both[0][0]

    def window(shadow):
        body, brain = fresh(view)
        mark = None
        for t in range(80):
            step(body, brain, view, LURE, 256, shadow and 40 <= t < 55, False)
            if t == 39:
                mark = (body["x"], body["y"])
        return body["escape_thrust_total"], isqrt((body["x"] - mark[0]) ** 2 + (body["y"] - mark[1]) ** 2)

    control_thrust, control_d = window(False)
    shadow_thrust, shadow_d = window(True)
    assert control_thrust == 0
    assert shadow_thrust == CONST["escape_ticks"] * CONST["escape_thrust"]
    assert shadow_d > control_d + 500

    _body, _, tilt_trace = run(view, [(80, LURE, 0, False, False, 300)])
    assert tilt_trace[0][3] == 300
    assert tilt_trace[-1][3] < 160
    assert tilt_trace[-1][3] < tilt_trace[0][3]

    # Phase 0 acceptance (docs/BRAIN_MODES_PLAN.md), measured by probe_dynamics.py.
    # Recorded here, not asserted: the probe is the run that fails until they pass.
    from probe_dynamics import Net, phase0_probe
    acc = phase0_probe(Net(view))
    d = acc["dimming_step"]
    phase0 = {
        "pass": acc["pass"],
        "all_pass": acc["all_pass"],
        "dimming_step": {k: v for k, v in d.items() if not k.startswith("spikes_by_class")},
        "antenna_alone": acc["antenna_alone"],
        "antenna_steers_dimming": acc["antenna_steers_dimming"],
        "pr1_regression": acc["pr1_regression"],
        "sustained_swimming": acc["sustained_swimming"],
        "seizure": acc["seizure"],
        "coverage": acc["coverage"],
    }
    dyn = Path(__file__).resolve().parents[1] / "results" / "dynamics.json"
    abl = json.loads(dyn.read_text()).get("phase0", {}).get("ablations", []) if dyn.exists() else []
    if abl:
        phase0["ablations"] = {
            "file": "bench/results/dynamics.json",
            "hypotheses": len(abl),
            "all_pass": sum(1 for a in abl if a["all_pass"]),
            "most_tests_passed": max(sum(a["pass"].values()) for a in abl),
            "of_tests": len(abl[0]["pass"]),
        }

    out = {
        "data_hash": doc["data_hash"],
        "counts": doc["counts"],
        "unassigned": [c["id"] for c in doc["cells"] if c["class"] == "unassigned"],
        "probe": probe,
        "course": {
            "light_100": {"x": trace[99][0], "y": trace[99][1], "heading": trace[99][2], "yolk": trace[99][4]},
            "hash": body_a["hash"].hex(),
            "shadow_escape_thrust": shadow_thrust,
            "shadow_displacement": shadow_d,
            "control_displacement": control_d,
            "tilt_after_80": tilt_trace[-1][3],
        },
        "phase0_acceptance": phase0,
        "constants": CONST,
    }
    (RES / "phase0_behavior.json").write_text(json.dumps(out, indent=1) + "\n")
    print("course ok", out["course"])


if __name__ == "__main__":
    main()
