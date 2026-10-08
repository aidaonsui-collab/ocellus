# bench/: on-chain brain gas benchmark

This is a prototype, unoptimized Move implementation of the fixed-point leaky integrate-and-fire model from [DESIGN.md §3](../DESIGN.md#3-the-brain). It runs over the real *Ciona* larval connectome: 237 matrix labels, 3,010 chemical neuron→neuron entries, 866 directed gap-junction entries, 28 inhibitory cells and 25 sensory inputs. It is a **benchmark only, not production code.**

> **All numbers here come from a local, throwaway Sui test network (localnet),** at localnet's reference gas price (1,000 MIST per computation unit), using Sui CLI 1.80.1. Mainnet gas prices and protocol versions differ. Re-measure on testnet or mainnet before relying on any figure.

## Layout

| Path | What it is |
|---|---|
| `sources/brain.move` | LIF model: `Connectome` (CSR wiring), `Brain` (membrane state), `step()`, plus `create` / `create_frozen` / `noop` entry points |
| `tests/bench_tests.move` | Unit tests with the full graph embedded (generated) |
| `graph_csr.json` | CSR arrays fed to the localnet run (generated) |
| `scripts/build_graph.py` | eLife Figure 16 spreadsheets (`../research/`) → `../research/graph.json`, `matrix_stats.json` |
| `scripts/gen_bench.py` | `graph.json` → `graph_csr.json` + `tests/bench_tests.move` (sets the inhibitory cells and sensory inputs) |
| `scripts/run_localnet.py` | Spins up an isolated localnet, publishes, measures `step()` gas, writes `results/run-*.json`, then tears everything down |
| `results/` | Raw `gasUsed` from our runs (see below) |

## Rerun

Prerequisites: the [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install) (tested with 1.80.1), Python 3, and `pip install openpyxl`.

```sh
# from the repo root
python3 bench/scripts/build_graph.py            # regenerate research/graph.json from the eLife xlsx
python3 bench/scripts/gen_bench.py              # regenerate graph_csr.json + tests
(cd bench && sui move test)                     # unit tests (logic check; unit-test gas is not representative)
SUI_BIN=$(which sui) python3 bench/scripts/run_localnet.py   # real gas on a throwaway localnet
```

`run_localnet.py` creates its genesis, keystore and client config in a temporary directory and deletes them afterwards. It never touches `~/.sui`. Ports default to 19000 (RPC) and 19123 (faucet); you can override them with `RPC_PORT` and `FAUCET_PORT`.

## Results so far (localnet, computation units)

| Transaction | Units |
|---|---|
| No-op (same objects) | 1,000 (minimum bucket) |
| 1 tick, typical activity | 1,450 – 2,610 |
| 1 tick, every cell spiking | 12,500 – 12,600 |
| 2 ticks, typical | 12,600 – 21,100 |
| 5 ticks, typical | 207,700 – 210,100 |
| 50 ticks, typical | 3,076,000 |
| 100 ticks | fails with `InsufficientGas` (50 SUI budget cap) |

The cost grows superlinearly because Sui prices instructions in tiers (see `initial_cost_schedule_v5` in [`gas_model/tables.rs`](https://github.com/MystenLabs/sui/blob/main/crates/sui-types/src/gas_model/tables.rs)). That's why the design uses one tick per transaction.

Result files:
- `results/2026-10-07-owned-connectome.json`: first exploratory run with an owned (not frozen) connectome, including the 10/50/100-tick runs. The owned connectome gets rewritten on every transaction, which costs about 110 M MIST in storage, mostly rebated.
- `results/2026-10-07-frozen-connectome.json`: the same model with a frozen connectome (the production shape).
- `results/run-*.json`: full reruns made with `scripts/run_localnet.py`.

Activity varies from tick to tick because the brain state carries over between calls, so the "typical" figures are ranges.

## Data

The wiring comes from Ryan, Lu & Meinertzhagen (2016), *eLife* 5:e16962, licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The weights are contact depth ÷ 0.06 µm, so each one counts 60-nm sections. Cell labels are **not yet reconciled** between the two matrices, so treat this graph as benchmark-grade, not the canonical connectome.
