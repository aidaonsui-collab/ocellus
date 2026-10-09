/// On-chain Ciona larval brain. Integer step, sensors, and body update.
/// The reference is bench/scripts/dynamics.py and bench/scripts/lif_model.py.
/// Trig tables live in trig.move and are generated from those same constants.
///
/// `measure_seizure` exists so a localnet run can price an all-spiking tick.
/// It aborts when SEIZURE_HOOK is false. Turn that off before the package is
/// made immutable.
module ocellus_brain::brain;

use ocellus_brain::trig;
use sui::hash;
use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::TxContext;

const SEIZURE_HOOK: bool = false;

const REST: u64 = 1048576;
const THRESH: u64 = 1048576 + 16384;
const RESET: u32 = 1048576 - 4096;
const V_FLOOR: u64 = 1048576 - 16384;
const V_CEIL: u64 = 1048576 + 65536;
const W_SCALE: u64 = 320;
const GAP_SHIFT: u8 = 12;
const ADAPT_INC: u32 = 8192;
const ADAPT_SHIFT: u8 = 4;

const POS_BIAS: u64 = 1000000;
const TILT_BIAS: u32 = 1024;
const THETA_BIAS: u64 = 4096;

const DRIVE: u64 = 8000;
const NEAR2: u64 = 4000 * 4000;
const SHADE_FLOOR: u64 = 64;
const SHADE_SPAN: u64 = 192;
const SHADOW_DIV: u64 = 4;
const ANT_TONIC: u64 = 1500;
const ANT_GAIN: u64 = 6400;
const PR2_DRIVE: u64 = 12000;
const PR2_WINDOW: u64 = 6;
const PR2_TRIGGER: u64 = 3;
const ESCAPE_TICKS: u16 = 8;
const ESCAPE_COOLDOWN: u16 = 40;
const ESCAPE_THRUST: u64 = 250;
const BOUT_BRIDGE: u16 = 3;
const THRUST_BASE: u64 = 40;
const THRUST_DIV: u64 = 100;
const YAW_DIV: u64 = 800;
const YAW_CAP: u64 = 400;
const PR1_TURN: u64 = 180;
const TILT_STEP: u32 = 40;
const TILT_CAP: u32 = 512;
const DEPTH_BIAS: u32 = 1024;
const DEPTH_STEP: u32 = 40;
const DEPTH_CAP: u32 = 512;
const BURN_IDLE: u64 = 12;
const BURN_BOUT: u64 = 26;
const BURN_PULSE: u64 = 18;
const BURN_ESCAPE: u64 = 20;
const DRIVE_CAP: u64 = 20000;

const G_PR1: u8 = 0;
const G_PR2: u8 = 1;
const G_ANT: u8 = 2;

const E_LEN: u64 = 1;
const E_LIGHT: u64 = 2;
const E_HOOK: u64 = 3;
const E_RANGE: u64 = 4;

public struct PublisherCap has key, store { id: UID }

public struct Connectome has key, store {
    id: UID,
    version: u16,
    n: u16,
    row_ptr: vector<u16>,
    col: vector<u8>,
    w: vector<u16>,
    inhib: vector<bool>,
    gap_ptr: vector<u16>,
    gap_col: vector<u8>,
    gap_w: vector<u16>,
    nmj_l: vector<u16>,
    nmj_r: vector<u16>,
    class_group: vector<u8>,
    pr1: vector<u8>,
    pr2: vector<u8>,
    antenna: vector<u8>,
    data_hash: vector<u8>,
}

public struct Brain has store, drop {
    v: vector<u32>,
    adapt: vector<u16>,
    spiked: vector<u64>,
    tick: u64,
    spikes_total: u64,
    state_hash: vector<u8>,
}

public struct Body has store, drop {
    x: u64,
    y: u64,
    heading: u16,
    tilt: u32,
    yolk: u64,
    bout: u16,
    escape: u16,
    escape_cd: u16,
    pr2_hist: vector<u8>,
    escape_thrust: u64,
    depth: u32,
}

/// One larva. The connectome stays a separate frozen object.
public struct Larva has key, store {
    id: UID,
    brain: Brain,
    body: Body,
}

/// Physiology decoded from a 64-byte genome. Baseline matches dynamics.py.
public struct Params has drop, store {
    theta: vector<u64>,
    leaks: vector<u8>,
    gains: vector<u64>,
    lr: vector<u64>,
    yolk0: u64,
    competence: u64,
}

public struct S has copy, drop { neg: bool, mag: u64 }

fun init(ctx: &mut TxContext) {
    transfer::public_transfer(PublisherCap { id: object::new(ctx) }, ctx.sender());
}

fun build_connectome(
    n: u16,
    row_ptr: vector<u16>,
    col: vector<u8>,
    w: vector<u16>,
    inhib: vector<bool>,
    gap_ptr: vector<u16>,
    gap_col: vector<u8>,
    gap_w: vector<u16>,
    nmj_l: vector<u16>,
    nmj_r: vector<u16>,
    class_group: vector<u8>,
    data_hash: vector<u8>,
    ctx: &mut TxContext,
): Connectome {
    let nn = n as u64;
    assert!(row_ptr.length() == nn + 1, E_LEN);
    assert!(inhib.length() == nn, E_LEN);
    assert!(nmj_l.length() == nn && nmj_r.length() == nn, E_LEN);
    assert!(class_group.length() == nn, E_LEN);
    assert!(data_hash.length() == 32, E_LEN);
    assert!(gap_ptr.length() == nn + 1, E_LEN);
    let pr1 = collect_group(&class_group, G_PR1);
    let pr2 = collect_group(&class_group, G_PR2);
    let antenna = collect_group(&class_group, G_ANT);
    assert!(pr1.length() == 23 && pr2.length() == 7 && antenna.length() == 2, E_LEN);
    Connectome {
        id: object::new(ctx),
        version: 1,
        n,
        row_ptr,
        col,
        w,
        inhib,
        gap_ptr,
        gap_col,
        gap_w,
        nmj_l,
        nmj_r,
        class_group,
        pr1,
        pr2,
        antenna,
        data_hash,
    }
}

fun collect_group(class_group: &vector<u8>, g: u8): vector<u8> {
    let mut out = vector[];
    let mut i = 0;
    while (i < class_group.length()) {
        if (class_group[i] == g) out.push_back((i as u8));
        i = i + 1;
    };
    out
}

public fun baseline_params(): Params {
    let g = neutral_genome();
    decode(&g)
}

fun neutral_genome(): vector<u8> {
    let mut g = vector[];
    let mut i = 0;
    while (i < 64) {
        let b = if (i < 16) 128u8
            else if (i < 24) 64
            else if (i < 32) 85
            else if (i < 38) 128
            else 0;
        g.push_back(b);
        i = i + 1;
    };
    g
}

public fun decode(g: &vector<u8>): Params {
    assert!(g.length() == 64, E_LEN);
    let mut theta = vector[];
    let mut i = 0;
    while (i < 16) {
        let b = g[i] as u64;
        let raw = if (b >= 128) (b - 128) * 1966 / 128 else (128 - b) * 1966 / 128;
        let mag = if (raw > 1966) 1966 else raw;
        theta.push_back(if (b >= 128) THETA_BIAS + mag else THETA_BIAS - mag);
        i = i + 1;
    };
    let mut leaks = vector[];
    while (i < 24) {
        leaks.push_back(2 + (g[i] >> 6));
        i = i + 1;
    };
    let mut gains = vector[];
    while (i < 32) {
        gains.push_back(500 + (g[i] as u64) * 1500 / 255);
        i = i + 1;
    };
    let mut lr = vector[];
    while (i < 36) {
        let b = g[i] as u64;
        let raw = if (b >= 128) (b - 128) * 100 / 128 else (128 - b) * 100 / 128;
        let mag = if (raw > 100) 100 else raw;
        lr.push_back(if (b >= 128) 100 + mag else 100 - mag);
        i = i + 1;
    };
    let yolk0 = centered(100000, g[36], 200, 80000, 120000);
    let competence = centered(1200, g[37], 4, 800, 1600);
    Params { theta, leaks, gains, lr, yolk0, competence }
}

fun centered(base: u64, b: u8, scale: u64, lo: u64, hi: u64): u64 {
    let b = b as u64;
    let v = if (b >= 128) base + (b - 128) * scale
        else {
            let dec = (128 - b) * scale;
            if (base > dec) base - dec else 0
        };
    clamp_u64(v, lo, hi)
}

fun clamp_u64(v: u64, lo: u64, hi: u64): u64 {
    if (v < lo) lo else if (v > hi) hi else v
}

fun new_brain(n: u64): Brain {
    let mut spiked = vector[];
    let mut k = 0;
    while (k < 4) { spiked.push_back(0u64); k = k + 1; };
    let mut state_hash = vector[];
    k = 0;
    while (k < 32) { state_hash.push_back(0u8); k = k + 1; };
    Brain {
        v: vector::tabulate!(n, |_| REST as u32),
        adapt: vector::tabulate!(n, |_| 0u16),
        spiked,
        tick: 0,
        spikes_total: 0,
        state_hash,
    }
}

fun new_body(yolk0: u64): Body {
    Body {
        x: POS_BIAS,
        y: POS_BIAS,
        heading: 0,
        tilt: TILT_BIAS,
        yolk: yolk0,
        bout: 0,
        escape: 0,
        escape_cd: 0,
        pr2_hist: vector[],
        escape_thrust: 0,
        depth: DEPTH_BIAS,
    }
}

public fun new_larva(c: &Connectome, p: &Params, ctx: &mut TxContext): Larva {
    Larva {
        id: object::new(ctx),
        brain: new_brain(c.n as u64),
        body: new_body(p.yolk0),
    }
}

public fun create_and_freeze(
    cap: PublisherCap,
    n: u16,
    row_ptr: vector<u16>,
    col: vector<u8>,
    w: vector<u16>,
    inhib: vector<bool>,
    gap_ptr: vector<u16>,
    gap_col: vector<u8>,
    gap_w: vector<u16>,
    nmj_l: vector<u16>,
    nmj_r: vector<u16>,
    class_group: vector<u8>,
    data_hash: vector<u8>,
    ctx: &mut TxContext,
): Connectome {
    let c = build_connectome(
        n, row_ptr, col, w, inhib, gap_ptr, gap_col, gap_w, nmj_l, nmj_r, class_group, data_hash, ctx,
    );
    let PublisherCap { id } = cap;
    object::delete(id);
    c
}

entry fun create_frozen(
    cap: PublisherCap,
    n: u16,
    row_ptr: vector<u16>,
    col: vector<u8>,
    w: vector<u16>,
    inhib: vector<bool>,
    gap_ptr: vector<u16>,
    gap_col: vector<u8>,
    gap_w: vector<u16>,
    nmj_l: vector<u16>,
    nmj_r: vector<u16>,
    class_group: vector<u8>,
    data_hash: vector<u8>,
    ctx: &mut TxContext,
) {
    let c = create_and_freeze(
        cap, n, row_ptr, col, w, inhib, gap_ptr, gap_col, gap_w, nmj_l, nmj_r, class_group, data_hash, ctx,
    );
    let p = baseline_params();
    let larva = new_larva(&c, &p, ctx);
    transfer::public_freeze_object(c);
    transfer::public_transfer(larva, ctx.sender());
}

entry fun tick_baseline(
    c: &Connectome,
    larva: &mut Larva,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
) {
    let p = baseline_params();
    tick(c, larva, &p, lure_x, lure_y, light, shadow, pulse);
}

entry fun measure_seizure(
    c: &Connectome,
    larva: &mut Larva,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
) {
    assert!(SEIZURE_HOOK, E_HOOK);
    let p = baseline_params();
    let _d = tick_inner(c, &mut larva.brain, &mut larva.body, &p, lure_x, lure_y, light, shadow, pulse, 0, true);
}

public fun tick(
    c: &Connectome,
    larva: &mut Larva,
    p: &Params,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
) {
    let _d = tick_inner(c, &mut larva.brain, &mut larva.body, p, lure_x, lure_y, light, shadow, pulse, 0, false);
}

public fun new_state(c: &Connectome, p: &Params): (Brain, Body) {
    (new_brain(c.n as u64), new_body(p.yolk0))
}

public fun tick_state(
    c: &Connectome,
    brain: &mut Brain,
    body: &mut Body,
    p: &Params,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
): u32 {
    tick_current(c, brain, body, p, lure_x, lure_y, light, shadow, pulse, 0)
}

public fun tick_current(
    c: &Connectome,
    brain: &mut Brain,
    body: &mut Body,
    p: &Params,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
    current: u64,
): u32 {
    tick_inner(c, brain, body, p, lure_x, lure_y, light, shadow, pulse, current, false)
}

/// A zero seed adds nothing, so the published course is unchanged.
public fun drift(seed: u64, x: u64, y: u64): (u64, u64) {
    if (seed == 0) (0, 0)
    else {
        let dx = ((seed + (x % 997)) % 5) + 1;
        let dy = (seed + (y % 991)) % 3;
        (dx, dy)
    }
}

fun tick_inner(
    c: &Connectome,
    brain: &mut Brain,
    body: &mut Body,
    p: &Params,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
    current: u64,
    force_all: bool,
): u32 {
    assert!(light <= 256, E_LIGHT);
    let n = c.n as u64;
    let mut exc = vector::tabulate!(n, |_| 0u64);
    let mut inh = vector::tabulate!(n, |_| 0u64);
    let mut i = 0;
    while (i < n) {
        if (force_all || bit_on(&brain.spiked, i)) {
            let lo = c.row_ptr[i] as u64;
            let hi = c.row_ptr[i + 1] as u64;
            let neg = c.inhib[i];
            let mut k = lo;
            while (k < hi) {
                let j = c.col[k] as u64;
                let dw = (c.w[k] as u64) * W_SCALE;
                if (neg) { *&mut inh[j] = inh[j] + dw } else { *&mut exc[j] = exc[j] + dw };
                k = k + 1;
            };
        };
        i = i + 1;
    };
    i = 0;
    while (i < n) {
        let lo = c.gap_ptr[i] as u64;
        let hi = c.gap_ptr[i + 1] as u64;
        let vi = brain.v[i] as u64;
        let mut k = lo;
        while (k < hi) {
            let j = c.gap_col[k] as u64;
            let vj = brain.v[j] as u64;
            let g = c.gap_w[k] as u64;
            if (vj > vi) {
                *&mut exc[i] = exc[i] + (((vj - vi) * g) >> GAP_SHIFT);
            } else {
                *&mut inh[i] = inh[i] + (((vi - vj) * g) >> GAP_SHIFT);
            };
            k = k + 1;
        };
        i = i + 1;
    };

    let drives = sensor_drives(c, body, p, lure_x, lure_y, light, shadow);
    let order = sensor_order(c);
    let mut s = 0;
    while (s < order.length()) {
        let j = order[s] as u64;
        *&mut exc[j] = exc[j] + (drives[s] as u64);
        s = s + 1;
    };

    let mut bits = vector[0u64, 0u64, 0u64, 0u64];
    let mut left = 0u64;
    let mut right = 0u64;
    let mut pr1_n = 0u64;
    let mut pr2_n = 0u64;
    let mut ant1 = false;
    let mut ant2 = false;
    let ant0 = c.antenna[0] as u64;
    let ant1_id = c.antenna[1] as u64;
    let lr = p.lr[0];
    let (factor_l, factor_r) = if (lr >= 100) {
        let d = (lr - 100) * 10;
        (1000 + d, if (1000 >= d) 1000 - d else 0)
    } else {
        let d = (100 - lr) * 10;
        (if (1000 >= d) 1000 - d else 0, 1000 + d)
    };
    i = 0;
    while (i < n) {
        let mut x = brain.v[i] as u64;
        let shift = p.leaks[(c.class_group[i] % 8) as u64];
        if (x > REST) { x = x - ((x - REST) >> shift) } else { x = x + ((REST - x) >> shift) };
        x = x + exc[i];
        x = if (x > inh[i]) { x - inh[i] } else { 0 };
        if (x < V_FLOOR) x = V_FLOOR;
        if (x > V_CEIL) x = V_CEIL;
        let mut a = brain.adapt[i] as u32;
        a = a - (a >> ADAPT_SHIFT);
        let th = p.theta[c.class_group[i] as u64];
        let mut base = THRESH + (a as u64);
        if (th >= THETA_BIAS) { base = base + (th - THETA_BIAS) } else { base = base - (THETA_BIAS - th) };
        let fired = x >= base;
        if (fired) {
            x = RESET as u64;
            let sum = a + ADAPT_INC;
            a = if (sum > 65535) 65535 else sum;
            brain.spikes_total = brain.spikes_total + 1;
            let word = i / 64;
            let sh = ((i % 64) as u8);
            *&mut bits[word] = bits[word] | (1u64 << sh);
            left = left + (c.nmj_l[i] as u64);
            right = right + (c.nmj_r[i] as u64);
            let g = c.class_group[i];
            if (g == G_PR1) pr1_n = pr1_n + 1;
            if (g == G_PR2) pr2_n = pr2_n + 1;
            if (i == ant0) ant1 = true;
            if (i == ant1_id) ant2 = true;
        };
        *&mut brain.v[i] = x as u32;
        *&mut brain.adapt[i] = a as u16;
        i = i + 1;
    };
    brain.spiked = bits;
    brain.tick = brain.tick + 1;

    let left = left * factor_l / 1000;
    let right = right * factor_r / 1000;
    integrate(body, lure_x, lure_y, light, shadow, pulse, left, right, pr1_n, pr2_n, ant1, ant2);
    let (dx, dy) = drift(current, body.x, body.y);
    body.x = body.x + dx;
    body.y = body.y + dy;

    let prev = copy_bytes(&brain.state_hash);
    let digest = digest_of(&drives);
    brain.state_hash = hash_tick(&prev, brain.tick, digest, &bits, n);
    digest
}

fun sensor_drives(
    c: &Connectome,
    body: &Body,
    p: &Params,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
): vector<u32> {
    let dx = delta(lure_x, body.x);
    let dy = delta(lure_y, body.y);
    let dist2 = dx.mag * dx.mag + dy.mag * dy.mag;
    let dist = isqrt_u64(dist2);
    let mut intensity = DRIVE * NEAR2 / (NEAR2 + dist2);
    intensity = intensity * (light as u64) / 256;
    let (s, cos) = sin_cos(body.heading);
    let shade = if (dist == 0) {
        SHADE_FLOOR + SHADE_SPAN
    } else {
        let dot = s_floor_div(s_add(s_mul(cos, dx), s_mul(s, dy)), dist);
        if (dot.neg) SHADE_FLOOR
        else {
            let d = if (dot.mag > 256) 256 else dot.mag;
            SHADE_FLOOR + SHADE_SPAN * d / 256
        }
    };
    let shade = if (shadow) shade / SHADOW_DIV else shade;
    let pr1 = &c.pr1;
    let pr2 = &c.pr2;
    let mut drives = vector[];
    let mut k = 0;
    while (k < pr1.length()) {
        let jit = 780 + 440 * (((k * 7919) % 23) as u64) / 22;
        let d = intensity * shade * jit / (256 * 1000) * p.gains[0] / 1000;
        drives.push_back(cap_drive(d));
        k = k + 1;
    };
    let tilt = body.tilt;
    let up = if (tilt > TILT_BIAS) ((tilt - TILT_BIAS) as u64) else 0;
    let dn = if (tilt < TILT_BIAS) ((TILT_BIAS - tilt) as u64) else 0;
    let g = p.gains[2];
    drives.push_back(cap_drive((ANT_TONIC + ANT_GAIN * up / 256) * g / 1000));
    drives.push_back(cap_drive((ANT_TONIC + ANT_GAIN * dn / 256) * g / 1000));
    let pr2_d = if (shadow) PR2_DRIVE else 0;
    k = 0;
    while (k < pr2.length()) {
        drives.push_back(cap_drive(pr2_d * p.gains[1] / 1000));
        k = k + 1;
    };
    drives
}

fun cap_drive(d: u64): u32 {
    let d = if (d > DRIVE_CAP) DRIVE_CAP else d;
    d as u32
}

fun sensor_order(c: &Connectome): vector<u8> {
    let mut o = vector[];
    let mut i = 0;
    while (i < c.pr1.length()) { o.push_back(c.pr1[i]); i = i + 1; };
    i = 0;
    while (i < c.antenna.length()) { o.push_back(c.antenna[i]); i = i + 1; };
    i = 0;
    while (i < c.pr2.length()) { o.push_back(c.pr2[i]); i = i + 1; };
    o
}

fun integrate(
    body: &mut Body,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
    left: u64,
    right: u64,
    pr1_n: u64,
    pr2_n: u64,
    ant1: bool,
    ant2: bool,
) {
    if (left + right > 0) body.bout = BOUT_BRIDGE
    else if (body.bout > 0) body.bout = body.bout - 1;
    let vigor = body.bout > 0;

    body.pr2_hist.push_back((pr2_n as u8));
    if (body.pr2_hist.length() > PR2_WINDOW) {
        let _old = vector::remove(&mut body.pr2_hist, 0);
    };
    if (body.escape_cd > 0) body.escape_cd = body.escape_cd - 1
    else if (body.escape == 0 && sum_hist(&body.pr2_hist) >= PR2_TRIGGER) {
        body.escape = ESCAPE_TICKS;
        body.escape_cd = ESCAPE_COOLDOWN;
    };

    if (pr1_n > 0 && light > 0) {
        let bearing = atan2_s(delta(lure_y, body.y), delta(lure_x, body.x));
        let err = ang_diff(body.heading, bearing);
        let cap = pr1_n * PR1_TURN;
        let mag = if (err.mag < cap) err.mag else cap;
        body.heading = add_heading(body.heading, err.neg, mag);
    };
    if (vigor) {
        let yaw = if (right >= left) {
            S { neg: false, mag: (right - left) / YAW_DIV }
        } else {
            S { neg: true, mag: ceil_div(left - right, YAW_DIV) }
        };
        let mag = if (yaw.mag > YAW_CAP) YAW_CAP else yaw.mag;
        body.heading = add_heading(body.heading, yaw.neg, mag);
    };

    // Depth is a game rule on the existing tilt. Dimming opens it. It is not a motor readout,
    // and it is not hashed: the next tick's sensors do not read it.
    if (light == 0 || shadow) {
        let hi = DEPTH_BIAS + DEPTH_CAP;
        let lo = DEPTH_BIAS - DEPTH_CAP;
        if (body.tilt > TILT_BIAS && body.depth < hi) {
            let room = hi - body.depth;
            let step = if (DEPTH_STEP < room) DEPTH_STEP else room;
            body.depth = body.depth + step;
        } else if (body.tilt < TILT_BIAS && body.depth > lo) {
            let room = body.depth - lo;
            let step = if (DEPTH_STEP < room) DEPTH_STEP else room;
            body.depth = body.depth - step;
        };
    };
    if (ant1 && !ant2) {
        if (body.tilt >= TILT_STEP) body.tilt = body.tilt - TILT_STEP;
    } else if (ant2 && !ant1) {
        body.tilt = body.tilt + TILT_STEP;
    };
    let hi = TILT_BIAS + TILT_CAP;
    let lo = TILT_BIAS - TILT_CAP;
    if (body.tilt > hi) body.tilt = hi;
    if (body.tilt < lo) body.tilt = lo;

    let mut thrust = 0u64;
    let escaping = body.escape > 0;
    if (vigor) thrust = THRUST_BASE + (left + right) / THRUST_DIV;
    if (escaping) {
        thrust = thrust + ESCAPE_THRUST;
        body.escape = body.escape - 1;
        body.escape_thrust = body.escape_thrust + ESCAPE_THRUST;
    };
    let (s, cos) = sin_cos(body.heading);
    body.x = add_scaled(body.x, thrust, cos);
    body.y = add_scaled(body.y, thrust, s);

    let mut burn = BURN_IDLE;
    if (vigor) burn = burn + BURN_BOUT;
    if (pulse) burn = burn + BURN_PULSE;
    if (escaping) burn = burn + BURN_ESCAPE;
    body.yolk = if (body.yolk > burn) body.yolk - burn else 0;
}

fun sum_hist(h: &vector<u8>): u64 {
    let mut t = 0u64;
    let mut i = 0;
    while (i < h.length()) { t = t + (h[i] as u64); i = i + 1; };
    t
}

fun digest_of(drives: &vector<u32>): u32 {
    let mut dig = 0u64;
    let mut i = 0;
    while (i < drives.length()) {
        dig = (dig + (drives[i] as u64) * (i + 1)) & 0xFFFFFFFF;
        i = i + 1;
    };
    (dig as u32)
}

fun hash_tick(prev: &vector<u8>, tick: u64, digest: u32, bits: &vector<u64>, n: u64): vector<u8> {
    let mut raw = vector[];
    let mut i = 0;
    while (i < 32) { raw.push_back(prev[i]); i = i + 1; };
    i = 0;
    while (i < 8) { raw.push_back((((tick >> ((i * 8) as u8)) & 0xff) as u8)); i = i + 1; };
    i = 0;
    let d = digest as u64;
    while (i < 4) { raw.push_back((((d >> ((i * 8) as u8)) & 0xff) as u8)); i = i + 1; };
    let nbytes = (n + 7) / 8;
    i = 0;
    while (i < nbytes) {
        let word = bits[i / 8];
        let shift = (((i % 8) * 8) as u8);
        raw.push_back((((word >> shift) & 0xff) as u8));
        i = i + 1;
    };
    hash::blake2b256(&raw)
}

fun bit_on(bits: &vector<u64>, i: u64): bool {
    let w = bits[i / 64];
    ((w >> ((i % 64) as u8)) & 1) == 1
}

public(package) fun isqrt_u64(n: u64): u64 {
    if (n == 0) return 0;
    let mut bits = 0u8;
    let mut t = n;
    while (t > 0) { t = t >> 1; bits = bits + 1; };
    let mut x = 1u64 << ((bits + 1) / 2);
    loop {
        let y = (x + n / x) / 2;
        if (y >= x) return x;
        x = y;
    }
}

fun delta(lure: u64, stored: u64): S {
    let lure_b = lure + POS_BIAS;
    if (lure_b >= stored) S { neg: false, mag: lure_b - stored }
    else S { neg: true, mag: stored - lure_b }
}

fun sin_cos(heading: u16): (S, S) {
    let h = (heading as u64) % 65536;
    let q = h / 16384;
    let r = h % 16384;
    let i = (r * 256) / 16384;
    let s = (trig::sin_at(i) as u64);
    let c = (trig::sin_at(256 - i) as u64);
    if (q == 0) (S { neg: false, mag: s }, S { neg: false, mag: c })
    else if (q == 1) (S { neg: false, mag: c }, S { neg: true, mag: s })
    else if (q == 2) (S { neg: true, mag: s }, S { neg: true, mag: c })
    else (S { neg: true, mag: c }, S { neg: false, mag: s })
}

fun atan2_s(y: S, x: S): u16 {
    if (x.mag == 0 && y.mag == 0) return 0;
    let ang = if (x.mag >= y.mag) {
        (trig::atan_at((y.mag * 256) / x.mag) as u64)
    } else {
        16384 - (trig::atan_at((x.mag * 256) / y.mag) as u64)
    };
    let a = if (!x.neg && !y.neg) ang
        else if (x.neg && !y.neg) 32768 - ang
        else if (x.neg && y.neg) 32768 + ang
        else 65536 - ang;
    ((a % 65536) as u16)
}

fun ang_diff(src: u16, dst: u16): S {
    let d = ((dst as u64) + 65536 - (src as u64)) % 65536;
    if (d >= 32768) S { neg: true, mag: 65536 - d } else S { neg: false, mag: d }
}

fun add_heading(h: u16, neg: bool, mag: u64): u16 {
    let h = h as u64;
    let m = mag % 65536;
    let r = if (!neg) (h + m) % 65536
        else if (h >= m) h - m
        else h + 65536 - m;
    (r as u16)
}

fun add_scaled(pos: u64, thrust: u64, trig: S): u64 {
    if (trig.mag == 0 || thrust == 0) return pos;
    if (!trig.neg) pos + thrust * trig.mag / 256
    else {
        let dec = ceil_div(thrust * trig.mag, 256);
        assert!(pos >= dec, E_RANGE);
        pos - dec
    }
}

fun ceil_div(n: u64, d: u64): u64 {
    if (n == 0) 0 else (n + d - 1) / d
}

fun s_add(a: S, b: S): S {
    if (a.neg == b.neg) zero_ok(S { neg: a.neg, mag: a.mag + b.mag })
    else if (a.mag >= b.mag) zero_ok(S { neg: a.neg, mag: a.mag - b.mag })
    else zero_ok(S { neg: b.neg, mag: b.mag - a.mag })
}

fun s_mul(a: S, b: S): S {
    zero_ok(S { neg: a.neg != b.neg, mag: a.mag * b.mag })
}

fun s_floor_div(a: S, den: u64): S {
    if (!a.neg || a.mag == 0) S { neg: false, mag: a.mag / den }
    else S { neg: true, mag: ceil_div(a.mag, den) }
}

fun zero_ok(s: S): S {
    if (s.mag == 0) S { neg: false, mag: 0 } else s
}

public fun race_lure(seed: &vector<u8>, tick: u64): (u64, u64) {
    let (x, y, _) = race_lure_at(seed, tick, 0);
    (x, y)
}

/// Kind 0 is the original two-axis drift, so races created before kinds keep their lure.
/// 1 fixed lamp, 2 drift on x only, 3 a loop, 4 a fixed lamp that blinks. Light is 0 or 256.
public fun race_lure_at(seed: &vector<u8>, tick: u64, kind: u8): (u64, u64, u16) {
    assert!(seed.length() >= 4, E_LEN);
    assert!(kind <= 4, E_LEN);
    let a = seed[0] as u64;
    let b = seed[1] as u64;
    if (kind == 0) {
        (800 + ((a * 40 + tick * 30) % 4000), 200 + ((b * 25 + tick * 17) % 2000), 256u16)
    } else if (kind == 1) {
        (800 + ((a * 40) % 4000), 200 + ((b * 25) % 2000), 256u16)
    } else if (kind == 2) {
        (800 + ((a * 40 + tick * 30) % 4000), 200 + ((b * 25) % 2000), 256u16)
    } else if (kind == 3) {
        let ang = (((tick * 2048) % 65536) as u16);
        let (s, cos) = sin_cos(ang);
        let cx = 2400 + ((a * 4) % 800);
        let cy = 1200 + ((b * 3) % 400);
        (place(cx, cos, 600), place(cy, s, 600), 256u16)
    } else {
        let x = 800 + ((a * 40) % 4000);
        let y = 200 + ((b * 25) % 2000);
        let phase = (tick + (seed[3] as u64)) % 16;
        let light = if (phase < 8) 256u16 else 0u16;
        (x, y, light)
    }
}

fun place(base: u64, trig: S, radius: u64): u64 {
    let delta = radius * trig.mag / 256;
    if (!trig.neg) base + delta
    else {
        assert!(base >= delta, E_RANGE);
        base - delta
    }
}

public fun shadow_circle(seed: &vector<u8>, tick: u64): (u64, u64, u64) {
    assert!(seed.length() >= 4, E_LEN);
    let x = ((seed[0] as u64) * 30 + tick * 80) % 2400;
    let y = ((seed[1] as u64) * 20 + tick * 40) % 1200;
    let radius = 500 + ((seed[2] as u64) % 200);
    (x, y, radius)
}

public fun race_shadow(seed: &vector<u8>, tick: u64): bool {
    assert!(seed.length() >= 4, E_LEN);
    let phase = (tick + (seed[2] as u64)) % 40;
    phase >= 30
}

/// Drop the membrane after settlement. The hash, tick, and spike count stay.
public fun clear(b: &mut Brain) {
    let n = b.v.length();
    let mut i = 0;
    while (i < n) {
        *&mut b.v[i] = REST as u32;
        *&mut b.adapt[i] = 0;
        i = i + 1;
    };
    i = 0;
    while (i < b.spiked.length()) {
        *&mut b.spiked[i] = 0;
        i = i + 1;
    };
}

public fun state_hash_bytes(b: &Brain): vector<u8> { copy_bytes(&b.state_hash) }

public fun spike_bits(b: &Brain): vector<u64> {
    let mut out = vector[];
    let mut i = 0;
    while (i < b.spiked.length()) {
        out.push_back(b.spiked[i]);
        i = i + 1;
    };
    out
}
public fun spike_count(b: &Brain): u64 { b.spikes_total }
public fun brain_tick(b: &Brain): u64 { b.tick }
public fun body_x(b: &Body): u64 { b.x }
public fun body_y(b: &Body): u64 { b.y }
public fun body_heading(b: &Body): u16 { b.heading }
public fun body_yolk(b: &Body): u64 { b.yolk }

public fun spikes_total(l: &Larva): u64 { l.brain.spikes_total }
public fun tick_count(l: &Larva): u64 { l.brain.tick }
public fun x_of(l: &Larva): u64 { l.body.x }
public fun y_of(l: &Larva): u64 { l.body.y }
public fun heading_of(l: &Larva): u16 { l.body.heading }
public fun tilt_of(l: &Larva): u32 { l.body.tilt }
public fun yolk_of(l: &Larva): u64 { l.body.yolk }
public fun escape_thrust_of(l: &Larva): u64 { l.body.escape_thrust }
public fun body_depth(b: &Body): u32 { b.depth }
public fun depth_bias(): u32 { DEPTH_BIAS }
public fun pos_bias(): u64 { POS_BIAS }
public fun tilt_bias(): u32 { TILT_BIAS }
public fun gain_at(p: &Params, i: u64): u64 { p.gains[i] }
public fun leak_at(p: &Params, i: u64): u8 { p.leaks[i] }
public fun theta_at(p: &Params, i: u64): u64 { p.theta[i] }
public fun lr_at(p: &Params, i: u64): u64 { p.lr[i] }
public fun yolk0_of(p: &Params): u64 { p.yolk0 }
public fun competence_of(p: &Params): u64 { p.competence }
public fun data_hash_of(c: &Connectome): vector<u8> { copy_bytes(&c.data_hash) }

public fun state_hash_of(l: &Larva): vector<u8> { copy_bytes(&l.brain.state_hash) }

fun copy_bytes(h: &vector<u8>): vector<u8> {
    let mut out = vector[];
    let mut i = 0;
    while (i < h.length()) { out.push_back(h[i]); i = i + 1; };
    out
}

public fun new_connectome(
    n: u16,
    row_ptr: vector<u16>,
    col: vector<u8>,
    w: vector<u16>,
    inhib: vector<bool>,
    gap_ptr: vector<u16>,
    gap_col: vector<u8>,
    gap_w: vector<u16>,
    nmj_l: vector<u16>,
    nmj_r: vector<u16>,
    class_group: vector<u8>,
    data_hash: vector<u8>,
    ctx: &mut TxContext,
): Connectome {
    build_connectome(
        n, row_ptr, col, w, inhib, gap_ptr, gap_col, gap_w, nmj_l, nmj_r, class_group, data_hash, ctx,
    )
}

public fun destroy_connectome(c: Connectome) {
    let Connectome {
        id, version: _, n: _, row_ptr: _, col: _, w: _, inhib: _, gap_ptr: _, gap_col: _, gap_w: _,
        nmj_l: _, nmj_r: _, class_group: _, pr1: _, pr2: _, antenna: _, data_hash: _,
    } = c;
    object::delete(id);
}

#[test_only]
public fun new_for_test(
    n: u16,
    row_ptr: vector<u16>,
    col: vector<u8>,
    w: vector<u16>,
    inhib: vector<bool>,
    gap_ptr: vector<u16>,
    gap_col: vector<u8>,
    gap_w: vector<u16>,
    nmj_l: vector<u16>,
    nmj_r: vector<u16>,
    class_group: vector<u8>,
    data_hash: vector<u8>,
    ctx: &mut TxContext,
): Connectome {
    build_connectome(
        n, row_ptr, col, w, inhib, gap_ptr, gap_col, gap_w, nmj_l, nmj_r, class_group, data_hash, ctx,
    )
}

#[test_only]
public fun blank_pr2_for_test(c: &mut Connectome) {
    let mut i = 0;
    while (i < c.pr2.length()) {
        let idx = c.pr2[i] as u64;
        *&mut c.class_group[idx] = 15;
        i = i + 1;
    };
    c.pr2 = vector[];
}

#[test_only]
public fun set_body_tilt(b: &mut Body, tilt: u32) { b.tilt = tilt; }

#[test_only]
public fun set_body_depth(b: &mut Body, depth: u32) { b.depth = depth; }

#[test_only]
public fun set_body_heading(b: &mut Body, heading: u16) { b.heading = heading; }

#[test_only]
public fun set_tilt(l: &mut Larva, real_tilt: u32) {
    l.body.tilt = TILT_BIAS + real_tilt;
}

#[test_only]
public fun set_yolk_test(b: &mut Body, y: u64) {
    b.yolk = y;
}

#[test_only]
public fun set_tick_test(b: &mut Brain, t: u64) {
    b.tick = t;
}

#[test_only]
public fun set_pose_test(b: &mut Body, x: u64, y: u64) {
    b.x = POS_BIAS + x;
    b.y = POS_BIAS + y;
}

#[test_only]
public fun destroy_for_test(c: Connectome, l: Larva) {
    let Connectome {
        id, version: _, n: _, row_ptr: _, col: _, w: _, inhib: _, gap_ptr: _, gap_col: _, gap_w: _,
        nmj_l: _, nmj_r: _, class_group: _, pr1: _, pr2: _, antenna: _, data_hash: _,
    } = c;
    object::delete(id);
    let Larva { id, brain: _, body: _ } = l;
    object::delete(id);
}
