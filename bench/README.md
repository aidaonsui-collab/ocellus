# bench/: on-chain brain gas benchmark

This is a prototype, unoptimized Move implementation of the fixed-point leaky integrate-and-fire model from [DESIGN.md §3](../DESIGN.md#3-the-brain). It runs over the real *Ciona* larval connectome: 237 matrix labels, 3,010 chemical neuron→neuron entries, 866 directed gap-junction entries, 28 inhibitory cells and 25 sensory inputs. It is a **benchmark only, not production code.** The current code is **model v1**; see [Model v1](#model-v1-motor-output-that-tracks-input) for what changed from the first version (v0) and why.

> **All numbers here come from a local, throwaway Sui test network (localnet),** at localnet's reference gas price (1,000 MIST per computation unit), using Sui CLI 1.80.1. Mainnet gas prices and protocol versions differ. Re-measure on testnet or mainnet before relying on any figure.

## Layout

| Path | What it is |
|---|---|
| `sources/brain.move` | LIF model: `Connectome` (CSR wiring), `Brain` (membrane and adaptation state), `step()`, plus `create` / `create_frozen` / `noop` entry points |
| `tests/bench_tests.move` | Unit tests with the full graph embedded (generated). They assert spike totals from the Python reference, so they check Move against `lif_model.py` exactly |
| `graph_csr.json` | CSR arrays fed to the localnet run (generated). `gw` holds the raw gap weights, `gc` the v1 coupling coefficients the Move code uses |
| `scripts/lif_model.py` | Exact integer Python reference of `step()`, for both v0 and v1 parameters |
| `scripts/probe_dynamics.py` | Behavioural probe (DESIGN §9.3): light then dark, drive sweep, pulsed light, dimming, antenna only, seizure recovery, activity census, on the bench graph. On the reconciled graph it also runs the phase 0 acceptance tests, a 3-hop pathway trace and the ablations (`docs/BRAIN_MODES_PLAN.md`). Writes `results/dynamics.json`, and exits non-zero while the shipped graph fails phase 0 |
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
python3 bench/scripts/probe_dynamics.py         # behaviour of v0 vs v1 (seconds; no Sui needed)
(cd bench && sui move test)                     # unit tests (Move == Python reference; unit-test gas is not representative)
SUI_BIN=$(which sui) python3 bench/scripts/run_localnet.py   # real gas on a throwaway localnet
```

`run_localnet.py` creates its genesis, keystore and client config in a temporary directory and deletes them afterwards. It never touches `~/.sui`. Ports default to 19000 (RPC) and 19123 (faucet); you can override them with `RPC_PORT` and `FAUCET_PORT`.

## Results so far (localnet, computation units)

| Transaction | v0 | v1 (current) |
|---|---|---|
| No-op (same objects) | 1,000 (minimum bucket) | 1,000 |
| 1 tick, typical activity | 1,450 – 2,610 | 1,640 – 3,200 |
| 1 tick, every cell spiking | 12,500 – 12,600 | 20,100 |
| 2 ticks, typical | 12,600 – 21,100 | 23,500 |
| 5 ticks, typical | 207,700 – 210,100 | 209,100 |
| 2 ticks, every cell spiking | 134,300 | 149,000 |
| 50 ticks, typical | 3,076,000 | not re-measured |
| 100 ticks | fails with `InsufficientGas` (50 SUI budget cap) | not re-measured |
| Brain write, storage (frozen connectome) | 11.4 M MIST, 0.114 M non-refundable | 18.6 M MIST, 0.186 M non-refundable |

v0 numbers are from Sui CLI 1.79.1 and 1.80.1; v1 from 1.80.1 (`results/run-20261007-221855.json`). Every step in these runs drives all 25 sensors at 20,000, so "typical" here is a busy network. The storage increase is the new `adapt` vector (237 × u32); storing it as `u16` would cut about half of that.

The cost grows superlinearly because Sui prices instructions in tiers (see `initial_cost_schedule_v5` in [`gas_model/tables.rs`](https://github.com/MystenLabs/sui/blob/main/crates/sui-types/src/gas_model/tables.rs)). That's why the design uses one tick per transaction.

Result files:
- `results/2026-10-07-owned-connectome.json`: first exploratory run with an owned (not frozen) connectome, including the 10/50/100-tick runs. The owned connectome gets rewritten on every transaction, which costs about 110 M MIST in storage, mostly rebated.
- `results/2026-10-07-frozen-connectome.json`: the same model with a frozen connectome (the production shape).
- `results/run-*.json`: full reruns made with `scripts/run_localnet.py`. `run-20261007-201251.json` is v0, `run-20261007-221855.json` is v1.
- `results/dynamics.json`: behavioural probe output for v0 and v1 (`scripts/probe_dynamics.py`).

Activity varies from tick to tick because the brain state carries over between calls, so the "typical" figures are ranges.

## Model v1: motor output that tracks input

**What was wrong with v0.** About 5 to 8 ticks after light first reached PR-I, the motor ganglion locked into a period-2 loop. MN1L, MN2R and MN4L alternated with MN1R, MN2L and MN4R, and MN5R joined later. The loop kept firing with zero input and gave the same motor output at every drive level. It had two numerical causes:

1. **Unstable gap coupling.** Each tick, a gap junction moves `gw/64` of the voltage difference. Summed over a cell's partners, that fraction exceeds 1 for 37 cells (MN2R: 14.5, MN2L: 13.6). The explicit update then overshoots and flips sign every tick.
2. **No floor on inhibition.** During the loop, 82–87 cells sat more than 100,000 units below rest, and 12–17 of them were pinned at `v = 0`, 2²⁰ below rest. For comparison, the threshold is 16,384 above rest. A gap junction touching a cell at 0 carries about 16,384 × `gw` per tick.

Making the coupling stable without changing anything else silenced the motor neurons at every drive level. All of v0's motor activity came from the instability. `W_SCALE = 64` is too weak to carry a signal from PR-I to the motor ganglion.

**What v1 changes.** Everything stays integer-only. `sources/brain.move` and `scripts/lif_model.py` implement it identically, and the unit tests check that.

| | v0 | v1 |
|---|---|---|
| Gap current | `(Δv >> 6) × gw` | `(Δv × gc) >> 12`, with `gc = gw × 2048 / max(32, Σg_i, Σg_j)`. Each cell's total coupling is at most 0.5 per tick; weakly coupled cells keep their v0 strength |
| Membrane range | 0 to unbounded | rest − 16,384 (inhibitory reversal) to rest + 65,536 (keeps gap products inside u32) |
| Spike-frequency adaptation | none | threshold + `a`; `a` += 8,192 per spike and decays by 1/16 per tick |
| Synaptic gain `W_SCALE` | 64 | 320 |
| Leak, threshold, reset | 1/8 per tick, rest + 16,384, rest − 4,096 | unchanged |
| Brain state | `v`, `spiked` | `v`, `adapt`, `spiked` |

Parameters came from a grid search over gain, leak, adaptation strength and decay, and an optional refractory period. The criteria were: no spikes without input, silence after the light goes off, seizures that die out, a drive response that rises steadily, and the largest share of ticks with motor output. A refractory counter didn't improve anything, so v1 doesn't have one.

**Behaviour** (`scripts/probe_dynamics.py`; PR-I drive jittered per cell; statistics over 400 ticks of steady light):

| Probe | v0 | v1 |
|---|---|---|
| Motor output vs PR-I drive 0 / 2,500 / 6,000 / 10,000 / 20,000 | 0 / 3,497 / 3,497 / 3,497 / 3,497 | 0 / 164 / 617 / 1,165 / 1,377 |
| Swim bouts per 400 ticks, same drives | 0 / 1 / 1 / 1 / 1 (one bout that never ends) | 0 / 1 / 4 / 7 / 10 |
| Rank correlation of motor output with drive | 0.55 | 0.996 |
| Motor output after the light goes off | unchanged (3,497) | 0, silent within 0–16 ticks depending on bout phase |
| Pulsed light, 15 on / 15 off: motor output during on vs off phases | 3,511 vs 3,482 | 1,207 vs 748 |
| Every cell spiking at once, no input | never stops (800 spikes in the last 50 ticks) | silent after 12 ticks |
| No input from rest | silent | silent |
| Cells that fire at least once (PR-I + antenna drive) | 54 / 237 | 113 / 237 |
| Dimming step (PR-II drive) | 3,497 (the loop) | 0 |
| Antenna cells only | 3,497 (the loop) | 0 |

**Still open (DESIGN §9.3):**

- **Bouts, not continuous swimming.** Steady light gives swim bouts of about 15 ticks separated by quiet spells, and brighter light makes bouts more frequent. Real larvae do swim episodically, but bout timing isn't fitted to any data.
- **Dimming and gravity don't reach the motor neurons.** Neither PR-II drive nor antenna drive produces motor output, so the dimming-response and gravity-gating tests fail. Phase 0 of `docs/BRAIN_MODES_PLAN.md` tested the sign-table explanation on the reconciled graph: 89 one-at-a-time sign flips, tonic drives and leak or adaptation changes, and none produces a PR-II-driven swim (`results/dynamics.json`, `phase0`).
- **Storage.** The `adapt` vector raised the storage cost of each brain write by about 7.2 M MIST, 99% rebated. Packing it as `u16` would reduce this.

## Data

The wiring comes from Ryan, Lu & Meinertzhagen (2016), *eLife* 5:e16962, licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The weights are contact depth ÷ 0.06 µm, so each one counts 60-nm sections. Cell labels are **not yet reconciled** between the two matrices, so treat this graph as benchmark-grade, not the canonical connectome.
