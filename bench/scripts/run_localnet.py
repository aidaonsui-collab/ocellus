#!/usr/bin/env python3
"""Reproduce the gas benchmark on a throwaway, isolated Sui localnet.

  SUI_BIN=/path/to/sui python3 bench/scripts/run_localnet.py

- Creates a fresh genesis in a temp dir (its own keystore; never touches ~/.sui),
  starts `sui start` on local ports, publishes this package with `test-publish`,
  creates the Connectome (frozen and owned variants) + Brain, runs step() at
  several tick counts, writes bench/results/run-<timestamp>.json, then stops
  the node and deletes the temp dir.
- Numbers are LOCAL TEST NETWORK numbers (localnet reference gas price, usually
  1,000 MIST/unit). Re-measure on testnet/mainnet before relying on them.
"""
import json, os, shutil, subprocess, sys, tempfile, time, urllib.request
from datetime import datetime
from pathlib import Path

SUI = os.environ.get("SUI_BIN", "sui")
BENCH = Path(__file__).resolve().parents[1]
RPC_PORT = int(os.environ.get("RPC_PORT", "19000"))
FAUCET_PORT = int(os.environ.get("FAUCET_PORT", "19123"))
G = json.load(open(BENCH / "graph_csr.json"))
V = lambda xs: "[" + ",".join(str(x).lower() for x in xs) + "]"


def rpc(method, params=None):
    req = urllib.request.Request(f"http://127.0.0.1:{RPC_PORT}", method="POST",
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode(),
        headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=5))["result"]


def main():
    work = Path(tempfile.mkdtemp(prefix="ocellus-localnet-"))
    node = None
    try:
        subprocess.run([SUI, "genesis", "--working-dir", str(work), "--with-faucet"], check=True, capture_output=True)
        node = subprocess.Popen([SUI, "start", "--network.config", str(work), f"--with-faucet=127.0.0.1:{FAUCET_PORT}",
                                 "--fullnode-rpc-port", str(RPC_PORT)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(60):
            try:
                rgp = rpc("suix_getReferenceGasPrice"); break
            except Exception:
                time.sleep(2)
        else:
            raise RuntimeError("localnet did not come up")
        cli = [SUI, "client", "--client.config", str(work / "client.yaml")]

        def run(args, budget="50000000000"):
            r = subprocess.run(cli + args + ["--gas-budget", budget, "--json"], capture_output=True, text=True, cwd=BENCH)
            if r.returncode:
                return {"error": (r.stderr + r.stdout).strip()[-300:]}
            return json.loads(r.stdout)

        pub = run(["test-publish", "--build-env", "testnet", "--pubfile-path", str(work / "Pub.localnet.toml")], "2000000000")
        pkg = next(o["packageId"] for o in pub["objectChanges"] if o["type"] == "published")
        args = [str(G["n"]), V(G["ptr"]), V(G["col"]), V(G["w"]), V(G["inhib"]), V(G["gptr"]), V(G["gcol"]), V(G["gc"])]  # gc: model v1 gap coefficients
        sens, drive = V(G["sens"]), V([20000] * len(G["sens"]))
        out = {"date": datetime.now().isoformat(timespec="seconds"), "sui_version": subprocess.run([SUI, "--version"], capture_output=True, text=True).stdout.strip(),
               "reference_gas_price": rgp, "graph": {k: G[k] for k in ("n",)} | {"chem_edges": len(G["col"]), "gap_directed": len(G["gcol"])}, "variants": {}}
        for variant, fn in (("frozen_connectome", "create_frozen"), ("owned_connectome", "create")):
            cr = run(["call", "--package", pkg, "--module", "brain", "--function", fn, "--args", *args], "5000000000")
            ids = {o["objectType"].split("::")[-1]: o["objectId"] for o in cr["objectChanges"] if o["type"] == "created"}
            rows = [{"call": "create", "gasUsed": cr["effects"]["gasUsed"]}]
            noop = run(["call", "--package", pkg, "--module", "brain", "--function", "noop", "--args", ids["Connectome"], ids["Brain"]])
            rows.append({"call": "noop", "gasUsed": noop.get("effects", {}).get("gasUsed", noop)})
            for ticks, force_all in [(1, False)] * 3 + [(2, False), (5, False), (1, True), (2, True)]:
                r = run(["call", "--package", pkg, "--module", "brain", "--function", "step", "--args",
                         ids["Connectome"], ids["Brain"], sens, drive, str(ticks), str(force_all).lower()])
                gu = r.get("effects", {}).get("gasUsed", r)
                rows.append({"call": "step", "ticks": ticks, "force_all_spiking": force_all, "gasUsed": gu})
                cu = int(gu["computationCost"]) // int(rgp) if "computationCost" in gu else gu
                print(f"{variant:18} ticks={ticks} all_spiking={force_all!s:5} computation_units={cu}")
            out["variants"][variant] = rows
        dest = BENCH / "results" / f"run-{datetime.now():%Y%m%d-%H%M%S}.json"
        json.dump(out, open(dest, "w"), indent=1)
        print("wrote", dest.relative_to(BENCH.parent))
    finally:
        if node:
            node.terminate(); node.wait(timeout=30)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
