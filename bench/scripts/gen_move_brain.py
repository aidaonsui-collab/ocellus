#!/usr/bin/env python3
"""Generate trig.move and the course goldens for contracts/brain.

The numbers come from dynamics.py, so a Move test failure means the package
disagreed with the Python reference.
"""
import json, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dynamics import ATAN, SIN, CONST, fresh, load_connectome, step
from lif_model import gap_coefficients

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "contracts" / "brain"
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


def lit(xs, suf=""):
    return "vector[" + ",".join(f"{x}{suf}" for x in xs) + "]"


def run_sched(view, ticks, lure, light, shadow, tilt=None):
    body, brain = fresh(view)
    if tilt is not None:
        body["tilt"] = tilt
    for _ in range(ticks):
        step(body, brain, view, lure, light, shadow, False)
    return body, brain


def pose(body, brain):
    return {
        "x": body["x"] + 1_000_000,
        "y": body["y"] + 1_000_000,
        "h": body["heading"],
        "tilt": body["tilt"] + 1024,
        "yolk": body["yolk"],
        "spikes": brain.spikes_total,
        "escape": body["escape_thrust_total"],
        "hash": list(body["hash"]),
    }


def main():
    view = load_connectome()
    g = view["graph"]
    doc = view["doc"]
    gc = gap_coefficients(g)
    groups = []
    for c in doc["cells"]:
        if c["class"] not in GROUP and c["class"] != "unassigned":
            raise SystemExit(f"no genome group for {c['class']}")
        groups.append(15 if c["class"] == "unassigned" else GROUP[c["class"]])
    inhib = [1 if b else 0 for b in g["inhib"]]
    cases = {
        "light10": pose(*run_sched(view, 10, (1500, 0), 256, False)),
        # The Move unit-test meter finishes 40 ticks and not 60. The 100-tick
        # course stays in test_course.py. This checkpoint is the same integrator.
        "light40": pose(*run_sched(view, 40, (1500, 0), 256, False)),
        "dark20": pose(*run_sched(view, 20, (1500, 0), 0, False)),
    }
    body, brain = fresh(view)
    for t in range(40):
        step(body, brain, view, (1500, 0), 256, 15 <= t < 30, False)
    cases["shadow40"] = pose(body, brain)
    cases["tilt40"] = pose(*run_sched(view, 40, (1500, 0), 0, False, tilt=300))

    trig = ["module ocellus_brain::trig;", "",
            "public fun sin_at(i: u64): u16 {", "    sin_table()[i]", "}", "",
            "public fun atan_at(i: u64): u16 {", "    atan_table()[i]", "}", "",
            "fun sin_table(): vector<u16> {", f"    {lit(SIN, 'u16')}", "}", "",
            "fun atan_table(): vector<u16> {", f"    {lit(ATAN, 'u16')}", "}", ""]
    (OUT / "sources" / "trig.move").write_text("\n".join(trig) + "\n")

    def case_asserts(name, p, codes):
        h = lit(p["hash"], "u8")
        return f"""
    assert!(brain::x_of(&l) == {p['x']}, {codes});
    assert!(brain::y_of(&l) == {p['y']}, {codes + 1});
    assert!(brain::heading_of(&l) == {p['h']}, {codes + 2});
    assert!(brain::tilt_of(&l) == {p['tilt']}, {codes + 3});
    assert!(brain::yolk_of(&l) == {p['yolk']}, {codes + 4});
    assert!(brain::spikes_total(&l) == {p['spikes']}, {codes + 5});
    assert!(brain::escape_thrust_of(&l) == {p['escape']}, {codes + 6});
    assert!(brain::state_hash_of(&l) == {h}, {codes + 7});
"""

    p10, p40, pd, ps, pt = (cases[k] for k in ("light10", "light40", "dark20", "shadow40", "tilt40"))
    text = f"""#[test_only]
module ocellus_brain::course_tests;
use ocellus_brain::brain;

fun conn(ctx: &mut TxContext): brain::Connectome {{
    brain::new_for_test({g['n']},
        {lit(g['ptr'], 'u16')}, {lit(g['col'], 'u8')}, {lit(g['w'], 'u16')},
        vector[{','.join('true' if b else 'false' for b in g['inhib'])}],
        {lit(g['gptr'], 'u16')}, {lit(g['gcol'], 'u8')}, {lit(gc, 'u16')},
        {lit(view['nmj_l'], 'u16')}, {lit(view['nmj_r'], 'u16')},
        {lit(groups, 'u8')}, {lit(list(bytes.fromhex(doc['data_hash'])), 'u8')}, ctx)
}}

fun larva(c: &brain::Connectome, ctx: &mut TxContext): brain::Larva {{
    let p = brain::baseline_params();
    brain::new_larva(c, &p, ctx)
}}

#[test] fun decode_baseline() {{
    let p = brain::baseline_params();
    assert!(brain::gain_at(&p, 0) == 1000, 1);
    assert!(brain::gain_at(&p, 1) == 1000, 1);
    assert!(brain::gain_at(&p, 2) == 1000, 1);
    assert!(brain::leak_at(&p, 0) == 3, 2);
    assert!(brain::theta_at(&p, 0) == 4096, 3);
    assert!(brain::lr_at(&p, 0) == 100, 4);
    assert!(brain::yolk0_of(&p) == 100000, 5);
    assert!(brain::competence_of(&p) == 1200, 6);
    assert!(brain::isqrt_u64(0) == 0, 7);
    assert!(brain::isqrt_u64(1) == 1, 7);
    assert!(brain::isqrt_u64(2250000) == 1500, 7);
}}

#[test] fun light_10() {{
    let mut ctx = tx_context::dummy();
    let c = conn(&mut ctx);
    let mut l = larva(&c, &mut ctx);
    let p = brain::baseline_params();
    let mut i = 0;
    while (i < 10) {{
        brain::tick(&c, &mut l, &p, 1500, 0, 256, false, false);
        i = i + 1;
    }};
{case_asserts('light10', p10, 10)}
    brain::destroy_for_test(c, l);
}}

#[test] fun light_40() {{
    let mut ctx = tx_context::dummy();
    let c = conn(&mut ctx);
    let mut l = larva(&c, &mut ctx);
    let p = brain::baseline_params();
    let mut i = 0;
    while (i < 40) {{
        brain::tick(&c, &mut l, &p, 1500, 0, 256, false, false);
        i = i + 1;
    }};
{case_asserts('light40', p40, 20)}
    brain::destroy_for_test(c, l);
}}

#[test] fun dark_20() {{
    let mut ctx = tx_context::dummy();
    let c = conn(&mut ctx);
    let mut l = larva(&c, &mut ctx);
    let p = brain::baseline_params();
    let mut i = 0;
    while (i < 20) {{
        brain::tick(&c, &mut l, &p, 1500, 0, 0, false, false);
        i = i + 1;
    }};
{case_asserts('dark20', pd, 30)}
    brain::destroy_for_test(c, l);
}}

#[test] fun shadow_40() {{
    let mut ctx = tx_context::dummy();
    let c = conn(&mut ctx);
    let mut l = larva(&c, &mut ctx);
    let p = brain::baseline_params();
    let mut i = 0;
    while (i < 40) {{
        brain::tick(&c, &mut l, &p, 1500, 0, 256, i >= 15 && i < 30, false);
        i = i + 1;
    }};
{case_asserts('shadow40', ps, 40)}
    brain::destroy_for_test(c, l);
}}

#[test] fun tilt_40() {{
    let mut ctx = tx_context::dummy();
    let c = conn(&mut ctx);
    let mut l = larva(&c, &mut ctx);
    brain::set_tilt(&mut l, 300);
    let p = brain::baseline_params();
    let mut i = 0;
    while (i < 40) {{
        brain::tick(&c, &mut l, &p, 1500, 0, 0, false, false);
        i = i + 1;
    }};
{case_asserts('tilt40', pt, 50)}
    brain::destroy_for_test(c, l);
}}
"""
    # inhib unused variable silence
    _ = inhib
    _ = CONST
    (OUT / "tests" / "course_tests.move").write_text(text)
    (OUT / "tests" / "goldens.json").write_text(json.dumps(cases, indent=1) + "\n")
    print("wrote trig.move and course_tests.move")
    for k, p in cases.items():
        print(f"  {k}: x={p['x'] - 1000000} y={p['y'] - 1000000} spikes={p['spikes']} yolk={p['yolk']}")


if __name__ == "__main__":
    main()
