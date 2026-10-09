# Ocellus

**A reef of sea-squirt tadpoles whose real, fully mapped 177-neuron brains run entirely on Sui.**

Each creature is a larva of the sea squirt *Ciona intestinalis*. It runs a copy of the published larval connectome, with every neuron updated on every tick inside Move, so anyone can replay its behavior. Larvae swim using their real light (ocellus) and gravity (otolith) sensors. They race toward light and compete for spots on a shared reef, then settle and metamorphose into adults. Adults spawn the next generation, and their genes are mixed with Sui's on-chain randomness.

The game works with any standard Sui coin and never needs minting rights, so it fits whichever launchpad the coin launches on.

## What it's for

Ocellus runs a real animal's complete mapped nervous system in public. The wiring is the *Ciona* larva connectome from Ryan et al. 2016 (CC BY). Every neuron updates on every step inside Move, so anyone can reproduce a larva's behavior from its chain events, using [`replay/`](./replay) or the verifier page ([`client/index.html`](./client/index.html)).

**What can be learned.** Genomes change each neuron's excitability, never its wiring. That makes it possible to ask how those differences change swimming, light response and where a larva settles, and once breeding exists, how a population drifts under selection. The published season datasets ([phase 7](./docs/BRAIN_MODES_PLAN.md#phase-7-lineage-and-population-dataset-seasons)) are meant to make that open data. They are blocked until anyone can check the connectome's hash rather than trusting the publisher's value.

**Limits.** The neuron model is a simplified integer one. Most cells are excitatory only by default, because no source gives their transmitter. Dimming and gravity don't yet drive the motor neurons ([phase 0](./docs/BRAIN_MODES_PLAN.md#phase-0-brain-pathways-dimming-and-gravity-reach-the-motor-neurons)). It is not a substitute for wet-lab science. It is a public, checkable model.

**Who it's for:** players, people curious about how a small brain works, students, and researchers who want an open toy model they can check line by line.

## Status

**Contracts written and tested locally; nothing deployed.** `contracts/brain`, `contracts/game` and `contracts/sink` build and pass `sui move test`. `client/src/engine.js` is the integer mirror that both the verifier (`client/index.html`) and the demo (`client/demo/`) run, and `replay/replay.py` checks the same events in Python. The gas figures in `bench/` come from a throwaway local network only. No package has been published to Sui mainnet or testnet.

Read the full design in **[DESIGN.md](./DESIGN.md)** and the plan for the game modes in **[docs/BRAIN_MODES_PLAN.md](./docs/BRAIN_MODES_PLAN.md)**.

## Repository layout

| Path | Contents |
|---|---|
| [`DESIGN.md`](./DESIGN.md) | Full design document |
| [`client/demo/`](./client/demo/README.md) | WebGL demo of the lifecycle (hatch, light-gate race, settlement, metamorphosis), served at `/demo/` by the Vite client. Every tick runs the chain's integer engine (`client/src/engine.js`) over the reconciled 224-cell connectome, and the page replays recorded chain events to check it. Nothing in it is on-chain. |
| [`bench/`](./bench/README.md) | Prototype Move gas benchmark of the on-chain brain (real connectome), scripts to reproduce it, and raw results. **Numbers are from a local Sui test network.** |
| [`research/`](./research/SOURCES.md) | CC BY source data from Ryan et al. 2016 (connectome matrices, cell key, full text), the derived edge list, and `SOURCES.md` listing every cited source, including ones that aren't redistributed here |
| [`contracts/`](./contracts) | The Move packages: `brain`, `game` (`ciona`, `race`, `reef`, `market`, `rules`) and `sink`, plus their tests |
| [`client/`](./client/src/engine.js) | The shared integer engine, the verifier page and the WebGL demo |
| [`replay/`](./replay) | The Python replay checker |
| [`docs/`](./docs/BRAIN_MODES_PLAN.md) | Implementation plans. The brain-modes plan sequences the modes the brain actually drives, starting with the pathway work that makes dimming and gravity real neural behavior |

## Data credit and license note

The brain wiring comes from:

> Ryan K, Lu Z, Meinertzhagen IA (2016). *The CNS connectome of a tadpole larva of* Ciona intestinalis *(L.) highlights sidedness in the brain of a chordate sibling.* **eLife** 5:e16962. https://elifesciences.org/articles/16962

That article and its source data are distributed under the [Creative Commons Attribution 4.0 (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/) license. Ocellus uses the connectome with attribution. Any derived data files we publish (cell-label reconciliation, weights, excitatory/inhibitory sign table) will document every change from the original matrices.

Neurotransmitter and sign assignments draw on Kourakis et al. 2019 (eLife 8:e44753) and Bostwick et al. 2020 (Curr Biol 30:600–609). This project contains no code or data from oBrain/Flybook.

No license has been chosen yet for this repository's own code and documents.
