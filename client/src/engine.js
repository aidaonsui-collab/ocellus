// Integer larva step. Matches bench/scripts/dynamics.py and the Move brain.
// Bit shifts are arithmetic floor-divides, not JS 32-bit >>.
import { ATAN, SIN } from "./trig.js";

const REST = 1048576;
const PARAMS = {
  thresh: REST + 16384, reset: REST - 4096, leak_shift: 3, w_scale: 320,
  gap_shift: 12, v_floor: REST - 16384, v_ceil: REST + 65536,
  adapt_inc: 8192, adapt_shift: 4,
};
export const CONST = {
  drive: 8000, near2: 4000 * 4000, shade_floor: 64, shade_span: 192, shadow_div: 4,
  ant_tonic: 1500, ant_gain: 6400, pr2_drive: 12000, pr2_window: 6, pr2_trigger: 3,
  escape_ticks: 8, escape_cooldown: 40, escape_thrust: 250, bout_bridge: 3,
  thrust_base: 40, thrust_div: 100, yaw_div: 800, yaw_cap: 400, pr1_turn: 180,
  tilt_step: 40, tilt_cap: 512, yolk0: 100000,
  burn_idle: 12, burn_bout: 26, burn_pulse: 18, burn_escape: 20, drive_cap: 20000,
};
const GROUP = {
  "PR-I": 0, "PR-II": 1, Ant: 2, "PR-III": 3, Cor: 4,
  prRN: 5, "pr-AMG RN": 5, "pr-BTN RN": 5, "pr-cor RN": 5,
  "ant1 RN": 5, "ant2 RN": 5, "ant1/2 RN": 5, "ant-cor RN": 5,
  "2 RN": 5, "PN RN": 5, Em: 5, MGIN: 6, MN: 7, ACIN: 8, AMG: 9,
  BTN: 10, pATEN: 10, aATEN: 10, "RTEN-a": 10, "RTEN-b": 10, DCEN: 10,
  vacIN: 11, trIN: 11, aaIN: 12,
  "cor-ass BVIN": 12, "cil-BVIN": 12, BVIN: 12, PNIN: 12, "PBV PNIN": 12,
  BPIN: 12, prIN: 12, antIN: 12, ambiguous: 12,
  Neck: 13, ddN: 13, PMGN: 13, MTN: 14,
};

function shr(x, n) { return Math.floor(x / 2 ** n); }
function floorDiv(a, b) {
  const q = Math.trunc(a / b);
  if (a % b !== 0 && (a < 0) !== (b < 0)) return q - 1;
  return q;
}
function isqrt(n) {
  if (n <= 0) return 0;
  let x = 1 << Math.floor(((n.toString(2).length) + 1) / 2);
  for (;;) {
    const y = Math.floor((x + Math.floor(n / x)) / 2);
    if (y >= x) return x;
    x = y;
  }
}
function sinCos(heading) {
  const h = heading & 65535;
  const q = Math.floor(h / 16384);
  const i = Math.floor((h % 16384) * 256 / 16384);
  const s = SIN[i];
  const c = SIN[256 - i];
  if (q === 0) return [s, c];
  if (q === 1) return [c, -s];
  if (q === 2) return [-s, -c];
  return [-c, s];
}
function atan2u16(y, x) {
  if (x === 0 && y === 0) return 0;
  const ax = Math.abs(x), ay = Math.abs(y);
  const ang = ax >= ay ? ATAN[Math.floor(ay * 256 / ax)] : 16384 - ATAN[Math.floor(ax * 256 / ay)];
  let a;
  if (x >= 0 && y >= 0) a = ang;
  else if (x < 0 && y >= 0) a = 32768 - ang;
  else if (x < 0 && y < 0) a = 32768 + ang;
  else a = 65536 - ang;
  return a & 65535;
}
function angDiff(src, dst) {
  let d = (dst - src) & 65535;
  return d >= 32768 ? d - 65536 : d;
}

const B2_IV = new Uint32Array([0xF3BCC908, 0x6A09E667, 0x84CAA73B, 0xBB67AE85, 0xFE94F82B, 0x3C6EF372, 0x5F1D36F1, 0xA54FF53A, 0xADE682D1, 0x510E527F, 0x2B3E6C1F, 0x9B05688C, 0xFB41BD6B, 0x1F83D9AB, 0x137E2179, 0x5BE0CD19]);
const B2_S = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3,11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4,7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8,9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13,2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9,12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11,13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10,6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5,10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3].map((x) => x * 2);
const b2v = new Uint32Array(32), b2m = new Uint32Array(32);
function b2add(a, b) { const o0 = b2v[a] + b2v[b]; let o1 = b2v[a + 1] + b2v[b + 1]; if (o0 >= 0x100000000) o1++; b2v[a] = o0 >>> 0; b2v[a + 1] = o1 >>> 0; }
function b2addc(a, b0, b1) { const o0 = b2v[a] + b0; let o1 = b2v[a + 1] + b1; if (o0 >= 0x100000000) o1++; b2v[a] = o0 >>> 0; b2v[a + 1] = o1 >>> 0; }
function b2g(a, b, c, d, ix, iy) {
  const v = b2v, x0 = b2m[ix], x1 = b2m[ix + 1], y0 = b2m[iy], y1 = b2m[iy + 1];
  b2add(a, b); b2addc(a, x0, x1);
  let p = v[d] ^ v[a], q = v[d + 1] ^ v[a + 1]; v[d] = q; v[d + 1] = p;
  b2add(c, d);
  p = v[b] ^ v[c]; q = v[b + 1] ^ v[c + 1]; v[b] = (p >>> 24) ^ (q << 8); v[b + 1] = (q >>> 24) ^ (p << 8);
  b2add(a, b); b2addc(a, y0, y1);
  p = v[d] ^ v[a]; q = v[d + 1] ^ v[a + 1]; v[d] = (p >>> 16) ^ (q << 16); v[d + 1] = (q >>> 16) ^ (p << 16);
  b2add(c, d);
  p = v[b] ^ v[c]; q = v[b + 1] ^ v[c + 1]; v[b] = (q >>> 31) ^ (p << 1); v[b + 1] = (p >>> 31) ^ (q << 1);
}
function b2compress(h, blk, t, last) {
  for (let i = 0; i < 16; i++) { b2v[i] = h[i]; b2v[i + 16] = B2_IV[i]; }
  b2v[24] ^= t >>> 0; b2v[25] ^= Math.floor(t / 0x100000000);
  if (last) { b2v[28] = ~b2v[28]; b2v[29] = ~b2v[29]; }
  for (let i = 0; i < 32; i++) b2m[i] = blk[4 * i] ^ (blk[4 * i + 1] << 8) ^ (blk[4 * i + 2] << 16) ^ (blk[4 * i + 3] << 24);
  for (let r = 0; r < 12; r++) {
    const s = r * 16;
    b2g(0, 8, 16, 24, B2_S[s], B2_S[s + 1]); b2g(2, 10, 18, 26, B2_S[s + 2], B2_S[s + 3]);
    b2g(4, 12, 20, 28, B2_S[s + 4], B2_S[s + 5]); b2g(6, 14, 22, 30, B2_S[s + 6], B2_S[s + 7]);
    b2g(0, 10, 20, 30, B2_S[s + 8], B2_S[s + 9]); b2g(2, 12, 22, 24, B2_S[s + 10], B2_S[s + 11]);
    b2g(4, 14, 16, 26, B2_S[s + 12], B2_S[s + 13]); b2g(6, 8, 18, 28, B2_S[s + 14], B2_S[s + 15]);
  }
  for (let i = 0; i < 16; i++) h[i] ^= b2v[i] ^ b2v[i + 16];
}
export function blake2b256(input) {
  const h = new Uint32Array(B2_IV); h[0] ^= 0x01010000 ^ 32;
  const blk = new Uint8Array(128); let t = 0, c = 0;
  for (let i = 0; i < input.length; i++) {
    if (c === 128) { t += c; b2compress(h, blk, t, false); c = 0; }
    blk[c++] = input[i];
  }
  t += c; while (c < 128) blk[c++] = 0;
  b2compress(h, blk, t, true);
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i++) out[i] = (h[i >> 2] >>> (8 * (i & 3))) & 255;
  return out;
}
export function toHex(bytes) { return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join(""); }

function gapCoefficients(g) {
  const n = g.n;
  const gsum = Array(n).fill(0);
  for (let i = 0; i < n; i++) for (let k = g.gptr[i]; k < g.gptr[i + 1]; k++) gsum[i] += g.gw[k];
  const out = [];
  for (let i = 0; i < n; i++) {
    for (let k = g.gptr[i]; k < g.gptr[i + 1]; k++) {
      const j = g.gcol[k];
      out.push(Math.floor(g.gw[k] * 2048 / Math.max(32, gsum[i], gsum[j])));
    }
  }
  return out;
}

export function buildView(doc) {
  const n = doc.n;
  const inhib = doc.cells.map((c) => c.sign === "inhibitory");
  const rows = Array.from({ length: n }, () => []);
  for (const [i, j, w] of doc.chem) rows[i].push([j, w]);
  const ptr = [0], col = [], w = [];
  for (const r of rows) { for (const [j, ww] of r) { col.push(j); w.push(ww); } ptr.push(col.length); }
  const grows = Array.from({ length: n }, () => []);
  for (const [a, b, ww] of doc.gap) { grows[a].push([b, ww]); grows[b].push([a, ww]); }
  const gptr = [0], gcol = [], gw = [];
  for (const r of grows) { for (const [j, ww] of r.sort((p, q) => p[0] - q[0])) { gcol.push(j); gw.push(ww); } gptr.push(gcol.length); }
  const graph = { n, inhib, ptr, col, w, gptr, gcol, gw };
  const nmjL = Array(n).fill(0), nmjR = Array(n).fill(0);
  for (const [i, muscle, ww] of doc.nmj) (String(muscle).startsWith("mul") ? nmjL : nmjR)[i] += ww;
  const gain = doc.cells.map((c) => doc.class_gain[c.class] ?? 1);
  return { doc, graph, pr1: doc.roles.pr1, pr2: doc.roles.pr2, ant: doc.roles.antenna, nmjL, nmjR, gain };
}

class Brain {
  constructor(graph) {
    const coef = gapCoefficients(graph);
    this.p = PARAMS;
    this.n = graph.n;
    this.inhib = graph.inhib;
    this.chem = Array.from({ length: this.n }, (_, i) => {
      const e = [];
      for (let k = graph.ptr[i]; k < graph.ptr[i + 1]; k++) e.push([graph.col[k], graph.w[k]]);
      return e;
    });
    this.gap = Array.from({ length: this.n }, (_, i) => {
      const e = [];
      for (let k = graph.gptr[i]; k < graph.gptr[i + 1]; k++) e.push([graph.gcol[k], coef[k]]);
      return e;
    });
    this.v = Array(this.n).fill(REST);
    this.a = Array(this.n).fill(0);
    this.spiked = Array(this.n).fill(false);
    this.spikes_total = 0;
  }
  step(order, drives, leak, theta) {
    const p = this.p, n = this.n, v = this.v;
    const exc = Array(n).fill(0), inh = Array(n).fill(0);
    for (let i = 0; i < n; i++) if (this.spiked[i]) {
      const tgt = this.inhib[i] ? inh : exc;
      for (const [j, w] of this.chem[i]) tgt[j] += w * p.w_scale;
    }
    for (let i = 0; i < n; i++) {
      const vi = v[i];
      for (const [j, c] of this.gap[i]) {
        const vj = v[j];
        if (vj > vi) exc[i] += shr((vj - vi) * c, p.gap_shift);
        else inh[i] += shr((vi - vj) * c, p.gap_shift);
      }
    }
    for (let s = 0; s < order.length; s++) exc[order[s]] += drives[s];
    const fired = [];
    for (let i = 0; i < n; i++) {
      let x = v[i];
      const shift = leak ? leak[i] : p.leak_shift;
      x = x > REST ? x - shr(x - REST, shift) : x + shr(REST - x, shift);
      x += exc[i];
      x = x > inh[i] ? x - inh[i] : 0;
      if (x < p.v_floor) x = p.v_floor;
      if (x > p.v_ceil) x = p.v_ceil;
      let a = this.a[i];
      a -= shr(a, p.adapt_shift);
      const extra = theta ? theta[i] : 0;
      const f = x >= p.thresh + a + extra;
      if (f) {
        x = p.reset;
        a += p.adapt_inc;
        if (a > 65535) a = 65535;
        fired.push(i);
        this.spikes_total++;
      }
      v[i] = x; this.a[i] = a; this.spiked[i] = f;
    }
    return fired;
  }
}

function groupOf(name) { return name === "unassigned" ? 15 : GROUP[name]; }
export function decodeGenome(bytes) {
  if (bytes.length !== 64) throw new Error("genome must be 64 bytes");
  const theta = [], leaks = [], gains = [], lr = [];
  for (let i = 0; i < 16; i++) {
    const b = bytes[i];
    let mag = b >= 128 ? Math.floor((b - 128) * 1966 / 128) : Math.floor((128 - b) * 1966 / 128);
    if (mag > 1966) mag = 1966;
    theta.push(b >= 128 ? 4096 + mag : 4096 - mag);
  }
  for (let i = 16; i < 24; i++) leaks.push(2 + (bytes[i] >> 6));
  for (let i = 24; i < 32; i++) gains.push(500 + Math.floor(bytes[i] * 1500 / 255));
  for (let i = 32; i < 36; i++) {
    const b = bytes[i];
    let mag = b >= 128 ? Math.floor((b - 128) * 100 / 128) : Math.floor((128 - b) * 100 / 128);
    if (mag > 100) mag = 100;
    lr.push(b >= 128 ? 100 + mag : 100 - mag);
  }
  const centered = (base, b, scale, lo, hi) => {
    const v = b >= 128 ? base + (b - 128) * scale : (base > (128 - b) * scale ? base - (128 - b) * scale : 0);
    return Math.min(hi, Math.max(lo, v));
  };
  return { theta, leaks, gains, lr, yolk0: centered(100000, bytes[36], 200, 80000, 120000) };
}
function physiology(view, decoded) {
  const leak = [], theta = [];
  for (const cell of view.doc.cells) {
    const g = groupOf(cell.class);
    leak.push(decoded.leaks[g % 8]);
    theta.push(decoded.theta[g] - 4096);
  }
  return [leak, theta];
}
function applyLr(left, right, lr) {
  let fl, fr;
  if (lr >= 100) {
    const d = (lr - 100) * 10;
    fl = 1000 + d; fr = 1000 >= d ? 1000 - d : 0;
  } else {
    const d = (100 - lr) * 10;
    fl = 1000 >= d ? 1000 - d : 0; fr = 1000 + d;
  }
  return [Math.floor(left * fl / 1000), Math.floor(right * fr / 1000)];
}

function sensorDrives(body, view, lure, light, shadow, gains) {
  const dx = lure[0] - body.x, dy = lure[1] - body.y;
  const dist2 = dx * dx + dy * dy;
  const dist = isqrt(dist2);
  let intensity = Math.floor(CONST.drive * CONST.near2 / (CONST.near2 + dist2));
  intensity = Math.floor(intensity * light / 256);
  const [s, c] = sinCos(body.heading);
  let dot = dist ? floorDiv(c * dx + s * dy, dist) : 256;
  if (dot > 256) dot = 256;
  if (dot < -256) dot = -256;
  let shade = CONST.shade_floor + Math.floor(CONST.shade_span * Math.max(dot, 0) / 256);
  if (shadow) shade = Math.floor(shade / CONST.shadow_div);
  const clamp = (d) => d < 0 ? 0 : d > CONST.drive_cap ? CONST.drive_cap : d;
  const drives = [];
  view.pr1.forEach((idx, k) => {
    const jit = 780 + Math.floor(440 * ((k * 7919) % 23) / 22);
    let d = Math.floor(intensity * shade * jit / (256 * 1000)) * view.gain[idx];
    if (gains) d = Math.floor(d * gains[0] / 1000);
    drives.push(clamp(d));
  });
  let up = (CONST.ant_tonic + Math.floor(CONST.ant_gain * Math.max(body.tilt, 0) / 256)) * view.gain[view.ant[0]];
  let dn = (CONST.ant_tonic + Math.floor(CONST.ant_gain * Math.max(-body.tilt, 0) / 256)) * view.gain[view.ant[1]];
  if (gains) { up = Math.floor(up * gains[2] / 1000); dn = Math.floor(dn * gains[2] / 1000); }
  drives.push(clamp(up), clamp(dn));
  let pr2 = shadow ? CONST.pr2_drive : 0;
  if (gains) pr2 = Math.floor(pr2 * gains[1] / 1000);
  for (const idx of view.pr2) drives.push(clamp(pr2 * view.gain[idx]));
  return drives;
}
function digestOf(drives) {
  let dig = 0;
  for (let i = 0; i < drives.length; i++) dig = (dig + drives[i] * (i + 1)) >>> 0;
  return dig;
}
function hashTick(prev, tick, drives, fired, n) {
  const raw = new Uint8Array(32 + 8 + 4 + Math.floor((n + 7) / 8));
  raw.set(prev, 0);
  for (let i = 0; i < 8; i++) raw[32 + i] = Math.floor(tick / 2 ** (8 * i)) & 255;
  const dig = digestOf(drives);
  for (let i = 0; i < 4; i++) raw[40 + i] = (dig >>> (8 * i)) & 255;
  for (const i of fired) raw[44 + (i >> 3)] |= 1 << (i & 7);
  return blake2b256(raw);
}

function fresh(view, yolk0) {
  return [{
    x: 0, y: 0, heading: 0, tilt: 0, yolk: yolk0 ?? CONST.yolk0,
    bout: 0, escape: 0, escapeCd: 0, pr2Hist: [], hash: new Uint8Array(32),
  }, new Brain(view.graph)];
}

export function stepLarva(body, brain, view, lure, light, shadow, pulse, decoded) {
  const gains = decoded ? decoded.gains : null;
  const [leak, theta] = decoded ? physiology(view, decoded) : [null, null];
  const drives = sensorDrives(body, view, lure, light, shadow, gains);
  const order = view.pr1.concat(view.ant, view.pr2);
  const fired = brain.step(order, drives, leak, theta);
  const firedSet = new Set(fired);
  let left = 0, right = 0;
  for (const i of fired) { left += view.nmjL[i]; right += view.nmjR[i]; }
  if (decoded) [left, right] = applyLr(left, right, decoded.lr[0]);
  let pr1n = 0, pr2n = 0;
  for (const i of view.pr1) if (firedSet.has(i)) pr1n++;
  for (const i of view.pr2) if (firedSet.has(i)) pr2n++;
  const ant1 = firedSet.has(view.ant[0]), ant2 = firedSet.has(view.ant[1]);
  const c = CONST;
  if (left + right > 0) body.bout = c.bout_bridge;
  else if (body.bout > 0) body.bout--;
  const vigor = body.bout > 0;
  body.pr2Hist.push(pr2n);
  if (body.pr2Hist.length > c.pr2_window) body.pr2Hist.shift();
  if (body.escapeCd > 0) body.escapeCd--;
  else if (body.escape === 0 && body.pr2Hist.reduce((s, v) => s + v, 0) >= c.pr2_trigger) {
    body.escape = c.escape_ticks; body.escapeCd = c.escape_cooldown;
  }
  if (pr1n && light) {
    const bearing = atan2u16(lure[1] - body.y, lure[0] - body.x);
    const err = angDiff(body.heading, bearing);
    let mag = Math.min(Math.abs(err), pr1n * c.pr1_turn);
    if (err < 0) mag = -mag;
    body.heading = (body.heading + mag) & 65535;
  }
  if (vigor) {
    let yaw = floorDiv(right - left, c.yaw_div);
    if (yaw > c.yaw_cap) yaw = c.yaw_cap;
    if (yaw < -c.yaw_cap) yaw = -c.yaw_cap;
    body.heading = (body.heading + yaw) & 65535;
  }
  if (ant1 && !ant2) body.tilt -= c.tilt_step;
  else if (ant2 && !ant1) body.tilt += c.tilt_step;
  if (body.tilt > c.tilt_cap) body.tilt = c.tilt_cap;
  if (body.tilt < -c.tilt_cap) body.tilt = -c.tilt_cap;
  let thrust = 0;
  const escaping = body.escape > 0;
  if (vigor) thrust = c.thrust_base + Math.floor((left + right) / c.thrust_div);
  if (escaping) { thrust += c.escape_thrust; body.escape--; }
  const [s, cos] = sinCos(body.heading);
  body.x += floorDiv(thrust * cos, 256);
  body.y += floorDiv(thrust * s, 256);
  let burn = c.burn_idle;
  if (vigor) burn += c.burn_bout;
  if (pulse) burn += c.burn_pulse;
  if (escaping) burn += c.burn_escape;
  body.yolk = body.yolk > burn ? body.yolk - burn : 0;
  const tick = (body.tick = (body.tick || 0) + 1);
  body.hash = hashTick(body.hash, tick, drives, fired, view.graph.n);
}

export function bytesOf(value) {
  if (typeof value === "string") {
    if (value.startsWith("0x")) return Uint8Array.from(value.slice(2).match(/../g), (h) => parseInt(h, 16));
    const bin = atob(value);
    return Uint8Array.from(bin, (ch) => ch.charCodeAt(0));
  }
  return Uint8Array.from(value, (n) => n & 255);
}

// Walk the chain events. On a hash mismatch, stop. The larva stays at the last tick that matched.
export function follow(doc, events) {
  const view = buildView(doc);
  const hatch = events.find((e) => e.genome && e.tick == null);
  const decoded = decodeGenome(bytesOf(hatch.genome));
  const [body, brain] = fresh(view, decoded.yolk0);
  const frames = [];
  const ticks = events.filter((e) => e.lure_x != null && e.tick != null);
  for (const e of ticks) {
    const before = { x: body.x, y: body.y, heading: body.heading, yolk: body.yolk, hash: toHex(body.hash) };
    stepLarva(body, brain, view, [Number(e.lure_x), Number(e.lure_y)], Number(e.light), Boolean(e.shadow), Boolean(e.pulse), decoded);
    const hash = toHex(body.hash);
    const chain = toHex(bytesOf(e.state_hash));
    if (hash !== chain || body.x + 1000000 !== Number(e.x) || (body.tick || 0) !== Number(e.tick)) {
      const larva = frames.at(-1) ?? { tick: 0, x: 0, y: 0, heading: 0, yolk: decoded.yolk0, hash: toHex(new Uint8Array(32)) };
      return { ok: false, stoppedAt: Number(e.tick), frames, larva };
    }
    frames.push(frameOf(body, hash));
  }
  const larva = frames.at(-1) ?? { tick: 0, x: 0, y: 0, heading: 0, yolk: decoded.yolk0, hash: toHex(new Uint8Array(32)) };
  return { ok: true, stoppedAt: null, frames, larva };
}

function frameOf(body, hash) {
  return { tick: body.tick || 0, x: body.x, y: body.y, heading: body.heading, yolk: body.yolk, hash };
}

export const REEF = {
  grid: 16,
  span: 400,
  radius: 250,
  competenceTicks: 1200,
  competenceMs: 20 * 60 * 1000,
};

export function cellCenter(cell) {
  const g = REEF.grid;
  const span = REEF.span;
  const x = (cell % g) * span + span / 2;
  const y = Math.floor(cell / g) * span + span / 2;
  return [x, y];
}

// Same test as Ciona::claim: within claim_radius of a cell center, competent, and the cell is free.
export function decideClaim(larva, occupied, bornMs = 0, nowMs = 0) {
  const tick = larva?.tick ?? 0;
  if (tick < REEF.competenceTicks) {
    return { ok: false, cell: null, reason: `Needs ${REEF.competenceTicks} ticks before a cell can be claimed. This larva has ${tick}.` };
  }
  if (nowMs < bornMs + REEF.competenceMs) {
    return { ok: false, cell: null, reason: "The competence clock has not finished." };
  }
  const x = larva.x, y = larva.y;
  const limit = REEF.radius * REEF.radius;
  let best = null;
  for (let cell = 0; cell < REEF.grid * REEF.grid; cell++) {
    const [cx, cy] = cellCenter(cell);
    const d2 = (x - cx) ** 2 + (y - cy) ** 2;
    if (d2 <= limit && (best == null || d2 < best.d2)) best = { cell, d2 };
  }
  if (!best) return { ok: false, cell: null, reason: "Not within 250 of a reef cell." };
  if (occupied.has(best.cell)) return { ok: false, cell: best.cell, reason: `Cell ${best.cell} is already taken.` };
  return { ok: true, cell: best.cell, reason: `Claim cell ${best.cell}.` };
}

export function statusText(result) {
  if (!result) return "No larva loaded.";
  if (result.stoppedAt != null) {
    return `Stopped at tick ${result.stoppedAt}. The predicted hash does not match the chain. The larva was not moved past the last matching tick.`;
  }
  const t = result.larva ? result.larva.tick : 0;
  return `Following the chain through tick ${t}.`;
}
