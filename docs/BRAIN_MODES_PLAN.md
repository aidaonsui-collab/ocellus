# Brain-driven game modes: implementation plan

> The player controls only inputs: light, shadow/dimming, and tilt/gravity. The on-chain brain decides the behavior. Every mode must be replayable from the events the chain already emits.

This plan is grounded in the code on `main` as of 2026-10-07 (`fcb68ab`). It does not replace [DESIGN.md](../DESIGN.md). It sequences the game modes that the brain can actually drive, starting with the pathway work that makes two of them real neural behavior instead of game-layer rules.

Nothing here changes the token design. Every paid action stays generic over `Coin<T>` through `ocellus_game::market`, with the coin type bound once by `bind_shared<T>` and no `TreasuryCap`.

## Where the code stands

| Piece | What it does today |
|---|---|
| `ocellus_brain::brain` | One integer tick: chemical synapses, normalized gap junctions, adaptation, sensor drive, body integration, rolling `blake2b256` state hash. `Connectome` is built by `create_frozen` / `create_and_freeze` and frozen. |
| Sensors | `sensor_drives` feeds 23 PR-I cells from lure position, heading shade and `light` (0–256); both antenna cells from `body.tilt`; 7 PR-II cells from the `shadow` flag only. |
| Body | `integrate` turns toward the lure while PR-I fires (`PR1_TURN`), yaws from left/right NMJ-weighted motor output, and steps `tilt` when exactly one antenna cell fires. An escape swim is a body counter: if PR-II spikes sum to ≥ 3 over 6 ticks, the body adds `ESCAPE_THRUST` (250) for 8 ticks. |
| `ocellus_game::ciona` | `hatch_founder` (free), `swim` / `swim_tick` (player lure), `race_tick` (lure and shadow from `brain::race_lure` / `race_shadow`), `claim`, `complete_settle`, `fail_settle`, `enter_paid`, `finalize_race`, `feed`. Each tick emits `Tick` with lure, light, shadow, pulse, pose and `state_hash`. |
| `ocellus_game::race` | Shared `LightRace`. Registration, then `reveal_seed` (non-public `entry`, `sui::random`), then ticks, then `finish` / `take_winner`. `create_race` is public and free. |
| `ocellus_game::reef` | One shared `Reef` per shard, 16×16 cells (`rules::grid`), `occupy` / `attach` / `release` / `evict_expired`. `current_seed` is fixed at 1 and only read by `feed`. |
| `ocellus_game::market` | `pay_hatch`, `pay_entry` (80% sink / 20% pot), `claim_prize`, timelocked `propose` / `execute`. |
| Client | `client/src/engine.js` is the integer mirror (`stepLarva`, `follow`). `client/index.html` verifies events. `client/demo/` renders the pose. `replay/replay.py` checks the same events in Python. |
| Data | `research/connectome.v1.json`: 224 reconciled cells, 3,010 chemical edges, 428 undirected gap junctions, 28 inhibitory. `research/signs.csv`: 138 of 224 cells are "default excitatory" with no transmitter identity in the cited papers, and 9 are "Contested" (kept excitatory although Kourakis 2019 reports VGAT; see phase 0). `ciona::canonical_hash` pins `9004dac6…cf16`. |

## The gap this plan closes

PR #2 measured it, and `research/phase0_behavior.json` still shows it: under brain model v1, **PR-II drive and antenna drive produce zero motor output** (`dimming_motor_mean: 0.0`, `antenna_only_motor_mean: 0.0`). PR-I light does reach the motor neurons (motor output rises with drive; silent with the light off).

So today:

- **Phototaxis** is mostly a body rule, and it points the wrong way. `integrate` turns the heading *toward* the lure whenever PR-I fires, up to `pr1_n × 180` angle units per tick, and motor yaw only adds a small bend. Real PR-I photoreceptors mediate **negative** phototaxis: in Kourakis 2019's assay, larvae cluster on the side of the dish away from the lamp. The game's "swim to the light" is a game convention, not the animal's behavior.
- **The escape swim is not neural.** PR-II spikes only arm a counter in `Body`. The thrust does not come from motor neurons. The demo's shadow escape (PR #4) is this counter.
- **Geotaxis is a body rule.** Antenna spikes nudge `tilt` by `TILT_STEP` (40), clamped to ±512. Nothing about gravity changes heading or thrust.
- **Steady light gives bouts, not continuous swimming.** On the old 237-label bench graph, brain model v1 at drive 20,000 swam on 38% of ticks, in 10 bouts per 400 (`bench/results/dynamics.json`, the number PR #2 reports). On the reconciled 224-cell graph (phase 0 probe, the chain's sensor mapping), PR-I intensity 4,000 to 20,000 swims on 17–40% of ticks, in 5–10 bouts per 400 ticks of 14–18 ticks each, and nothing swims below 4,000. Output isn't monotonic in drive (1,247 at 8,000, 979 at 10,000), and the rank correlation is 0.932 against the bench graph's 0.996.

The cause PR #2 names, and the sign table confirmed when this plan was written: **196 of 224 cells were inhibitory-or-not only by default, and the default is excitatory.** The relay neurons that should gate the dimming and gravity circuits are mostly in that default set, so inhibition never releases anything downstream. The 28 cells that *are* inhibitory are exactly the ones with a cited basis: PR-II (7), pr-AMG relay neurons (8), antenna relay classes (10) and ACINs (3). Phase 0 tested this explanation and it doesn't hold: no cited sign change, alone or with a tonic drive, makes PR-II or the antenna cells drive the motor neurons ([results](#results-2026-10-08-a-negative-result)).

Phases 2 and 3 would script behavior the brain does not produce. Phase 0's result is negative, so they stay on the body rules and the UI has to say so.

## Phase 0. Brain pathways: dimming and gravity reach the motor neurons

**Goal.** A dimming step and a gravity bias change motor output *inside the step*, with no new body rules. The three DESIGN §9.3 behavioral tests pass on the published wiring. Steady light produces sustained swimming if, and only if, the literature supports it.

### Results (2026-10-08): a negative result

Branch `brain/phase0-pathways`. `python3 bench/scripts/probe_dynamics.py` runs everything below on `research/connectome.v1.json` and writes it to `bench/results/dynamics.json` under `phase0`. `bench/scripts/test_course.py` copies the acceptance numbers into `research/phase0_behavior.json`. As the plan asks, the probe exits non-zero, because the shipped graph fails three tests. No sign, edge, constant or contract changed, so the goldens, `canonical_hash`, `phase2-events.json` and the gas figures stay as they are. `sui move test` (brain and game), `node client/src/check.js` and `replay.py` all pass unchanged.

**Acceptance tests on the graph as shipped.** Inputs are `sensor_drives` for a larva facing the light at intensity 8,000 (the lure at distance 0 under light 256). A shadow quarters the PR-I shade and drives PR-II at `PR2_DRIVE`, exactly as the chain does. Dimming numbers pool six onsets (ticks 80 to 105), because a single run depends on bout phase.

| Test | Result | Measured |
|---|---|---|
| Dimming step | fail | Motor mean 1,227 before the shadow, 0 in the first 10 ticks, 0 without PR-II drive, 0 in the dark after. During the shadow only PR-II fires. |
| Dimming is left-biased | fail | No burst to split. |
| Antenna alone | pass | Steady light: motor mean 1,260 at tilt 0, 238 at +512, 900 at −512. In the dark, tilt gives 0. |
| Antenna steers a dimming swim | fail | No dimming swim at tilt 0 or −512 to steer. At +512 the shadow window has output, but it is a bout already running at the onset, identical without PR-II drive. |
| PR-I regression | pass (baseline) | Rank correlation 0.932, silent 0 ticks after the light goes off. These are the reference values for any later change. |
| Seizure | pass | Silent 12 ticks after an all-spiking start. |
| Silence from rest | pass | 0 spikes with no input, and with the antenna tonic only. |
| Coverage | recorded | 121 of 224 cells fire at least once across light, tilt and shadow. |
| Sustained swimming | recorded | Bouts. Share of ticks swimming is 0 below intensity 4,000, then 0.17, 0.23, 0.35, 0.26, 0.31 and 0.40 at 4,000, 6,000, 8,000, 10,000, 15,000 and 20,000. |

The dimming test passes only if PR-II raises the first 10 ticks above both the pre-step mean and the same shadow without PR-II drive, at four of six onsets or more, and the dark after is silent. A shadow also quarters PR-I drive, so without that control a rebound or a bout carried over would count as a dimming response.

**Trace.** Missing paths are not the block. Within three chemical hops, PR-II and the antenna cells each reach all 16 MNs and MGINs. Counting routes by net sign (the source and the relays multiplied; only a net-excitatory route can raise motor output), with summed bottleneck weight:

| From | 2 hops, net excitatory | 2 hops, net inhibitory | 3 hops, net excitatory | 3 hops, net inhibitory |
|---|---|---|---|---|
| PR-II | 22 routes, 117 (all via pr-AMG RN) | 38, 105 | 932, 2,589 | 718, 1,815 |
| Antenna cells | 21, 63 | 65, 1,146 | 1,166, 4,107 | 1,097, 4,247 |

**Ablations.** 89 hypotheses, run one at a time, all listed in `dynamics.json`. None passes all seven tests, and the best pass five. None makes PR-II drive reliably raise motor output. Starting from light, PR-II changes the first-10-tick motor mean by −164 to +259 with no consistent sign, and it raises output at no more than three of the six onsets. That is bout-phase noise against pre-step means of up to 2,000.

| Hypothesis | What happened |
|---|---|
| Flip one default class to inhibitory: prRN, MGIN, AMG, Em, PNIN, ddN or Cor | PR-II has no effect in any of them. prRN or MGIN silences the PR-I pathway. Em cuts light-driven output by 81% (1,260 to 241) and fails antenna-alone. |
| Kourakis 2019's own VGAT cells: AMG1–4, AMG6 and AMG7, then those plus Em | PR-II has no effect. With Em, light-driven output falls 75%, to 321. |
| Tonic drive on pr-AMG RN, 1,024 to 8,192 per tick | Below about 4,096 the cells don't fire on their own, because gap junctions drain them (with the gap junctions zeroed, 3,072 makes them fire). Above that, PR-II slows them (0.17 to 0.05 spikes per tick at 4,096, 0.77 to 0.65 at 8,192) but never silences them. Two of the eight (74, 94) get no PR-II synapse, and the relays' mutual inhibition (334) outweighs PR-II's input to them (69). Nothing downstream changes. |
| Tonic drive on the antenna relay neurons, 2,048 to 4,096 | PR-II has no effect, and light-driven output drops. |
| Tonic pr-AMG RN (4,096 to 16,384) plus an excitatory baseline (2,048 to 4,096) on the cells it inhibits: its MN and MGIN targets, the AMGs, or every MN and MGIN. 60 combinations. | Its five MN and MGIN targets: no release, because a baseline on five cells spreads across the gap-coupled MN and MGIN pool (1,943 sections of gap junction among them). Every MN and MGIN: the larva swims in the dark with no input. The AMGs: the only switch seen, in the dark only. Rest is 0 to 100, motor output is 650 to 1,500 while PR-II is on, and 0 after (for example pr-AMG RN 6,144 with AMG 4,096), through PR-II ⊣ pr-AMG RN ⊣ AMG → MN. It fails the full tests. Starting from light, the same release happens without PR-II: PR-I's excitatory input to pr-AMG RN (191) outweighs PR-II's inhibitory input (69), and the shadow quarters PR-I. The larva keeps swimming in the dark afterward, most likely through the AMGs' recurrent excitation (563), a fresh larva swims at hatch, and small changes in either drive flip the outcome. It also needs the AMGs to be excitatory, which Kourakis 2019 contradicts for six of the seven. |
| Kourakis 2019's VGAT signs plus a tonic pr-AMG RN, with and without a baseline on its MGIN targets (the paper's own circuit) | PR-II has no effect, in the dark or from light. |
| Leak shift 4 or 5, or adaptation 4,096, 2,048 or 0, on MN and MGIN | PR-II has no effect. Adaptation at 2,048 or below makes the motor ganglion keep swimming with no input. |

**Why, in this model.** Kourakis 2019 proposes "the inhibitory PR-IIs synapsing to the pr-AMG RNs to reduce their inhibition on the cholinergic MGINs." Three things in the wiring and the LIF model stop that from working:

1. PR-II's input to pr-AMG RN is small: 69 sections onto six of the eight cells, against the relays' mutual inhibition (334) and their PR-I input (191).
2. pr-AMG RN's output to the motor side is narrow: MGIN1L 107, MGIN1R 52, MGIN2L 2, MN1L 6, MN1R 5. The MGINs' input is dominated by BTN (315), the antenna relay classes (898), other MGINs (248) and Em (212).
3. Disinhibition needs something held down. In this model the MGINs rest silent with no drive of their own, and there is no central pattern generator. Supplying that drive would be a new model mechanism (a per-cell tonic input in Move, JS and Python), not a sign change, and no setting measured here works.

So sign changes can't make the dimming and gravity responses come from this graph. Phases 2 and 3 stay on the body rules (the `escape` counter and `TILT_STEP`), and the UI must call them game rules.

**Gravity, measured anyway.** In steady light, tilt already changes the left/right split of PR-I bouts and lowers total output, because the antenna relays inhibit the running bout asymmetrically. At tilt −512, right exceeds left by 14,748 NMJ units over 300 ticks; at +512 the two sides are within 107. Bostwick 2020 reports that gravitaxis is inoperable in constant light and triggered by dimming. The model has no such gate. If phase 3 ever reads the brain's antenna output, it would steer in steady light too, which contradicts the paper.

**The sign table, corrected without changing a sign.** Reading Kourakis 2019 in full (the Europe PMC full text) corrected several basis strings in `signs.csv`, which `build_connectome.py` now writes. Basis text is not part of `connectome.v1.bin`, so `data_hash` is unchanged.

- PR-I: the majority are exclusively VGLUT (glutamatergic), matching the widespread ocellus VGLUT in Horie 2008b. The registration predicts PR-9 is VGAT-only (high confidence) and PR-10 is VGAT and VGLUT.
- Antenna cells: VGLUT. MNs, MGINs, ddNs: the motor ganglion's VACHT block. ACINs: glycinergic.
- prRN: the registration predicts the six are **evenly mixed between VGAT and VACHT**, with low confidence in which cell is which. The VACHT- and AMPAR-positive relay neurons carry the PR-I circuit. The candidate table's "prRNs are cholinergic" was too strong. The class stays excitatory, and the basis says why.
- pr-AMG RN: five of eight VGAT, two VACHT, one unresolved. AntRN: eight of ten VGAT. Both stay inhibitory at class level.
- AMG: **VGAT in AMGs 1, 2, 3, 4, 6 and 7, VACHT in AMG5.** This is the paper's registration, not an inference from how it groups cells, as the candidate table assumed.
- Em: VGAT, agreeing with earlier GAD reports (Takamura 2010).

138 cells are still "Default excitatory." Nine are marked "Contested": PR-9, AMG1–4, AMG6, AMG7, Em1 and Em2. The model keeps them excitatory although the paper reports VGAT, because flipping them produced neither behavior and cut light-driven output by about 75%. Whether to make the table match the paper anyway is a separate decision, not a phase 0 pathway fix. It would move every golden and `canonical_hash`.

**Phototaxis direction: what the measurements imply.** The brain gets no bearing. All 23 PR-I cells receive the same shade term, so motor output tracks only how much light the cup sees. Under steady light the left/right split is close to even at every intensity, with the right side ahead by 1 to 10%. Heading toward or away from the lamp therefore comes entirely from the `PR1_TURN` body rule. With the current sensor mapping the brain cannot carry direction by itself, so "replace the rule with motor yaw" is not reachable. Flipping the rule's sign costs nothing on the brain side, though it still moves the goldens, because it's a body rule. Kourakis 2019 reports negative phototaxis. The choice between herding and "toward the light" stays open.

### What the brain must do

1. **Dimming / escape (PR-II).** A step-down in light, delivered as the existing `shadow` input, must raise NMJ-weighted motor output above the pre-dimming baseline, and the burst must stop when the input stops. The left/right split should be asymmetric (the dimming swim is leftward-biased; see sources below). The body's `escape` counter must not be what produces the thrust.
2. **Gravity (antenna / otolith).** During a swim, the sign of `tilt` must bias the left/right split of motor output, because the antenna relay neurons project asymmetrically (Bostwick 2020, below). Antenna drive does not have to raise total motor output. Its two-hop routes to the motor neurons are almost all inhibitory (see the trace in the results), so it can steer a swim but not start one.
3. **No regression on PR-I.** Motor output still rises with light level, and the network still goes silent after the light goes off and after an all-spiking start. Those are the properties PR #2 established.
4. **Sustained swimming, only if supported.** Real larvae swim in short bouts ("tail flicks") under ordinary conditions and add sustained swims in specific conditions (Kourakis 2019, below). Do not tune the model to swim continuously under steady light just because it looks better. If sustained output appears as a consequence of the sign fix, record it; if it doesn't, bouts stay the honest behavior and the modes are designed around bouts.

### Investigation (do this before editing signs)

Done on 2026-10-08. The outcome is in [the results above](#results-2026-10-08-a-negative-result); the steps are kept as the record of what was asked.

Work in `bench/scripts/probe_dynamics.py` and `bench/scripts/lif_model.py`, which already compare models without touching the chain.

1. **Trace the two pathways on the reconciled graph.** From `research/connectome.v1.json`, list every cell reachable in 1, 2 and 3 chemical hops from PR-II and from the two antenna cells, and mark each hop's sign from `signs.csv`. Report, per pathway: how many hops are default-excitatory, where the first inhibitory cell sits, and whether any path reaches an MN or MGIN at all. This is the measurement that says whether the block is the sign table or missing edges.
2. **Ablations, one change at a time**, re-running the dimming and antenna probes:
   - Flip each default-excitatory class on the path to inhibitory, class by class (prRN, MGIN, AMG, Em, PNIN, ddN, Cor), never more than one hypothesis at once.
   - Separately, try a tonic baseline on the inhibitory relay classes (a small constant drive, not a rewiring), since a disinhibitory circuit needs something to release.
   - Separately, try a lower leak or lower adaptation on MGIN/MN only, as a candidate for sustained output.
3. **Keep the wiring fixed.** No edge is added or deleted. A sign change is a one-line edit in `research/signs.csv` with a new `basis` string. Anything that needs an edge the matrices don't contain is out of scope and gets written up as a negative result.
4. **Candidate revisions, each justified or rejected in writing:**

| Candidate | Why it's a candidate | What would justify it |
|---|---|---|
| AMG and eminens (Em) inhibitory | Kourakis 2019 reports VGAT directly: in AMGs 1, 2, 3, 4, 6 and 7 (AMG5 is VACHT) and in the eminens cells (agreeing with GAD reports, Takamura 2010). It isn't only an inference from how the paper groups them. Neither class is on a two-hop route from PR-II or the antenna cells to the motor neurons. | **Measured, rejected for phase 0:** the flips produce no dimming or gravity response and cut light-driven output by 75–81%. The cells are marked "Contested" in `signs.csv`. |
| A small tonic drive on pr-AMG RN | The dimming circuit is disinhibitory: PR-II inhibits pr-AMG RN, which inhibits the cholinergic MGINs, so those cells need a resting inhibitory tone to be released from (Kourakis 2019). A release also needs the released cells to have drive of their own, which the LIF model doesn't give them. That second part is an inference from the model, not from the papers. | **Measured, rejected:** alone, and with a baseline on its MGIN/MN targets, the AMGs, or every MN and MGIN (60 combinations), PR-II never reliably raises motor output. The one dark-only switch, through the AMGs, fails the full tests. |
| No change to prRN, ACINs, MNs, MGINs, ddNs, PR-I, antenna cells | Mostly supported. ACINs glycinergic (Kourakis 2019, citing Nishino 2010). MNs, MGINs and ddNs sit in the VACHT block. PR-I mostly glutamatergic, though the registration predicts PR-9 VGAT-only and PR-10 VGAT and VGLUT. Antenna cells VGLUT-positive (Kourakis 2019, citing Horie 2008b). prRNs are not uniformly cholinergic: the registration predicts the six are evenly mixed between VGAT and VACHT, and the VACHT/AMPAR-positive ones carry the PR-I circuit. | **Done:** signs left as they were. The `basis` text for PR-I, the antenna cells, prRN, MN, MGIN, ddN, AMG5 and ACIN now cites Kourakis 2019. PR-9 is marked "Contested" and prRN "excitatory at class level". |

### Sources (only what the papers actually say)

- **Kourakis et al. 2019**, *eLife* 8:e44753, CC BY ([PMC6499539](https://pmc.ncbi.nlm.nih.gov/articles/PMC6499539/)). PR-I (23 cells, opsin segments inside the pigment cup) mediate negative phototaxis; PR-II (7 cells, not in the pigment cup) mediate the dimming response, producing highly tortuous, leftward-biased swims, both as characterized by Salas et al. 2018, which this paper cites. PR-I are glutamatergic and drive cholinergic motor neurons through two tiers of cholinergic interneurons; PR-II are GABAergic and the circuit is disinhibitory, argued from picrotoxin and from the *frimousse* mutant. VGLUT is expressed in the two otolith antenna cells. The antenna relay neurons (AntRN) cluster with the VGAT-expressing cells at the back of the brain vesicle. Two pairs of VGAT-positive neurons sit in the posterior motor ganglion (citing Horie 2009). The ACINs are glycinergic and are described as essential for the central pattern generator (citing Nishino 2010). Spontaneous swimming in the dark is mostly short tail flicks with very few sustained swims (citing Salas 2018); picrotoxin raises spontaneous swim frequency and lowers the dimming response.
- **Bostwick et al. 2020**, *Current Biology* 30:600–609 ([PMC7066595](https://pmc.ncbi.nlm.nih.gov/articles/PMC7066595/)). The otolith is a statocyst cell plus projecting excitatory antenna cells. Antenna relay neurons are inhibitory and project asymmetrically to the left and right motor units, which is what curves the body. Inhibitory photoreceptor relay neurons suppress that circuit until dimming inhibits them. Negative gravitaxis is triggered by dimming, not by gravity alone: downward-facing larvae reorient with curved swims, upward-facing larvae swim straight up, and under constant light the gravity circuit looks inoperable.
- **Ryan, Lu & Meinertzhagen 2016**, *eLife* 5:e16962, CC BY. The wiring itself, the cell classes, and the name "ascending contralateral inhibitory neuron" for the ACINs. This paper does not assign transmitters.

Three consequences for the game. From Bostwick 2020: gravity should do nothing visible until dimming opens the gate. From Kourakis 2019 (citing Salas 2018): an escape swim should be tortuous and leftward-biased, not just faster. Also from Kourakis 2019: under steady light the real larva moves away from the lamp. The current `integrate` contradicts all three.

**Phototaxis direction (decide in phase 0, apply in phase 1).** Two honest options:

1. **Flip the convention:** the player's light is a lamp the larva flees, and courses are run by herding. The body rule's sign flips, and later, if the motor yaw carries the direction on its own, the rule is removed.
2. **Keep "toward the light"** and label it in the UI and DESIGN as a game convention that reverses the animal's reflex.

Option 1 is the one that matches the brain's claim. Either way, the `PR1_TURN` heading rule is a body rule computed from the lure's true bearing, not from motor output, and the plan should aim to replace it with motor yaw once phase 0 shows the left/right split carries direction.

### Acceptance tests

Extend `bench/scripts/probe_dynamics.py` and fail the run unless all of these hold. Numbers below are the pass/fail shape, not targets; the measured values get written into `bench/results/dynamics.json` and `research/phase0_behavior.json` when they exist.

| Test | Passes when |
|---|---|
| Dimming step (currently 0) | Motor mean over the first 10 ticks after the step-down is greater than the pre-step mean and than the same shadow without PR-II drive, at four of six onsets or more, and the dark period returns to silence. |
| Dimming is left-biased | Over that burst, left NMJ weight exceeds right. (Split the probe's single `MW` sum into the two sides.) |
| Antenna alone | With constant light and no dimming, antenna drive does **not** raise motor output. This matches Bostwick 2020 and should be an explicit pass, not a failure. |
| Antenna steers a dimming swim | During a dimming-evoked swim, the sign of tilt changes which side (left or right NMJ weight) dominates. Total motor output does not have to rise: the antenna's routes to the motor neurons are almost all inhibitory, so it can steer a swim but not start one. |
| PR-I regression | The drive sweep's rank correlation doesn't fall below the shipped graph's (0.932 on the reconciled graph; 0.996 was the bench graph), and `ticks_to_silence_after_off` stays 0. |
| Seizure | `all_spiking_start_no_input` still reaches silence. PR #2 measured 12 ticks; record the new number, don't assert 12. |
| Coverage | The activity census reports cells fired at least once. Publish the count; don't set a quota. |
| Sustained swimming | Report `share_of_ticks_swimming` at each drive level. No minimum. If it stays bout-like, say so in the results file. |

### Golden tests and the three mirrors

`contracts/brain/tests/course_tests.move` pins `light_10`, `light_40`, `dark_20`, `shadow_40` and `tilt_40` against `contracts/brain/tests/goldens.json`. `contracts/game/tests/swim_tests.move` pins ten ticks against the same reference. Any sign or parameter change breaks all of them, which is what they're for.

Order: change `signs.csv` (and `connectome.v1.json`, which copies `sign` onto each cell), regenerate the Move graph with `bench/scripts/gen_move_brain.py` / `build_connectome.py`, rerun the Python reference, then update `goldens.json` from that output and re-run `sui move test` in `contracts/brain` and `contracts/game`. Then check the mirrors: `node client/src/check.js`, `replay/replay.py` against `bench/results/phase2-events.json`, and the demo's load-time replay of those same 50 ticks. All three must be regenerated from a fresh localnet run, because the old hashes will no longer match.

`ciona::canonical_hash` is a hard-coded 32-byte constant compared with `brain::data_hash_of`. A new connectome version means a new hash, and that constant has to change in the same commit. `SEIZURE_HOOK` stays `false`.

### Gas and storage

PR #2 measured model v1 on a localnet (Sui 1.80.1, frozen connectome): a typical tick rose from 1,450–2,610 to **1,640–3,200** units, an all-spiking tick from 12,500 to **20,100**, and the brain write from 11.4 M to **18.6 M** MIST, of which 99% is rebated (non-refundable 0.114 M to 0.186 M). The `adapt` vector caused the storage increase. PR #2 noted that storing it as `u16` would remove about half; `contracts/brain`'s `Brain` already declares `adapt: vector<u16>`, so re-measure the contract (not just the bench package) to confirm the saving is real.

A sign change doesn't add state, but it can add spikes, and spikes add gas because every spike walks that cell's outgoing edges. Re-measure with `bench/scripts/run_brain_localnet.py` after the change: typical tick, all-spiking tick, and a dimming burst. If the dimming burst pushes a tick past the first instruction tier (about 20,000 instructions, see DESIGN §3.5), record it as a blocker for phases 2 and 3 rather than guessing.

### Risks

- **No path at all: ruled out.** PR-II and the antenna cells reach every MN and MGIN within three chemical hops. **No justified change produces the behavior: this is what happened** (results above). Phases 2 and 3 stay on the body rules with the UI saying so. Don't add edges to force it.
- Sign flips change behavior for every existing larva concept. No larva is on a public network, so nothing is stranded, but every golden and the pinned `phase2-events.json` must move together.
- `data_hash` is still whatever the publisher passes to `create_frozen` (open item from PR #3). Phase 0 doesn't fix that; phase 7 depends on it being fixed first.

### Depends on

Nothing. Everything below depends on this, except phase 1, which can start in parallel because it only needs the PR-I pathway that already works.

## Playing without a signature on every tick

Today every brain step is its own transaction (`swim_tick` or `race_tick`), signed by the larva's owner, because `&mut Ciona` is an owned object. A 400-tick race leg is 400 wallet prompts. Some on-chain brain games avoid this by running play on a server and touching the chain only when ownership changes. Ocellus doesn't. Every step still runs in Move and emits `Tick`. What changes is who signs and who pays.

**Measured so far** (bench package, 237-label graph, every sensor driven at 20,000, local network only, `bench/README.md`). Model v1: 1 tick 1,640–3,200 computation units, 2 ticks 23,500, 5 ticks 209,100. Model v0: 100 ticks ran out of gas at the 50 SUI budget cap. The jump comes from Sui's tiered instruction pricing (DESIGN §3.5). Mainnet must be re-measured, and so must the game's `ciona::swim` path, which adds checks and an event on top of the bench step.

| Option | How it works on Sui | Tradeoffs |
|---|---|---|
| **A. Several steps per transaction** | A new `ciona::swim_many(ciona, connectome, clock, inputs)` runs N brain steps in one call. Calling `swim` N times in one PTB doesn't work: `step` aborts with `E_CLOCK` when two steps share a clock millisecond, and every command in a transaction sees the same `Clock`. | Fewer signatures, but the tier cliff caps N. DESIGN's target of ≥ 4 ticks under ~20k instructions is an **estimate** that needs the planned optimizations. Treat N as a measured cap, not a promise. Every step still emits `Tick`, so replay is unchanged. |
| **B. Sponsored transactions** | Sui's native sponsorship: `sender` is the player, `GasData.owner` is the game's gas-station address, and both sign the full `TransactionData` ([Sui docs](https://docs.sui.io/develop/transaction-payment/sponsor-txn)). | The player holds no SUI and sees no gas, but **still signs every transaction**. On its own this doesn't remove the prompt. The operator pays gas from its own funded address, never from the `Sink` (it has no withdraw) or from race pots. This is an operating cost, not a payout to holders. The station must allowlist Ocellus `moveCall` targets, rate-limit per address, and cap the budget (all from the Sui hardening list). |
| **C. A session that one signature authorizes** | Sui has **no protocol-level session key for ordinary wallets**. Two honest versions: (1) **zkLogin**. The app's ephemeral key signs silently until `maxEpoch` ([zkLogin](https://docs.sui.io/sui-stack/zklogin-integration/)), but it carries the whole account's authority. (2) **A Move-level grant**, the same pattern as DeepBook's `deepbook_sessions` ([docs](https://docs.sui.io/onchain-finance/deepbook/deepbook-predict/contract-information/sessions)). The owner signs once: `session::open(ciona, delegate, max_ticks, expires_ms, mode)` wraps the larva in a shared `SwimSession`. A browser-held key may then call only `session::swim` or `session::race_tick` on that one larva, until the tick budget or deadline runs out. `session::close` returns the larva: the owner can call it any time, and anyone can call it after the deadline. | One prompt covers a race leg. The scope is narrow: one larva and two step functions, with no transfer, claim, settle or payout. `Ciona` has `store`, so it must stay wrapped and never be sent to the delegate address. Otherwise a leaked browser key could take the larva. Wrapping makes the larva a shared object, so its ticks go through consensus. Two ticks landing in the same commit would hit `E_CLOCK`, so the client must space them. For `race_tick` the inputs come from the revealed seed, so a delegate can only choose *when* to tick, not what the larva sees. |

**Recommended default: C(2) + B, one step per transaction, with A as an optimization.** The player signs `session::open` once per race leg or free-swim stretch. The browser key signs each step, the game's station sponsors the gas, and the transaction goes to a full node. `swim_many` comes in only after the optimized step measures inside the first tier on testnet and mainnet. zkLogin players can use C(1) instead. It is simpler, but broader in authority.

**Never off-chain:** the brain step (`brain::tick_state`), the race seed (`race::reveal_seed` with `sui::random`), hatching randomness, settlement (`claim`, `complete_settle`, `fail_settle`, `reef::evict_expired`), and payouts (`finalize_race`, `market::claim_prize`). The server may build transactions, sponsor gas, submit them and index events. It never holds the owner's key or the larva, and it never decides an outcome. If it stalls or censors, the owner can still `close` the session and step the larva directly from their wallet.

## Phase 1. Light racing ladder

**Goal.** A series of shared light races where the only thing a player controls is where the light is, and the brain's PR-I pathway does the swimming. Genomes differ in excitability, so larvae steer differently, and breeding is how you get a larva that steers the way you want.

### What the brain must do

Nothing new beyond phase 0's phototaxis decision. `race_tick` already steps the brain with a lure from `brain::race_lure(seed, tick)` and a shadow from `brain::race_shadow`. The ladder adds track variety by replacing that one formula with a family of them, all pure functions of `(seed, tick)`.

If phase 0 picks the herding convention, a race is scored on reaching a goal region while the lamp pushes the larva, and `best_distance` becomes distance to the goal instead of to the lure. That's a change to `ciona::race_tick`'s scoring line and to `apart`, not to the brain.

### Contract changes

- `ocellus_brain::brain`: add `race_lure_at(seed, tick, kind)` (or a `kind` argument) returning `(u64, u64)`. Keep `race_lure` as kind 0 so existing tests don't move. Kinds to support, all deterministic: fixed lamp, lamp drifting along one axis, lamp on a loop, and a lamp that blinks (return the position plus a light level, since `race_tick` currently hard-codes `light = 256`).
- `ocellus_game::race`: store `kind: u8` on `LightRace`, chosen in `create_race` and covered by the reveal so it can't be changed after entries open. `create_race` currently takes only a `Clock`; adding a `kind` argument is source-compatible if a default entry point is kept.
- `ocellus_game::ciona::race_tick`: read the kind, pass the resulting light level instead of the constant 256, and keep scoring `best_distance` the same way.
- **Currents:** `Reef.current_seed` is never rolled. Add `reef::roll_current(reef, r, clock)`, a non-public `entry` that draws from `sui::random` once per window, and a pure `brain::drift(current_seed, x, y)` applied inside `integrate` as an additive displacement. This is a body-level force, like gravity on a boat, not a brain input, and the doc should say so. It changes every golden pose, so it ships with its own golden update.
- **Breeding:** not built. `Ciona` has `parents` and `generation` but nothing writes them, and there is no spawn function. Phase 1 needs a minimal one: `ciona::spawn(a, b, r, clock, connectome, ctx)` that requires both adults (`stage == 3`), checks the self-sterility alleles in the genome bytes (DESIGN §5.3), crosses per locus with `Random`, and mints a larva. It does not need the full adult lifecycle. Price it through `market::pay_hatch` so breeding isn't a free mint.

### Client and verifier

- `engine.js` needs the same `race_lure_at` and `drift` functions, byte-for-byte with the Move. `follow` already replays whatever lure the event recorded, so old events still verify; only new events need the new code.
- The demo's course is a fixed gate layout in `client/demo/index.html`. Add the track kinds as selectable courses, rendered from the same pure function, so the picture can't disagree with the chain.
- The verifier page shows the genome's decoded gains and leak (`decodeGenome` already returns them) next to the replay, so a viewer can see why two larvae took different lines.

### Tests and acceptance

- For each kind, a Move test: two larvae with different genomes (different `gains[0]` and `lr[0]`) finish one identical revealed race at different `best_distance`.
- A test that the seed is unreadable before `reveal_seed` and that `race_tick` aborts before it. Already true; keep it.
- A drift test: the same inputs with two `current_seed` values end at different positions, and both hashes match the Python reference.
- Client: `check.js` replays one event log per kind.

### Gas, storage, risks

- No new per-tick state. A second pure function is noise next to the brain step. Re-measure once anyway.
- A race leg is hundreds of `race_tick` calls. Ship it with the session, sponsorship and batching path in [Playing without a signature on every tick](#playing-without-a-signature-on-every-tick), not as one wallet prompt per tick.
- **Open item, PR #3:** `hatch_founder` is free and never calls `pay_hatch`. A racing ladder with free larvae is fine for the demo and wrong for launch. Wire founder hatching through `pay_hatch` (new `hatch_paid<T>`, mirroring `enter_paid`) before the ladder is playable against the coin, and keep `hatch_founder` behind a dev-only flag or remove it. Note `market` already has `settle_bounty`, which nothing pays out.
- `create_race` is a public, free `entry`. Anyone can open races. Cap open races per game, or require `pay_entry`-style funding at creation, before this is public.
- Shared `LightRace` is written at `enter`, `reveal_seed` and `finish` only, so the race itself doesn't hot-spot. Good; keep it that way.

### Depends on

Phase 0 is not required. The PR-I pathway already tracks light level. Currents and breeding can land after the track kinds.

## Phase 2. Predator gauntlet

**Goal.** A survival mode whose outcome is the PR-II escape pathway. Shadows sweep the course; a larva that escapes in time keeps its yolk, and one that doesn't is eliminated. The player can only place or time the light, not move the larva.

### What the brain must do

Phase 0's dimming result: a shadow must change motor output and heading inside `tick_inner`, and the escape thrust must come from motor neurons. The body's `escape` / `escape_cd` / `escape_thrust` fields should be demoted to telemetry (still useful for the UI) or removed once the neural burst is real. Removing them changes `Body`'s layout, which is a stored struct, so do it before anything is deployed and not after.

### Contract changes

- New module `ocellus_game::gauntlet` with a shared `Gauntlet`: a schedule seed (revealed the same way as `LightRace`, via `reveal_seed`), a tick window, and a table of entrants. Shadow positions are a pure function of `(seed, tick)`, like `race_shadow` but returning a circle per tick instead of a bool.
- `ciona` gains `gauntlet_tick`, parallel to `race_tick`: it computes whether the larva's pose is inside a shadow circle, passes that as `shadow`, and records the resulting displacement. Elimination is a recorded outcome, not a deletion: the larva is marked failed in the gauntlet table and can still swim elsewhere.
- Entry goes through `market::pay_entry` with the gauntlet's id, exactly as races do, so the sink/pot split is unchanged.

### Client and verifier

- `engine.js` learns the shadow-circle function so the demo can draw the predators on the same integers the chain uses.
- The verifier draws the PR-II spike rows for the ticks where `shadow` was true, which is the whole point of the mode: you can see the escape happen in the cells.

### Tests and acceptance

- A larva with the dimming pathway intact covers more distance during a shadow window than the same larva with PR-II drive removed (test this by a second connectome fixture with PR-II indices empty, not by a flag).
- Yolk falls faster during an escape (`BURN_ESCAPE` is 20, on top of the idle and bout burns), and a gauntlet long enough drains a larva that escapes on every shadow. Assert the ordering, not a specific tick.
- Replay: a full gauntlet log passes `follow` and `replay.py`.

### Gas, storage, risks

- One extra shared-object read per tick, no extra write. The gauntlet object is only written at entry and at the final mark.
- `gauntlet_tick` needs the same session entry point as `race_tick` (see [Playing without a signature on every tick](#playing-without-a-signature-on-every-tick)). Its shadow schedule comes from the seed, so the delegate key can't choose what the larva sees.
- If phase 0's dimming burst makes the tick much more expensive, the gauntlet is the first place it hurts, because every tick in the window is a dimming tick. Re-measure before building the mode.
- Don't let the gauntlet mint rewards by itself. Payouts reuse `claim_prize`.

### Depends on

Phase 0. Without it, this mode is the existing 8-tick thrust counter with a new name.

## Phase 3. Depth and gravity settlement puzzles

**Goal.** Reef spots differ in depth and current, and reaching the good ones requires the gravity pathway: the larva only climbs or dives when dimming has opened the otolith circuit. Settlement stays the existing `claim` rule.

### What the brain must do

Phase 0's antenna result: tilt changes the motor left/right split only during a dimming window, and not in constant light. The puzzle is built around that gate. A player who holds the light steady cannot steer by gravity; a player who dims at the right moment can.

### Contract changes

- `ocellus_brain::brain`: `Body` has `tilt` but no depth. Add `depth: u32` only if phase 0 shows the gravity pathway actually moves the body. Update it in `integrate` from the tilt-driven motor bias, and include it in the state hash only if it changes the tick inputs; otherwise it is derivable and should stay out of the hash to keep old-style verification simple. Decide this explicitly in the phase 0 write-up.
- `ocellus_game::reef`: cells gain a static depth band (a pure function of the cell index, so no extra state) and `current_of` finally varies per cell. `ciona::claim`'s `near` test gains a depth term. `ciona::feed` already pays `(current_of % 10) + 1`; point that at the per-cell current so the best spots are worth more.
- No new randomness here. Depth bands are fixed by the shard, so every player faces the same puzzle and replays agree.

### Client and verifier

- The demo already fakes depth as presentation (PR #4: "the engine has no depth"). Phase 3 replaces that with the integer depth, and the presentation reads it instead of inventing it.
- The verifier shows tilt and antenna firing alongside the climb, so a viewer can see the gate open and close.

### Tests and acceptance

- Constant light: a larva held at a non-zero tilt ends a window at the same depth it started.
- Dimmed light: the same larva changes depth, and the sign of tilt picks the direction.
- Two cells at different depths: `feed` returns more energy on the higher-current one, and `claim` rejects a larva that is close in x/y but far in depth.

### Gas, storage, risks

- One `u32` on `Body` is small. The cost is the phase 0 tick, not the field.
- Puzzles are free-swim stretches driven by the player's light and dimming. They use `session::swim` under the same one-signature path (see [Playing without a signature on every tick](#playing-without-a-signature-on-every-tick)).
- `Ciona` and `Body` are stored structs. Adding a field is fine now and a migration later. Land it before any deployment.
- The 20-minute competence clock (`rules::competence_ms`) and the 1,200-tick minimum are unchanged. Puzzles have to be solvable inside the remaining yolk, which the tests should check.

### Depends on

Phase 0, and phase 1's current roll if puzzles are meant to share the live current. The depth field itself does not depend on phase 1.

## Phase 4. "Raising" through adaptation state

**Goal.** A larva that has been swum behaves a little differently from a fresh one, using only the adaptation state the model already has. No rewiring, no new learning rule, and no claim that this is memory.

### What the brain must do

`Brain.adapt` is a `vector<u16>`, incremented by 8,192 on every spike and decayed by 1/16 per tick, added to the threshold. It exists to stop runaway firing (PR #2). It is not a store of experience: anything it remembers is gone within a few dozen quiet ticks.

Raising, honestly, means three things and no more:

1. **Let adaptation persist across sessions.** It already does, because it lives on the object. A larva worked hard yesterday starts today slightly less excitable. Say exactly that in the UI.
2. **Optionally lengthen the decay**, by changing `ADAPT_SHIFT`, so a training session matters for a whole play session. This is a modeling choice, not a biological one, and it must be labeled as such. Real *Ciona* larvae are not trained; the papers cited here describe reflexes, not learning.
3. **Bound it.** `adapt` already saturates at `u16` max. Keep that bound. Do not add a second, slower variable unless its gas and storage cost is measured and accepted.

### Contract changes

- No new struct if decay stays as it is. A slower decay is a constant change in `brain.move` plus a golden update.
- If a slower component is added, put it in `Brain` as a second `vector<u16>` and document the extra write. Do not put it in dynamic fields; the tick would have to open them every time.
- `ciona` needs no new function. Raising is just `swim`.

### Client and verifier

- Show the adaptation of the sensory classes as a small bar, computed at replay time from the event log rather than stored again. `follow` can accumulate it because it re-runs the step.
- Copy in the UI: "this larva fires less readily for a while after hard swimming." Never "training" or "learning."

### Tests and acceptance

- Two larvae, identical genome: one swum through a bright window, one rested. On the next identical input, the swum one produces fewer spikes. The rested one matches the fresh golden.
- After enough quiet ticks, the two agree again. The test measures how many ticks that takes and writes it down; it does not assert a number chosen in advance.
- A test that no function changes `signs`, the connectome, or the genome. This is a property to keep true, not a feature to add.

### Gas, storage, risks

- The existing `adapt` vector is already the expensive part of the write (PR #2: 11.4 M to 18.6 M MIST, 99% rebated). A second vector of the same size roughly doubles that line. Measure before adding one.
- The biological risk is over-claiming. The README and the demo text need a sentence that says this is the model's spike-adaptation variable, not a model of memory.

### Depends on

Nothing structural. Better after phase 0 so the numbers mean something, but it can be prototyped on the current model.

## Phase 5. Swarm events

**Goal.** Many larvae in one shared zone at once: a race or a gauntlet with a crowd, where larvae interact through the shared world and not through each other's objects.

### What the brain must do

Nothing. Each larva is its own object and is stepped by its owner, exactly as now. The swarm is a property of the shared objects, not of the brain.

### Contract changes

- **Don't step other players' larvae.** `swim` and `race_tick` take `&mut Ciona`, so only the owner can tick it. Keep that. A swarm mode that ticks everyone in one transaction will hit the per-transaction computation ceiling (DESIGN §3.5) and the shared-object contention limits at the same time.
- **Sharding.** `reef::add_shard` already creates more `Reef` objects, and `Ciona.home` records which one. Swarm events should be pinned to a shard, with a cap on entrants per shard chosen from a measurement, not a guess.
- **Interaction.** Larvae affecting each other (blocking a cell, shading a neighbor) must be a pure function of posted poses, not a write to the other larva. Add a small shared `SwarmBoard` that stores the last posted `(x, y, tick)` per entrant, written once per tick by that entrant's own transaction. Reads of it are the only cross-larva input, and they go in as extra fields on the `Tick` event so replay still works.
- **Limits.** One tick per transaction stays the rule. A transaction that tries to step several larvae should be rejected by construction: no function takes two `&mut Ciona`.

### Client and verifier

- The verifier already replays one larva. For a swarm, it replays each larva independently and then checks the posted poses against the board. Add that second check rather than folding everything into one hash.
- The demo renders neighbors from the board as presentation only.

### Tests and acceptance

- Two larvae posting to one board: each replay matches its own hash, and a replay that ignores the board fails the pose check.
- A test that a third party cannot write a pose for a larva it doesn't own.
- A load test on a localnet: N larvae posting to one board in the same checkpoint, with N increased until contention shows up. Record the N where it degrades; that number becomes the shard cap.

### Gas, storage, risks

- The board is the hot object. Every entrant's tick writes it, so it serializes the shard. Keep the write to a few integers per larva and shard early.
- Stale poses: a larva that stops ticking leaves its last pose up. Expire entries older than a set number of milliseconds using `Clock`, or the board fills with ghosts.
- Replay now depends on other players' transactions. Publish the board events alongside the tick events or verification is impossible after the fact.

### Depends on

Phases 1 and 2 for the modes worth crowding. The board itself can be built earlier.

## Phase 6. Brain-replay highlights

**Goal.** A shareable clip of a larva's best moments, verified cell by cell, so a viewer sees the spikes that caused the swim rather than a video of it.

### What the brain must do

Nothing new. The `Tick` event already carries `state_hash`, `spikes` (the cumulative spike count, not the set), the inputs and the pose. The missing piece is the spike set: `follow` recomputes it, but a viewer can't see it without re-running.

### Contract changes

- Emit the spike bitset. `Brain.spiked` is four `u64`s (256 bits) for 224 cells, 32 bytes. Adding it to `Tick` grows every event by that much. Check `max_event_emit_size` against a real tick before committing, and if it's tight, emit it only on ticks the player marks.
- `ciona::mark(ciona, clock)` records a tick range the owner flags as a highlight. It stores nothing heavy: a start tick, an end tick and the hash at both ends.

### Client and verifier

- This is mostly client work. `engine.js` already returns `fired` from `stepLarva` but `follow` throws it away. Keep it, and draw the 224 cells per frame in the verifier, colored by class (PR-I, PR-II, antenna, MN, everything else).
- A "clip" is a JSON file of the `Hatch` plus the `Tick` events for the range, which `follow` and `replay.py` already accept. Sharing is handing someone that file. No new chain object is needed for the clip itself.
- The demo's "Save run as events" (PR #4) becomes "save this range."

### Tests and acceptance

- A clip file with one altered spike bit fails verification at that tick.
- The drawn frame agrees with the bitset: the cells listed as fired are exactly the ones `stepLarva` returned.
- A clip from phase 2 shows PR-II firing before the escape, and one from phase 3 shows the antenna cells firing only while dimmed. These are demo checks, not chain checks.

### Gas, storage, risks

- 32 bytes more per tick event, forever, for every larva. Measure the event size once and decide whether it's every tick or only marked ranges. Marked ranges are the cheaper default and probably enough.
- Clips can be faked visually but not numerically: the verifier is the whole feature, so the clip format should be exactly the event JSON and nothing prettier.

### Depends on

Nothing. It's better once phases 0, 2 and 3 give it something worth watching.

## Phase 7. Lineage and population dataset seasons

**Goal.** Publish, per season, a dataset of every larva's genome, parentage, and outcome, so anyone can analyze the population without trusting the project to summarize it.

### What the brain must do

Nothing directly. The dataset is events plus the connectome they were run on.

### Contract changes

- **Fix the hash provenance first** (open item, PR #3). `create_frozen` stores a `data_hash` the publisher supplies and only checks that it is 32 bytes long. `ciona` then trusts it by comparing against `canonical_hash`. Before any dataset is published, the connectome's hash must be computable by anyone from `research/connectome.v1.json` and checked at publication: the client refuses a connectome whose `blake2b256` over the canonical encoding doesn't match, and the season record names the encoding. Computing it inside Move over the whole graph may not fit a transaction; if it doesn't, publish the encoding and the hash and verify off-chain, and say that's what was done.
- `ciona::spawn` (phase 1) must emit both parents and the seed-independent genome. It does not emit the random seed.
- A `Season` object: an id, a start and end timestamp, the connectome id and its hash, and the package version. No larva data is copied into it. The dataset is the event stream filtered by time.

### Client and verifier

- `replay/` gains a script that pulls a season's events and writes one file per larva plus an index: genome, parents, ticks, final pose, race results. The index carries the connectome hash so a reader can confirm which brain produced it.
- The verifier gains "open a season index" to replay any larva in it.

### Tests and acceptance

- A season file regenerated from the same events is byte-identical.
- A larva in the file replays to its recorded final hash.
- The file's connectome hash matches `connectome.v1.json` for that season, and a different season can name a different hash.

### Gas, storage, risks

- No per-tick cost. The cost is event volume, which is set by how much phases 1 through 6 emit. Keep events small.
- Seasons are snapshots of rules as well as of larvae. Record the package id, or a dataset from before a rule change will be replayed with the wrong code.
- Don't publish datasets that include anything but what's already public on-chain.

### Depends on

Phase 1 for parentage worth publishing, and the hash-provenance fix, which can be done on its own at any time.

## Dependency order

```
phase 0  brain pathways ─────────────▶ phase 2 gauntlet ──┐
        │                                                  │
        ├──────────────────────────────▶ phase 3 depth    │
        │                                                  ▼
phase 1  racing ladder (parallel) ──▶ phase 5 swarm ◀── phase 2, 3
   │
   ├── breeding, currents
   └── phase 7 seasons (also needs the hash-provenance fix)

phase 4  adaptation display     independent; best after phase 0
phase 6  replay highlights      independent; best after phases 0, 2, 3
hash provenance                 independent; required before phase 7
pay_hatch wiring                independent; required before any paid mode launches
```

## Open items to carry (from PR #3)

| Item | Where it bites |
|---|---|
| `hatch_founder` is free and never calls `pay_hatch`, even though `pay_hatch` is implemented and tested. | Phase 1, before the ladder is played with the coin. Add `hatch_paid<T>` and stop exposing the free path. |
| `Connectome.data_hash` is whatever the publisher passes in. `ciona` only checks it against a hard-coded constant. | Phase 7, and any public claim that the on-chain brain is the published one. |
| `market.settle_bounty` is set in `bind` and never paid. | Phase 3, if settlement is going to be rewarded. Either pay it or remove it. |
| `Reef.current_seed` is fixed at 1. | Phases 1 and 3. |
| No spawn function exists. `parents` and `generation` are always empty and 0. | Phases 1 and 7. |
| `Body.escape*` fields script the escape swim. | Phase 2, once phase 0 makes them redundant. |

## Explicitly not in this plan

- No new coins, no mint authority, no change to the 80/20 sink split.
- No edge is added to the connectome. Signs move only with a cited basis and a recorded measurement.
- No mode where the player sets the larva's position, heading, or thrust.
- No promises about rewards beyond the prize pots already defined for in-game results.
