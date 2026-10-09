#!/usr/bin/env python3
"""Hatch a founder on a throwaway localnet, swim 50 ticks, and replay them.

Writes bench/results/phase2-events.json and checks it with replay/replay.py.
"""
import json, os, shutil, subprocess, sys, tempfile, time, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dynamics import load_connectome
from lif_model import gap_coefficients
from genome import GROUP

SUI = os.environ.get("SUI_BIN", "sui")
ROOT = Path(__file__).resolve().parents[2]
GAME = ROOT / "contracts" / "game"
RPC = int(os.environ.get("RPC_PORT", "19030"))
FAUCET = int(os.environ.get("FAUCET_PORT", "19153"))
CLOCK = "0x6"
RANDOM = "0x8"


def vec(xs):
    return "[" + ",".join(str(x).lower() for x in xs) + "]"


def rpc(method, params=None):
    req = urllib.request.Request(
        f"http://127.0.0.1:{RPC}", method="POST",
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode(),
        headers={"Content-Type": "application/json"},
    )
    return json.load(urllib.request.urlopen(req, timeout=8))["result"]


def clock_ms():
    obj = rpc("sui_getObject", [CLOCK, {"showContent": True}])
    return int(obj["data"]["content"]["fields"]["timestamp_ms"])


def events_of(tx):
    out = []
    for ev in tx.get("events") or []:
        name = ev["type"].split("::")[-1]
        parsed = dict(ev.get("parsedJson") or {})
        parsed["kind"] = name
        out.append(parsed)
    return out


def main():
    view = load_connectome()
    g = view["graph"]
    doc = view["doc"]
    gc = gap_coefficients(g)
    groups = [15 if c["class"] == "unassigned" else GROUP[c["class"]] for c in doc["cells"]]
    digest = [int(doc["data_hash"][i:i + 2], 16) for i in range(0, 64, 2)]
    inhib = ["true" if b else "false" for b in g["inhib"]]
    create_args = [
        str(g["n"]), vec(g["ptr"]), vec(g["col"]), vec(g["w"]), vec(inhib),
        vec(g["gptr"]), vec(g["gcol"]), vec(gc),
        vec(view["nmj_l"]), vec(view["nmj_r"]), vec(groups), vec(digest),
    ]
    work = Path(tempfile.mkdtemp(prefix="ocellus-game-"))
    node = None
    try:
        subprocess.run([SUI, "genesis", "--working-dir", str(work), "--with-faucet"], check=True, capture_output=True)
        node = subprocess.Popen(
            [SUI, "start", "--network.config", str(work), f"--with-faucet=127.0.0.1:{FAUCET}",
             "--fullnode-rpc-port", str(RPC)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        for _ in range(60):
            try:
                rpc("suix_getReferenceGasPrice")
                break
            except Exception:
                time.sleep(2)
        else:
            raise SystemExit("localnet did not come up")
        cli = [SUI, "client", "--client.config", str(work / "client.yaml")]

        def run(args, budget="10000000000"):
            r = subprocess.run(
                cli + args + ["--gas-budget", budget, "--json"],
                capture_output=True, text=True, cwd=GAME,
            )
            if r.returncode:
                raise SystemExit((r.stderr + r.stdout).strip()[-1000:])
            return json.loads(r.stdout)

        published = run([
            "test-publish", "--build-env", "testnet", "--with-unpublished-dependencies", "--silence-warnings",
            "--pubfile-path", str(work / "Pub.localnet.toml"),
        ], "8000000000")
        blocks = published if isinstance(published, list) else [published]
        pkgs = {}
        cap = None
        founder = None
        for block in blocks:
            for o in block.get("objectChanges") or []:
                if o.get("type") == "published":
                    pkgs[o.get("packageId")] = o
                kind = str(o.get("objectType", ""))
                if o.get("type") == "created" and kind.endswith("PublisherCap"):
                    cap = o["objectId"]
                if o.get("type") == "created" and kind.endswith("FounderCap"):
                    founder = o["objectId"]
        if not cap:
            raise SystemExit("no PublisherCap in " + json.dumps(blocks)[:600])
        # The brain package is the one that owns PublisherCap.
        brain_pkg = cap and None
        for block in blocks:
            for o in block.get("objectChanges") or []:
                if o.get("type") == "created" and str(o.get("objectType", "")).endswith("PublisherCap"):
                    brain_pkg = o["objectType"].split("::")[0]
        game_pkg = None
        for block in blocks:
            for o in block.get("objectChanges") or []:
                t = str(o.get("objectType", ""))
                if o.get("type") == "published":
                    continue
                if "::ciona::" in t:
                    game_pkg = t.split("::")[0]
        if game_pkg is None:
            # init may not create a game object. The last published package is the game.
            ids = []
            for block in blocks:
                for o in block.get("objectChanges") or []:
                    if o.get("type") == "published":
                        ids.append(o["packageId"])
            game_pkg = ids[-1]
            if brain_pkg is None and len(ids) >= 2:
                brain_pkg = ids[0]
        print("brain", brain_pkg, "game", game_pkg, "cap", cap)
        created = run(["call", "--package", brain_pkg, "--module", "brain", "--function", "create_frozen",
                       "--args", cap, *create_args], "10000000000")
        conn = larva = None
        for o in created["objectChanges"]:
            t = o.get("objectType", "")
            if t.endswith("::Connectome"):
                conn = o["objectId"]
            if t.endswith("::Larva"):
                larva = o["objectId"]
        if not conn:
            raise SystemExit("no connectome: " + json.dumps(created["objectChanges"])[:500])
        print("connectome", conn, "clock", clock_ms())
        if not founder:
            raise SystemExit("no FounderCap; the free hatch is no longer a public entry")
        hatched = run(["call", "--package", game_pkg, "--module", "ciona", "--function", "hatch_founder",
                       "--args", founder, RANDOM, CLOCK, conn])
        events = events_of(hatched)
        ciona = next(o["objectId"] for o in hatched["objectChanges"] if o.get("objectType", "").endswith("::Ciona"))
        print("ciona", ciona, "hatch events", [e["kind"] for e in events])
        last_ms = clock_ms()
        for i in range(50):
            lure_x = 1200 + i * 20
            lure_y = (i % 7) * 30
            for attempt in range(40):
                now = clock_ms()
                if now == last_ms:
                    time.sleep(0.25)
                    continue
                tx = run(["call", "--package", game_pkg, "--module", "ciona", "--function", "swim_tick",
                          "--args", ciona, conn, CLOCK, str(lure_x), str(lure_y), "256",
                          "true" if i == 20 else "false", "false"])
                events.extend(events_of(tx))
                last_ms = now
                if i % 10 == 0:
                    print("tick", i, "clock", now)
                break
            else:
                raise SystemExit(f"clock did not advance before tick {i}")
        dest = ROOT / "bench" / "results" / "phase2-events.json"
        dest.write_text(json.dumps(events, indent=1) + "\n")
        print("events", len(events), "wrote", dest)
        check = subprocess.run([sys.executable, str(ROOT / "replay" / "replay.py"), str(dest)], capture_output=True, text=True)
        print(check.stdout.strip() or check.stderr.strip()[-500:])
        if check.returncode:
            raise SystemExit(check.returncode)
    finally:
        if node:
            node.terminate()
            try:
                node.wait(timeout=20)
            except subprocess.TimeoutExpired:
                node.kill()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
