# Ocellus

**A reef of sea-squirt tadpoles whose real, fully mapped 177-neuron brains run entirely on Sui.**

Each creature is a larva of the sea squirt *Ciona intestinalis*. It runs a copy of the published larval connectome, with every neuron updated on every tick inside Move, so anyone can replay its behavior. Larvae swim using their real light (ocellus) and gravity (otolith) sensors. They race toward light and compete for spots on a shared reef, then settle and metamorphose into adults. Adults spawn the next generation, and their genes are mixed with Sui's on-chain randomness.

The game works with any standard Sui coin and never needs minting rights, so it fits whichever launchpad the coin launches on.

## Status

**Design stage.** No contracts have been deployed yet. Read the full design in **[DESIGN.md](./DESIGN.md)**, which covers the brain model, gas benchmarks, creature objects, genetics, lifecycle, reef world, token integration, verification, trading, roadmap and risks.

## Data credit and license note

The brain wiring comes from:

> Ryan K, Lu Z, Meinertzhagen IA (2016). *The CNS connectome of a tadpole larva of* Ciona intestinalis *(L.) highlights sidedness in the brain of a chordate sibling.* **eLife** 5:e16962. https://elifesciences.org/articles/16962

That article and its source data are distributed under the [Creative Commons Attribution 4.0 (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/) license. Ocellus uses the connectome with attribution. Any derived data files we publish (cell-label reconciliation, weights, excitatory/inhibitory sign table) will document every change from the original matrices.

Neurotransmitter and sign assignments draw on Kourakis et al. 2019 (eLife 8:e44753) and Bostwick et al. 2020 (Curr Biol 30:600–609). This project contains no code or data from oBrain/Flybook.

No license has been chosen yet for this repository's own code and documents.
