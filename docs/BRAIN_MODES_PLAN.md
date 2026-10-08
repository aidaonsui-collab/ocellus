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
| Data | `research/connectome.v1.json`: 224 reconciled cells, 3,010 chemical edges, 428 undirected gap junctions, 28 inhibitory. `research/signs.csv`: 196 of 224 cells are "default excitatory" with no transmitter identity in the cited papers. `ciona::canonical_hash` pins `9004dac6…cf16`. |

## The gap this plan closes

PR #2 measured it, and `research/phase0_behavior.json` still shows it: under brain model v1, **PR-II drive and antenna drive produce zero motor output** (`dimming_motor_mean: 0.0`, `antenna_only_motor_mean: 0.0`). PR-I light does reach the motor neurons (motor output rises with drive; silent with the light off).

So today:

- **Phototaxis** is mostly a body rule, and it points the wrong way. `integrate` turns the heading *toward* the lure whenever PR-I fires, up to `pr1_n × 180` angle units per tick, and motor yaw only adds a small bend. Real PR-I photoreceptors mediate **negative** phototaxis: in Kourakis 2019's assay, larvae cluster on the side of the dish away from the lamp. The game's "swim to the light" is a game convention, not the animal's behavior.
- **The escape swim is not neural.** PR-II spikes only arm a counter in `Body`. The thrust does not come from motor neurons. The demo's shadow escape (PR #4) is this counter.
- **Geotaxis is a body rule.** Antenna spikes nudge `tilt` by `TILT_STEP` (40), clamped to ±512. Nothing about gravity changes heading or thrust.
- **Steady light gives bouts, not continuous swimming.** On the old 237-label bench graph, brain model v1 at drive 20,000 swam on 38% of ticks, in 10 bouts per 400 (`bench/results/dynamics.json`, the number PR #2 reports). The reconciled 224-cell graph has not been swept the same way; `phase0_behavior.json` only records that PR-I drive of 8,000 produces motor output while dimming and antenna drive produce none. Re-run the sweep on the reconciled graph before quoting a percentage for it.

The cause PR #2 names, and the sign table confirms: **196 of 224 cells are inhibitory-or-not only by default, and the default is excitatory.** The relay neurons that should gate the dimming and gravity circuits are mostly in that default set, so inhibition never releases anything downstream. The 28 cells that *are* inhibitory are exactly the ones with a cited basis: PR-II (7), pr-AMG relay neurons (8), antenna relay classes (10) and ACINs (3).

Until phase 0 lands, phases 2 and 3 would be scripting behavior the brain does not produce. They wait for it.

## Phase 0. Brain pathways: dimming and gravity reach the motor neurons

**Goal.** A dimming step and a gravity bias change motor output *inside the step*, with no new body rules. The three DESIGN §9.3 behavioral tests pass on the published wiring. Steady light produces sustained swimming if, and only if, the literature supports it.

### What the brain must do

1. **Dimming / escape (PR-II).** A step-down in light, delivered as the existing `shadow` input, must raise NMJ-weighted motor output above the pre-dimming baseline, and the burst must stop when the input stops. The left/right split should be asymmetric (the dimming swim is leftward-biased; see sources below). The body's `escape` counter must not be what produces the thrust.
2. **Gravity (antenna / otolith).** Antenna drive from `tilt` must change motor output, and the sign of `tilt` must bias the left/right split, because the antenna relay neurons project asymmetrically (Bostwick 2020, below).
3. **No regression on PR-I.** Motor output still rises with light level, and the network still goes silent after the light goes off and after an all-spiking start. Those are the properties PR #2 established.
4. **Sustained swimming, only if supported.** Real larvae swim in short bouts ("tail flicks") under ordinary conditions and add sustained swims in specific conditions (Kourakis 2019, below). Do not tune the model to swim continuously under steady light just because it looks better. If sustained output appears as a consequence of the sign fix, record it; if it doesn't, bouts stay the honest behavior and the modes are designed around bouts.

### Investigation (do this before editing signs)

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
| AMG and eminens (Em) inhibitory | Kourakis 2019 lists the eminens cells and the AMGs among the PNS relay neurons picrotoxin should affect, which treats them as GABAergic. All 7 AMG and both Em are default excitatory today. | Antenna or PR-II drive reaches AMG or Em and stops there. Note this is an inference from how the paper groups them, and the `basis` string must say so. |
| A small tonic drive on pr-AMG RN | The dimming circuit is disinhibitory: PR-II inhibits pr-AMG RN, which inhibits the downstream cholinergic cells, so those cells need a resting inhibitory tone to be released from (Kourakis 2019). | PR-II fires and suppresses pr-AMG RN in the trace, but nothing downstream changes because nothing was being held down. |
| No change to prRN, ACINs, MNs, MGINs, ddNs, PR-I, antenna cells | Already supported: prRNs are the cholinergic, AMPA-receptor-expressing relay for PR-I (Kourakis 2019), so they stay excitatory even though the table's basis currently says "default". ACINs glycinergic (Kourakis 2019, citing Nishino 2010). MNs, MGINs and ddNs sit in the VACHT block. PR-I glutamatergic. Antenna cells VGLUT-positive (Kourakis 2019, agreeing with Horie 2008b). | Leave the signs. Do update the `basis` text for prRN, MN, MGIN and ddN to cite Kourakis 2019 instead of "default", because that changes what the table can claim without changing behavior. |

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
| Dimming step (already probed, currently 0) | Motor mean over the first 10 ticks after the step-down is greater than the pre-step mean, and the dark period returns to silence. |
| Dimming is left-biased | Over that burst, left NMJ weight exceeds right. (Split the probe's single `MW` sum into the two sides.) |
| Antenna alone | With constant light and no dimming, antenna drive does **not** raise motor output. This matches Bostwick 2020 and should be an explicit pass, not a failure. |
| Antenna after dimming | The same antenna drive during a dimming window does raise motor output, and the sign of tilt changes which side dominates. |
| PR-I regression | The drive sweep stays monotonic (Spearman of motor mean vs drive level above the current 0.996, or not below it), and `ticks_to_silence_after_off` stays 0. |
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

- The hop trace may show **no path at all** from PR-II or antenna cells to the motor ganglion even with signs flipped. In that case the honest outcome is a written negative result, and phases 2 and 3 stay on the body rules with the UI saying so. Don't add edges to force it.
- Sign flips change behavior for every existing larva concept. No larva is on a public network, so nothing is stranded, but every golden and the pinned `phase2-events.json` must move together.
- `data_hash` is still whatever the publisher passes to `create_frozen` (open item from PR #3). Phase 0 doesn't fix that; phase 7 depends on it being fixed first.

### Depends on

Nothing. Everything below depends on this, except phase 1, which can start in parallel because it only needs the PR-I pathway that already works.

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
