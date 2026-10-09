#!/usr/bin/env python3
"""Replay a larva from Hatch and Tick events.

  python3 replay/replay.py events.json

events.json is a list of the parsed chain events, Hatch first, then Tick in
order. The script rebuilds the brain from connectome v1 and the emitted
genome, feeds each tick the lure that event recorded, and checks the hash.
"""
import base64, json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bench" / "scripts"))
from dynamics import fresh, load_connectome, step
from genome import decode

DATA_HASH = "9004dac630dbed5d88438c892deab08bb3a927f75e6337301cc720eeac65cf16"


def bytes_of(value):
    if isinstance(value, str):
        if value.startswith("0x"):
            return bytes.fromhex(value[2:])
        try:
            return base64.b64decode(value, validate=True)
        except Exception:
            return bytes.fromhex(value)
    if isinstance(value, list):
        return bytes(int(x) for x in value)
    raise TypeError(f"cannot read bytes from {type(value)}")


def replay(events):
    view = load_connectome()
    if view["doc"]["data_hash"] != DATA_HASH:
        raise SystemExit("connectome.v1.json hash does not match the game constant")
    hatch = next(e for e in events if e.get("kind", "Hatched") in ("Hatched", "hatch") or "genome" in e and "tick" not in e)
    genome = bytes_of(hatch["genome"])
    decoded = decode(genome)
    body, brain = fresh(view)
    body["yolk"] = decoded["yolk0"]
    ticks = [e for e in events if "tick" in e and "lure_x" in e]
    if not ticks:
        raise SystemExit("no Tick events")
    for e in ticks:
        neighbors = int(e.get("neighbors", 0))
        light = int(e["light"]) - neighbors * 16
        if light < 0:
            light = 0
        step(
            body, brain, view,
            (int(e["lure_x"]), int(e["lure_y"])),
            light, bool(e["shadow"]), bool(e["pulse"]),
            decoded,
        )
        got = body["hash"].hex()
        want = bytes_of(e["state_hash"]).hex()
        if got != want or body["x"] + 1_000_000 != int(e["x"]) or brain.tick != int(e["tick"]):
            raise SystemExit(
                f"tick {e['tick']} diverged: hash {got} vs {want}, "
                f"x {body['x']} vs {int(e['x']) - 1000000}, brain tick {brain.tick}"
            )
    return {"ticks": len(ticks), "final_hash": body["hash"].hex(), "x": body["x"], "yolk": body["yolk"]}


def main():
    path = Path(sys.argv[1])
    events = json.loads(path.read_text())
    print(json.dumps(replay(events)))


if __name__ == "__main__":
    main()
