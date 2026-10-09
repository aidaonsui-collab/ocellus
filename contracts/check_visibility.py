#!/usr/bin/env python3
"""Check that game entry points meant for the package only can't be called from outside.

  python3 contracts/check_visibility.py

Builds a throwaway package that depends on ocellus_game and calls each restricted
function from its own module. Each restricted call must fail to compile; the control
module (public reads and the paid entry path) must compile. Needs the Sui CLI.
"""
import os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SUI = os.environ.get("SUI_BIN", "sui")
HEAD = """use ocellus_brain::brain::Connectome;
use ocellus_game::{ciona, gauntlet, market, race, reef, swarm};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::object::ID;
use sui::tx_context::TxContext;
"""
RESTRICTED = {
    "race_enter": "public fun f(r: &mut race::LightRace, id: ID, c: &Clock) { race::enter(r, id, c) }",
    "race_finish": "public fun f(r: &mut race::LightRace, id: ID, c: &Clock) { race::finish(r, id, 0, @0x1, c) }",
    "race_take_winner": "public fun f(r: &mut race::LightRace, c: &Clock): address { let (p, _d) = race::take_winner(r, c); p }",
    "reef_occupy": "public fun f(r: &mut reef::Reef, id: ID) { reef::occupy(r, 0, id, 0) }",
    "reef_attach": "public fun f(r: &mut reef::Reef, id: ID) { reef::attach(r, 0, id) }",
    "reef_release": "public fun f(r: &mut reef::Reef, id: ID): bool { reef::release(r, 0, id) }",
    "ciona_enter_race": "public fun f(a: &mut ciona::Ciona, r: &mut race::LightRace, c: &Clock) { ciona::enter_race(a, r, c) }",
    "ciona_enter_gauntlet": "public fun f(a: &mut ciona::Ciona, g: &mut gauntlet::Gauntlet, c: &Clock) { ciona::enter_gauntlet(a, g, c) }",
    "ciona_swim_current": "public fun f(a: &mut ciona::Ciona, n: &Connectome, c: &Clock) { ciona::swim_current(a, n, c, 0, 0, 0, false, false, 1) }",
    "swarm_join": "public fun f(b: &mut swarm::SwarmBoard, id: ID, c: &Clock, ctx: &TxContext) { swarm::join(b, id, c, ctx) }",
    "swarm_post": "public fun f(b: &mut swarm::SwarmBoard, id: ID, c: &Clock, ctx: &TxContext) { swarm::post(b, id, 0, 0, 0, c, ctx) }",
    "market_pay_entry": "public fun f<T>(g: &mut market::Game<T>, s: &mut ocellus_sink::sink::Sink<T>, r: &race::LightRace, p: Coin<T>, c: &Clock, ctx: &mut TxContext): Coin<T> { market::pay_entry(g, s, r, p, c, ctx) }",
}
CONTROL = """public fun ok<T>(a: &mut ciona::Ciona, r: &mut race::LightRace, g: &mut market::Game<T>, s: &mut ocellus_sink::sink::Sink<T>, p: Coin<T>, c: &Clock, ctx: &mut TxContext): Coin<T> {
    let _open = race::is_open(r, 0);
    ciona::enter_paid(a, r, g, s, p, c, ctx)
}"""


def build(modules):
    work = Path(tempfile.mkdtemp(prefix="ocellus-visibility-"))
    try:
        (work / "sources").mkdir()
        (work / "Move.toml").write_text(f"""[package]
name = "outsider"
edition = "2024"

[dependencies]
ocellus_brain = {{ local = "{HERE / 'brain'}" }}
ocellus_game = {{ local = "{HERE / 'game'}" }}
ocellus_sink = {{ local = "{HERE / 'sink'}" }}

[addresses]
outsider = "0x0"
""")
        for name, body in modules.items():
            (work / "sources" / f"{name}.move").write_text(f"module outsider::{name};\n{HEAD}\n{body}\n")
        r = subprocess.run([SUI, "move", "build", "--path", str(work)], capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    code, out = build({"control": CONTROL})
    if code != 0:
        print(out[-2000:])
        sys.exit("control module failed to build; the harness is broken")
    failures = []
    for name, body in RESTRICTED.items():
        code, out = build({name: body})
        blocked = code != 0 and re.search(r"(Invalid call|visibility|public\(package\))", out)
        print(f"{'blocked' if blocked else 'ALLOWED':8} {name}")
        if not blocked:
            failures.append(name)
    if failures:
        sys.exit(f"callable from outside the package: {', '.join(failures)}")
    print("all restricted entry points are package-only")


if __name__ == "__main__":
    main()
