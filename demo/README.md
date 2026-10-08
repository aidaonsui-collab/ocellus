# demo/: playable vertical slice

A single-file WebGL demo of the Ocellus lifecycle: hatch a founder egg, swim the larva through seven light gates, survive a passing shadow, then settle on a free reef cell and metamorphose into an adult. It runs in any WebGL 2 browser with no build step and no wallet. Nothing in it touches a chain.

```sh
# from the repo root
python3 -m http.server 5180 --directory demo   # then open http://localhost:5180
```

## What is real and what is staged

| Part | Status |
|---|---|
| Brain | **Real wiring, real math.** The 237-cell matrix from `bench/graph_csr.json` (3,010 chemical entries, 866 directed gap entries, 28 inhibitory cells) steps every tick with brain model v1, the same integer update as `bench/sources/brain.move`: constants, stability-normalized gap coefficients, reversal floor, adaptation, and chemical → gap → sensory → membrane order. In the browser it reproduces the Move unit tests' golden spike totals exactly. It runs at 18 ticks/s, a pacing choice; on-chain the design is one tick per transaction. |
| Sensors | PR-I photoreceptors get the player's light, shaded by where the ocellus faces as the larva rolls. Ant1/Ant2 read body tilt. PR-II cells read dimming (tonic darkness plus the drop per tick). |
| Motor | The larva swims in **bouts**. A bout lasts while motor neurons keep firing (gaps under 3 ticks are bridged), and brighter light brings bouts more often. Thrust and tail-beat strength follow the motor output, weighted by the neuromuscular-junction values in `research/graph.json`. Right minus left bends the tail and sets the helical turn bias. Between bouts the larva glides and slows. The beat rhythm inside a bout is drawn by the game, because v1's left and right spikes don't alternate cleanly. |
| Steering toward the light | **Demo assist.** Heading eases toward the light at a rate gated by real PR-I spike rate. The tuned behavioural model is still a design item (DESIGN §9.3). |
| Escape swim | Triggered only when PR-II cells actually spike during the dimming event. In v1, PR-II drive doesn't reach the motor neurons, so the escape swim itself is a game-layer response to those real spikes. |
| State hash | BLAKE2b-256 chain over (previous hash, tick u64 LE, input digest u32, 237-bit spike set). Verified against RFC 7693 test vectors. The encoding is a demo choice, not a protocol spec. |
| Genome, `sui::random`, LarvalRecord, reef cells | Simulated in the browser to show the flow in DESIGN §5–§7. |

## Brain model history

The first version of this demo ran the v0 benchmark model. About 5 to 8 ticks after light reached PR-I, its motor ganglion locked into a self-sustaining period-2 loop that ignored input, and the demo used that loop as the tail beat. The loop turned out to be numerical: an unstable gap-junction update plus inhibition with no floor. Model v1 fixes both (see `bench/README.md`, section "Model v1", added in #2).

The demo now runs v1. In a scripted run of the full course, the larva swam in 30 bouts, roughly one every 2.5 seconds, and was swimming 43% of the time. It is silent without light and stops swimming soon after the light goes away.

## Controls

Mouse / WASD / left stick / drag steers the light. Hold click / Space / RT pulses it brighter (more PR-I drive, so more frequent swim bouts, and more yolk burned). E / A settles on a free cell once competent. B toggles the brain panel, H the HUD, C a cinematic camera, Esc pauses (graphics quality lives there), M mutes.

## Rendering notes

Three.js r160 from jsDelivr, everything else procedural and inline: HDR pipeline with MSAA, volumetric light shafts ray-marched against the depth buffer, per-channel underwater absorption and in-scatter, Snell's window, animated chromatic caustics projected along the sun direction, gather depth of field with bokeh marine snow, a dual-filter bloom chain with an anamorphic streak, ACES tone mapping and a filmic grade, PCF soft shadows and dynamic resolution. Terrain, rocks, the stone arch, kelp, seagrass, anemones, sponges, sea fans, adults (two-layer: glass tunic over the branchial basket) and the larva (translucent trunk, notochord, fin fold, ocellus, otolith, yolk cells, 237 glowing cells) are all generated at load.

Brain wiring: Ryan K, Lu Z, Meinertzhagen IA (2016), *eLife* 5:e16962, CC BY 4.0.
