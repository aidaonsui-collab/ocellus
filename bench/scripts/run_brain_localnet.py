#!/usr/bin/env python3
"""Gas-measure ocellus_brain on a throwaway localnet.

Publishes contracts/brain, freezes the connectome, runs baseline swim ticks
and one all-spiking tick. Writes bench/results/brain-localnet.json.
Numbers are localnet numbers. The node and keystore live in a temp dir.
"""
import json, os, shutil, subprocess, sys, tempfile, time, urllib.request
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dynamics import load_connectome
from lif_model import gap_coefficients

SUI = os.environ.get("SUI_BIN", "sui")
ROOT = Path(__file__).resolve().parents[2]
PKG = ROOT / "contracts" / "brain"
RPC_PORT = int(os.environ.get("RPC_PORT", "19020"))
FAUCET_PORT = int(os.environ.get("FAUCET_PORT", "19143"))


def vec(xs):
    return "[" + ",".join(str(x).lower() for x in xs) + "]"


def rpc(method, params=None):
    req = urllib.request.Request(
        f"http://127.0.0.1:{RPC_PORT}", method="POST",
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode(),
        headers={"Content-Type": "application/json"},
    )
    return json.load(urllib.request.urlopen(req, timeout=5))["result"]


def units(gas, price):
    if not isinstance(gas, dict) or "computationCost" not in gas:
        return None
    return int(gas["computationCost"]) // int(price)


def mutated_ids(effects):
    out = []
    for item in effects.get("mutated") or []:
        if isinstance(item, str):
            out.append(item)
        elif isinstance(item, dict):
            ref = item.get("reference") or item
            if "objectId" in ref:
                out.append(ref["objectId"])
    return out


def main():
    view = load_connectome()
    g = view["graph"]
    doc = view["doc"]
    gc = gap_coefficients(g)
    groups = []
    group_of = {
        "PR-I": 0, "PR-II": 1, "Ant": 2, "PR-III": 3, "Cor": 4,
        "prRN": 5, "pr-AMG RN": 5, "pr-BTN RN": 5, "pr-cor RN": 5,
        "ant1 RN": 5, "ant2 RN": 5, "ant1/2 RN": 5, "ant-cor RN": 5,
        "2 RN": 5, "PN RN": 5, "Em": 5, "MGIN": 6, "MN": 7, "ACIN": 8, "AMG": 9,
        "BTN": 10, "pATEN": 10, "aATEN": 10, "RTEN-a": 10, "RTEN-b": 10, "DCEN": 10,
        "vacIN": 11, "trIN": 11, "aaIN": 12, "cor-ass BVIN": 12, "cil-BVIN": 12,
        "BVIN": 12, "PNIN": 12, "PBV PNIN": 12, "BPIN": 12, "prIN": 12, "antIN": 12,
        "ambiguous": 12, "Neck": 13, "ddN": 13, "PMGN": 13, "MTN": 14,
    }
    for c in doc["cells"]:
        groups.append(15 if c["class"] == "unassigned" else group_of[c["class"]])
    digest = [int(doc["data_hash"][i:i + 2], 16) for i in range(0, 64, 2)]
    inhib = ["true" if b else "false" for b in g["inhib"]]
    create_args = [
        str(g["n"]),
        vec(g["ptr"]), vec(g["col"]), vec(g["w"]), vec(inhib),
        vec(g["gptr"]), vec(g["gcol"]), vec(gc),
        vec(view["nmj_l"]), vec(view["nmj_r"]), vec(groups), vec(digest),
    ]

    work = Path(tempfile.mkdtemp(prefix="ocellus-brain-"))
    node = None
    try:
        subprocess.run([SUI, "genesis", "--working-dir", str(work), "--with-faucet"], check=True, capture_output=True)
        node = subprocess.Popen(
            [SUI, "start", "--network.config", str(work), f"--with-faucet=127.0.0.1:{FAUCET_PORT}",
             "--fullnode-rpc-port", str(RPC_PORT)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        for _ in range(60):
            try:
                price = int(rpc("suix_getReferenceGasPrice"))
                break
            except Exception:
                time.sleep(2)
        else:
            raise SystemExit("localnet did not come up")
        cli = [SUI, "client", "--client.config", str(work / "client.yaml")]

        def run(args, budget="10000000000"):
            r = subprocess.run(cli + args + ["--gas-budget", budget, "--json"], capture_output=True, text=True, cwd=PKG)
            if r.returncode:
                tail = (r.stderr + r.stdout).strip()[-800:]
                raise SystemExit(tail)
            return json.loads(r.stdout)

        pub = run(["test-publish", "--build-env", "testnet", "--pubfile-path", str(work / "Pub.localnet.toml")], "3000000000")
        changes = pub["objectChanges"]
        pkg = next(o["packageId"] for o in changes if o["type"] == "published")
        cap = next(o["objectId"] for o in changes if o["type"] == "created" and o["objectType"].endswith("PublisherCap"))
        created = run(["call", "--package", pkg, "--module", "brain", "--function", "create_frozen",
                       "--args", cap, *create_args], "10000000000")
        ids = {}
        for o in created["objectChanges"]:
            if o["type"] in ("created", "published"):
                ids[o.get("objectType", "").split("::")[-1]] = o.get("objectId")
        # freeze shows up as a mutated or frozen change, not created
        conn = None
        larva = None
        for o in created["objectChanges"]:
            t = o.get("objectType", "")
            if t.endswith("::Connectome"):
                conn = o["objectId"]
            if t.endswith("::Larva"):
                larva = o["objectId"]
        if not conn or not larva:
            raise SystemExit("missing objects: " + json.dumps(created["objectChanges"])[:800])

        rows = []
        for i in range(8):
            r = run(["call", "--package", pkg, "--module", "brain", "--function", "tick_baseline",
                     "--args", conn, larva, "1500", "0", "256", "false", "false"])
            gu = r["effects"]["gasUsed"]
            rows.append({"call": "tick_baseline", "i": i, "units": units(gu, price), "gasUsed": gu,
                         "connectome_mutated": conn in mutated_ids(r["effects"])})
            print(f"tick {i} units={rows[-1]['units']} connectome_mutated={rows[-1]['connectome_mutated']}")
        r = run(["call", "--package", pkg, "--module", "brain", "--function", "measure_seizure",
                 "--args", conn, larva, "1500", "0", "256", "false", "false"])
        gu = r["effects"]["gasUsed"]
        seizure = {"call": "measure_seizure", "units": units(gu, price), "gasUsed": gu,
                   "connectome_mutated": conn in mutated_ids(r["effects"])}
        print(f"seizure units={seizure['units']} connectome_mutated={seizure['connectome_mutated']}")
        busy = max(row["units"] for row in rows[2:])
        out = {
            "date": datetime.now().isoformat(timespec="seconds"),
            "sui": subprocess.run([SUI, "--version"], capture_output=True, text=True).stdout.strip(),
            "reference_gas_price": price,
            "package": pkg,
            "connectome": conn,
            "larva": larva,
            "busy_units_max_after_warmup": busy,
            "seizure_units": seizure["units"],
            "ticks": rows,
            "seizure": seizure,
            "gate": {"busy_under_8000": busy < 8000, "seizure_under_40000": seizure["units"] < 40000,
                     "connectome_not_rewritten": not any(row["connectome_mutated"] for row in rows + [seizure])},
        }
        dest = ROOT / "bench" / "results" / "brain-localnet.json"
        dest.write_text(json.dumps(out, indent=1) + "\n")
        print(json.dumps(out["gate"]))
        print("wrote", dest)
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
