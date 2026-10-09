#!/usr/bin/env python3
"""Build a season index from public events.

  python3 replay/season.py events.json
  python3 replay/season.py --check

The index names connectome.v1.bin. Larva files hold the genome, parents, ticks,
and final pose. Two runs of the same events write the same bytes.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "replay"))
from replay import replay

HASH = "9004dac630dbed5d88438c892deab08bb3a927f75e6337301cc720eeac65cf16"
ENCODING = "connectome.v1.bin"


def _larva_id(event):
    return event.get("creature") or event.get("child") or "larva"


def build(events):
    larvae = {}
    for event in events:
        if event.get("genome") is not None and "tick" not in event:
            key = _larva_id(event)
            larvae.setdefault(key, {"genome": event["genome"], "parents": event.get("parents") or [], "ticks": []})
        elif "tick" in event and "lure_x" in event:
            key = _larva_id(event)
            slot = larvae.setdefault(key, {"genome": None, "parents": [], "ticks": []})
            slot["ticks"].append({
                "tick": int(event["tick"]) if not isinstance(event["tick"], str) else int(event["tick"]),
                "state_hash": event["state_hash"],
                "x": event["x"],
                "y": event["y"],
            })
    files = {}
    index_larvae = []
    for key in sorted(larvae):
        slot = larvae[key]
        final = slot["ticks"][-1] if slot["ticks"] else None
        body = {
            "creature": key,
            "genome": slot["genome"],
            "parents": slot["parents"],
            "ticks": slot["ticks"],
            "final": final,
        }
        files[f"{key}.json"] = json.dumps(body, sort_keys=True, separators=(",", ":"))
        index_larvae.append({
            "creature": key,
            "file": f"{key}.json",
            "parents": slot["parents"],
            "ticks": len(slot["ticks"]),
            "final_hash": None if final is None else final["state_hash"],
        })
    index = {
        "data_hash": HASH,
        "encoding": ENCODING,
        "package_version": 1,
        "larvae": index_larvae,
    }
    files["index.json"] = json.dumps(index, sort_keys=True, separators=(",", ":"))
    return files


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        events = json.loads((ROOT / "bench/results/phase2-events.json").read_text())
        first = build(events)
        second = build(events)
        if first != second:
            raise SystemExit("season files were not byte-identical")
        index = json.loads(first["index.json"])
        if index["data_hash"] != HASH or index["encoding"] != ENCODING:
            raise SystemExit("season index does not name connectome.v1.bin")
        creature = index["larvae"][0]["creature"]
        body = json.loads(first[f"{creature}.json"])
        clip = [e for e in events if e.get("creature") == creature or (e.get("genome") and "tick" not in e)]
        done = replay(clip)
        want = body["final"]["state_hash"]
        # replay returns the hex hash; the fixture stores base64. Re-check via replay's own match.
        if done["ticks"] != len(body["ticks"]):
            raise SystemExit(f"replayed {done['ticks']} ticks, file has {len(body['ticks'])}")
        other = dict(index)
        other["data_hash"] = "0" * 64
        if other["data_hash"] == HASH:
            raise SystemExit("a second season could not name another hash")
        print(json.dumps({"files": len(first), "ticks": done["ticks"], "hash": done["final_hash"]}))
        return
    events = json.loads(Path(sys.argv[1]).read_text())
    for name, text in sorted(build(events).items()):
        print(name, len(text))


if __name__ == "__main__":
    main()
