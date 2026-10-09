// node client/src/check.js
import { readFileSync } from "node:fs";
import { acceptConnectome, blake2b256, buildView, CANONICAL_HASH, cellCenter, decideClaim, decodeGenome, drift, follow, fresh, raceLureAt, raceShadow, sameSpikeBits, shadowCircle, spikeBits, statusText, stepLarva, toHex } from "./engine.js";

const root = new URL("../../", import.meta.url);
const doc = JSON.parse(readFileSync(new URL("research/connectome.v1.json", root)));
if (acceptConnectome(doc) !== CANONICAL_HASH) throw new Error("canonical hash");
const [ddx, ddy] = drift(1, 1000000, 1000000);
if (ddx !== 1 || ddy !== 1) throw new Error(`drift ${ddx},${ddy}`);
const events = JSON.parse(readFileSync(new URL("bench/results/phase2-events.json", root)));
const gold = JSON.parse(readFileSync(new URL("contracts/brain/tests/goldens.json", root))).light10;

const abc = blake2b256(new TextEncoder().encode("abc"));
if (toHex(abc) !== "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319") {
  throw new Error("blake2b abc mismatch");
}

const live = follow(doc, events);
if (!live.ok || live.frames.length !== 50) {
  throw new Error(`phase2 replay failed at ${live.stoppedAt}, frames ${live.frames.length}`);
}
if (live.larva.x !== 3256) throw new Error(`final x ${live.larva.x}`);

const broken = structuredClone(events);
const ticks = broken.filter((e) => e.tick != null);
const bad = Uint8Array.from(atob(ticks[6].state_hash), (c) => c.charCodeAt(0));
bad[0] ^= 1;
ticks[6].state_hash = btoa(String.fromCharCode(...bad));
const stopped = follow(doc, broken);
if (stopped.ok || stopped.stoppedAt !== 7 || stopped.frames.length !== 6) {
  throw new Error(`mismatch did not stop cleanly: ${JSON.stringify({ ok: stopped.ok, at: stopped.stoppedAt, n: stopped.frames.length })}`);
}
if (stopped.larva.tick !== 6) throw new Error("showed a tick past the mismatch");
const text = statusText(stopped);
if (!text.startsWith("Stopped at tick 7.")) throw new Error(text);

const [c0x, c0y] = cellCenter(0);
if (c0x !== 200 || c0y !== 200) throw new Error("cell 0 center");
const young = decideClaim(live.larva, new Set());
if (young.ok || !young.reason.includes("1200")) throw new Error(young.reason);
const ready = { tick: 1200, x: 200, y: 200 };
const open = decideClaim(ready, new Set(), 0, 20 * 60 * 1000);
if (!open.ok || open.cell !== 0) throw new Error(JSON.stringify(open));
const taken = decideClaim(ready, new Set([0]), 0, 20 * 60 * 1000);
if (taken.ok || taken.cell !== 0) throw new Error(JSON.stringify(taken));
const deep = decideClaim({ tick: 1200, x: 200, y: 200, depth: 400 }, new Set(), 0, 20 * 60 * 1000);
if (deep.ok || !deep.reason.includes("depth")) throw new Error(deep.reason);
const corner = decideClaim({ tick: 1200, x: 0, y: 0 }, new Set(), 0, 20 * 60 * 1000);
if (corner.ok) throw new Error("corner should be outside the claim radius");
const early = decideClaim(ready, new Set(), 0, 0);
if (early.ok || !early.reason.includes("clock")) throw new Error(early.reason);

const seed = Uint8Array.from({ length: 32 }, (_, i) => i + 1);
const circle = shadowCircle(seed, 1);
if (circle[0] !== 110 || circle[1] !== 80 || circle[2] !== 503) throw new Error(`circle ${circle}`);
const lure1 = raceLureAt(seed, 1, 0);
if (lure1[0] !== 870 || lure1[1] !== 267 || lure1[2] !== 256) throw new Error(`kind 0 ${lure1}`);
const fixed = raceLureAt(seed, 1, 1);
if (fixed[0] !== 840 || fixed[1] !== 250) throw new Error(`kind 1 ${fixed}`);
const axis = raceLureAt(seed, 1, 2);
if (axis[0] !== 870 || axis[1] !== 250) throw new Error(`kind 2 ${axis}`);
const loop0 = raceLureAt(seed, 0, 3);
const loop8 = raceLureAt(seed, 8, 3);
if (loop0[0] === loop8[0] && loop0[1] === loop8[1]) throw new Error("kind 3 did not move");
if (raceLureAt(seed, 0, 4)[2] !== 256 || raceLureAt(seed, 8, 4)[2] !== 0) throw new Error("kind 4 blink");

function genome(fillGain) {
  const g = new Uint8Array(64);
  for (let i = 0; i < 16; i++) g[i] = 128;
  for (let i = 16; i < 24; i++) g[i] = 64;
  for (let i = 24; i < 32; i++) g[i] = fillGain;
  for (let i = 32; i < 38; i++) g[i] = fillGain === 255 ? 255 : 128;
  return g;
}
function finish(bytes, kind) {
  const view = buildView(doc);
  const decoded = decodeGenome(bytes);
  const [body, brain] = fresh(view, decoded.yolk0);
  for (let t = 1; t <= 8; t++) {
    const [x, y, light] = raceLureAt(seed, t, kind);
    stepLarva(body, brain, view, [x, y], light, raceShadow(seed, t), false, decoded);
  }
  return `${body.x},${body.y}`;
}
for (let kind = 0; kind <= 4; kind++) {
  const calm = finish(genome(85), kind);
  const keen = finish(genome(255), kind);
  if (calm === keen) throw new Error(`kind ${kind} genomes tied at ${calm}`);
}

const clip = structuredClone(events);
const first = clip.filter((e) => e.tick != null)[0];
first.spike_bits = spikeBits([0]);
if (sameSpikeBits([], first.spike_bits)) throw new Error("empty bits matched cell 0");
const tampered = follow(doc, clip);
if (tampered.ok) throw new Error("altered spike bit was accepted");
const drawn = live.frames.at(-1).fired;
if (!Array.isArray(drawn)) throw new Error("frame has no fired cells");

console.log("client engine ok", { ticks: live.frames.length, x: live.larva.x, y: live.larva.y, yolk: live.larva.yolk, light10x: gold.x, claim: young.reason, cells: drawn.length });
