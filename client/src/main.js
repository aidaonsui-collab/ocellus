import doc from "../../research/connectome.v1.json";
import sample from "../../bench/results/phase2-events.json";
import { REEF, buildView, bytesOf, cellCenter, decideClaim, decodeGenome, follow, statusText } from "./engine.js";

const view = buildView(doc);
const cellClass = view.doc.cells.map((cell) => {
  if (cell.class === "PR-I") return "pr1";
  if (cell.class === "PR-II") return "pr2";
  if (cell.class === "Ant") return "ant";
  if (cell.class === "MN" || cell.class === "MGIN") return "mn";
  return "";
});

const status = document.querySelector("#status");
const track = document.querySelector("#track");
let pristine = sample;
let events = sample;
let shown = 0;
let timer = 0;
let occupied = new Set();
let claimed = null;
let current = null;
const bornMs = 0;
let nowMs = 0;

function ticksOf(list) {
  return list.filter((e) => e.lure_x != null && e.tick != null);
}
function hatchOf(list) {
  return list.find((e) => e.genome && e.tick == null);
}

function reveal(n) {
  const hatch = hatchOf(events);
  const ticks = ticksOf(events).slice(0, n);
  return follow(doc, hatch ? [hatch, ...ticks] : ticks);
}

function draw(result) {
  current = result;
  const larva = result.larva ?? { tick: 0, x: 0, y: 0, heading: 0, yolk: 0, hash: "" };
  document.querySelector("#tick").textContent = String(larva.tick);
  document.querySelector("#x").textContent = String(larva.x);
  document.querySelector("#y").textContent = String(larva.y);
  document.querySelector("#heading").textContent = `${Math.round((larva.heading || 0) / 65536 * 360)}°`;
  document.querySelector("#yolk").textContent = String(larva.yolk);
  const frame = result.frames.at(-1);
  document.querySelector("#depth").textContent = String(frame ? frame.depth || 0 : 0);
  const shadows = result.frames.filter((f) => f.shadow);
  const pr2 = shadows.reduce((s, f) => s + (f.pr2 || 0), 0);
  document.querySelector("#pr2").textContent = shadows.length
    ? `PR-II fired ${pr2} times across ${shadows.length} shadow ticks. The escape swim is the body's counter, not a motor-neuron burst.`
    : "";
  const hatch = hatchOf(events);
  if (hatch) {
    const decoded = decodeGenome(bytesOf(hatch.genome));
    document.querySelector("#gain").textContent = String(decoded.gains[0]);
    document.querySelector("#leak").textContent = String(decoded.leaks[0]);
  } else {
    document.querySelector("#gain").textContent = "—";
    document.querySelector("#leak").textContent = "—";
  }
  document.querySelector("#hash").textContent = larva.hash || "";
  const failed = result.stoppedAt != null || Boolean(result.error);
  status.textContent = failed
    ? statusText(result)
    : shown === 0 && !(larva.tick > 0)
      ? "Hatched. Step to predict the first tick."
      : statusText(result);
  status.className = "status" + (failed ? " bad" : shown ? " ok" : "");
  const decision = claimed != null
    ? { ok: false, cell: claimed, reason: `Claimed cell ${claimed}. Settlement attaches for one minute, then the record freezes the last tick.` }
    : decideClaim(larva, occupied, bornMs, nowMs);
  document.querySelector("#claimtext").textContent = decision.reason;
  document.querySelector("#claim").disabled = !decision.ok;
  document.querySelector("#claim").textContent = decision.ok ? decision.reason : "Claim";
  const size = REEF.grid * REEF.span;
  const yOf = (y) => size - y;
  let cells = "";
  for (let i = 0; i < REEF.grid * REEF.grid; i++) {
    const [cx, cy] = cellCenter(i);
    const hot = decision.cell === i;
    const fill = occupied.has(i) || claimed === i ? "#3d2c2a" : hot ? "#1d4a3c" : "none";
    cells += `<rect x="${cx - REEF.span / 2}" y="${yOf(cy + REEF.span / 2)}" width="${REEF.span}" height="${REEF.span}" fill="${fill}" stroke="#24403b" stroke-width="8"/>`;
  }
  const pts = result.frames.map((f) => [f.x, f.y]);
  const d = pts.map((p, i) => `${i ? "L" : "M"}${p[0].toFixed(1)} ${yOf(p[1]).toFixed(1)}`).join(" ");
  const last = shown > 0 || larva.tick > 0 ? [larva.x, larva.y] : null;
  track.setAttribute("viewBox", `0 0 ${size} ${size}`);
  track.innerHTML = cells
    + (d ? `<path d="${d}" fill="none" stroke="#d7fff0" stroke-width="28"/>` : "")
    + (last ? `<circle cx="${last[0]}" cy="${yOf(last[1])}" r="70" fill="#f2d38a"/>` : "");
  const fired = new Set(frame && frame.fired ? frame.fired : []);
  document.querySelector("#cells").innerHTML = cellClass.map((name, i) => `<i class="${name}${fired.has(i) ? " on" : ""}"></i>`).join("");
  document.querySelector("#step").disabled = failed || shown >= ticksOf(events).length;
  document.querySelector("#play").disabled = document.querySelector("#step").disabled;
}

function paint() { draw(reveal(shown)); }

document.querySelector("#step").addEventListener("click", () => {
  if (shown >= ticksOf(events).length) return;
  shown += 1;
  const result = reveal(shown);
  if (!result.ok) shown = result.frames.length;
  draw(result);
});
document.querySelector("#play").addEventListener("click", () => {
  clearInterval(timer);
  timer = setInterval(() => {
    if (shown >= ticksOf(events).length) { clearInterval(timer); return; }
    shown += 1;
    const result = reveal(shown);
    if (!result.ok) { shown = result.frames.length; clearInterval(timer); }
    draw(result);
  }, 180);
});
document.querySelector("#reset").addEventListener("click", () => {
  clearInterval(timer);
  events = pristine;
  shown = 0;
  occupied = new Set();
  claimed = null;
  nowMs = 0;
  paint();
});
document.querySelector("#claim").addEventListener("click", () => {
  if (!current?.larva) return;
  const decision = decideClaim(current.larva, occupied, bornMs, nowMs);
  if (!decision.ok) return;
  occupied.add(decision.cell);
  claimed = decision.cell;
  draw(current);
});
document.querySelector("#break").addEventListener("click", () => {
  clearInterval(timer);
  const ticks = ticksOf(pristine);
  const index = Math.min(shown, ticks.length - 1);
  // Break from the untouched log, so a second click on the same tick stays broken.
  const copy = structuredClone(pristine);
  const victim = ticksOf(copy)[index];
  const raw = Uint8Array.from(atob(victim.state_hash), (c) => c.charCodeAt(0));
  raw[0] ^= 0xff;
  victim.state_hash = btoa(String.fromCharCode(...raw));
  events = copy;
  shown = index + 1;
  const result = reveal(shown);
  if (!result.ok) shown = result.frames.length;
  draw(result);
});
document.querySelector("#file").addEventListener("change", async (ev) => {
  const file = ev.target.files[0];
  if (!file) return;
  clearInterval(timer);
  pristine = JSON.parse(await file.text());
  events = pristine;
  shown = 0;
  paint();
});

paint();

const params = new URLSearchParams(location.search);
if (params.has("ready")) {
  nowMs = 20 * 60 * 1000;
  shown = 0;
  const ready = { ok: true, stoppedAt: null, frames: [{ tick: 1200, x: 200, y: 200, heading: 0, yolk: 50000, hash: "ready" }], larva: { tick: 1200, x: 200, y: 200, heading: 0, yolk: 50000, hash: "ready" } };
  const paintReady = () => draw(ready);
  paintReady();
  if (params.has("claim")) document.querySelector("#claim").click();
} else if (params.has("break")) document.querySelector("#break").click();
else if (params.has("step")) {
  shown = Number(params.get("step")) || 1;
  const result = reveal(shown);
  if (!result.ok) shown = result.frames.length;
  draw(result);
}
