// node client/src/check.js
import { readFileSync } from "node:fs";
import { blake2b256, cellCenter, decideClaim, follow, statusText, toHex } from "./engine.js";

const root = new URL("../../", import.meta.url);
const doc = JSON.parse(readFileSync(new URL("research/connectome.v1.json", root)));
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
const corner = decideClaim({ tick: 1200, x: 0, y: 0 }, new Set(), 0, 20 * 60 * 1000);
if (corner.ok) throw new Error("corner should be outside the claim radius");
const early = decideClaim(ready, new Set(), 0, 0);
if (early.ok || !early.reason.includes("clock")) throw new Error(early.reason);

console.log("client engine ok", { ticks: live.frames.length, x: live.larva.x, y: live.larva.y, yolk: live.larva.yolk, light10x: gold.x, claim: young.reason });
