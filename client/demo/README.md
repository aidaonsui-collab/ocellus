# client/demo/: playable vertical slice

A WebGL demo of the Ocellus lifecycle: hatch a founder egg, swim the larva through seven light gates, survive a passing shadow, then settle on a free reef cell and metamorphose into an adult. It runs in any WebGL 2 browser with no wallet. Nothing in it touches a chain.

The demo is the second page of the Vite client. It imports the same `client/src/engine.js` that the larva verifier (`client/index.html`) uses, so there is one copy of the larva engine.

```sh
# from the repo root
npm install --prefix client
npm run dev --prefix client     # then open http://localhost:5190/demo/
npm run build --prefix client   # writes client/dist/index.html and client/dist/demo/index.html
```

## What is real and what is staged

| Part | Status |
|---|---|
| Brain and body | **The chain's integers.** Every tick is `stepLarva` from `client/src/engine.js` over `research/connectome.v1.json` (224 reconciled cells, 3,010 chemical edges, 428 gap junctions, 28 inhibitory cells), the JS mirror of `contracts/brain/sources/brain.move`. That covers genome-decoded physiology (per-group threshold and leak, sensory gains, left/right motor bias, starting yolk) and the integer body: heading, tilt, bouts, thrust, escape swims and yolk burn. |
| Inputs | Each tick passes what a `swim_tick` transaction carries: the lure position as unsigned integers, `light` (256, or 0 while you hold Dim), `shadow` (set while the ray's drawn shadow covers the larva) and `pulse` (never set: in brain.move it only burns yolk). The lure is kept in x ≥ 0, y ≥ 0 because the contract takes it as `u64`. |
| Engine check | On load the page replays the 50 `swim_tick` events in `bench/results/phase2-events.json` through its own tick code and compares the state hash, tick, spike count, x, y and heading of every tick. It also checks that a corrupted hash stops the replay at tick 7. The result is on the title screen and in "About the brain". |
| Steering | **The engine's.** Heading turns toward the lure while PR-I cells fire, and right-minus-left motor output yaws it during a bout. There is no steering assist. |
| Run record | The page keeps the Tick events a chain would emit. After settling, "Save run as events" downloads them as JSON, and the verifier page's "Open events" replays and checks every tick. |
| Presentation | One world millimetre is 80 engine units, and ticks run at 20 per second (on-chain each tick is one transaction). The pose is interpolated between ticks. Depth, pitch (from the integer tilt), roll, the tail beat rhythm, the camera and the gates are drawn by the game over the integer state. Gates are crossed in the horizontal plane because the engine has no depth. |
| Genome, `sui::random`, reef cells, rivals, shadow path | Simulated in the browser. The genome is 64 bytes from `crypto.getRandomValues`. Claiming uses the contract's rule on the integer pose (1,200 ticks, within 250 units of a free cell), but the cells are the demo's own shelf and the 20-minute competence clock is skipped. |

Random genomes differ a lot. In a headless run of 60 genomes steered along the course, 55 reached the shelf within 6,000 ticks (median about 1,160 ticks, slowest tenth past 2,800). The other five swam slowly and stalled partway or ran out of yolk, and a few eggs barely swim at all. If a larva has not swum after 240 ticks, the demo says so; Esc, then Restart run, draws a new egg.

## Controls

Mouse / WASD / left stick / drag steers the light. Hold click / Space / RT dims it (light 0), and the larva stops once its bout ends. E / A settles on a free cell once competent. B toggles the brain panel, H the HUD, C a cinematic camera, Esc pauses (graphics quality lives there), M mutes.

## Testing hooks

`?autorun` keeps the game simulating in a hidden tab and exposes `window.__oc`. `__oc.sim(seconds)` plays game time without rendering, `__oc.G.autopilot = true` steers through the gates and settles, and `__oc.replayEvents(events)` replays any event list through the page's tick code. With `?autorun`, `&genome=<128 hex chars>` fixes the egg.

## Rendering notes

Three.js r160 from jsDelivr, everything else procedural and inline: HDR pipeline with MSAA, volumetric light shafts ray-marched against the depth buffer, per-channel underwater absorption and in-scatter, Snell's window, animated chromatic caustics projected along the sun direction, gather depth of field with bokeh marine snow, a dual-filter bloom chain with an anamorphic streak, ACES tone mapping and a filmic grade, PCF soft shadows and dynamic resolution. Terrain, rocks, the stone arch, kelp, seagrass, anemones, sponges, sea fans, adults (two-layer: glass tunic over the branchial basket) and the larva (translucent trunk, notochord, fin fold, ocellus, otolith, yolk cells, 224 glowing cells) are all generated at load.

Brain wiring: Ryan K, Lu Z, Meinertzhagen IA (2016), *eLife* 5:e16962, CC BY 4.0.
