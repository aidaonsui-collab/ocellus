/// Gas benchmark only — NOT production code.
/// Fixed-point leaky integrate-and-fire over the Ciona larval connectome
/// (Ryan, Lu & Meinertzhagen 2016, eLife, CC BY 4.0). Every neuron's membrane
/// is updated on every tick; synaptic input is propagated from neurons that
/// spiked on the previous tick (CSR, presynaptic-major).
///
/// Model v1 (see bench/README.md, "Model v1"): inhibitory reversal floor,
/// stability-normalized gap coupling, spike-frequency adaptation. The exact
/// Python reference is bench/scripts/lif_model.py.
module ciona_bench::brain;

const REST: u32 = 1048576;      // 2^20 = 0 mV offset (unsigned fixed point)
const THRESH: u32 = 1048576 + 16384;
const RESET: u32 = 1048576 - 4096;
const V_FLOOR: u32 = 1048576 - 16384; // inhibitory reversal: inhibition can't push v below this
const V_CEIL: u32 = 1048576 + 65536;  // caps adapted cells above THRESH; keeps gap products in u32
const LEAK_SHIFT: u8 = 3;       // v += (rest - v) / 8 per tick
const W_SCALE: u32 = 320;       // weight units -> membrane units
const GAP_SHIFT: u8 = 12;       // gap_w holds coupling coefficients x 4096 (each cell's sum <= 0.5 per tick)
const ADAPT_INC: u32 = 8192;    // threshold rise per spike (spike-frequency adaptation)
const ADAPT_SHIFT: u8 = 4;      // adaptation decays by 1/16 per tick

public struct Connectome has key, store {
    id: UID,
    n: u64,
    row_ptr: vector<u16>, // len n+1
    col: vector<u8>,      // postsynaptic index
    w: vector<u16>,       // contact depth in 60-nm sections
    inhib: vector<bool>,  // per presynaptic neuron sign (Dale's law)
    gap_ptr: vector<u16>,
    gap_col: vector<u8>,
    gap_w: vector<u16>,   // stability-normalized coupling coefficients (scripts/gen_bench.py)
}

public struct Brain has key, store {
    id: UID,
    v: vector<u32>,
    adapt: vector<u32>,   // per-cell threshold adaptation
    spiked: vector<bool>,
    tick: u64,
    spikes_total: u64,
}

public fun new_connectome(
    n: u64, row_ptr: vector<u16>, col: vector<u8>, w: vector<u16>, inhib: vector<bool>,
    gap_ptr: vector<u16>, gap_col: vector<u8>, gap_w: vector<u16>, ctx: &mut TxContext,
): Connectome {
    Connectome { id: object::new(ctx), n, row_ptr, col, w, inhib, gap_ptr, gap_col, gap_w }
}

public fun new_brain(c: &Connectome, all_spiking: bool, ctx: &mut TxContext): Brain {
    let mut v = vector[]; let mut a = vector[]; let mut s = vector[];
    let mut i = 0; while (i < c.n) { v.push_back(REST); a.push_back(0); s.push_back(all_spiking); i = i + 1; };
    Brain { id: object::new(ctx), v, adapt: a, spiked: s, tick: 0, spikes_total: 0 }
}

/// sensor: list of (neuron index, drive) pairs injected this tick.
public fun step(c: &Connectome, b: &mut Brain, sensor_idx: vector<u8>, sensor_drive: vector<u32>, ticks: u64, force_all: bool) {
    let n = c.n;
    let mut t = 0;
    while (t < ticks) {
        let mut exc = vector::tabulate!(n, |_| 0u32);
        let mut inh = vector::tabulate!(n, |_| 0u32);
        // 1) chemical synapses from last tick's spikes
        let mut i = 0;
        while (i < n) {
            if (force_all || b.spiked[i]) {
                let lo = c.row_ptr[i] as u64; let hi = c.row_ptr[i + 1] as u64;
                let neg = c.inhib[i];
                let mut k = lo;
                while (k < hi) {
                    let j = c.col[k] as u64; let dw = (c.w[k] as u32) * W_SCALE;
                    if (neg) { *&mut inh[j] = inh[j] + dw } else { *&mut exc[j] = exc[j] + dw };
                    k = k + 1;
                };
            };
            i = i + 1;
        };
        // 2) gap junctions: current = voltage difference x coefficient / 4096.
        //    v stays in [V_FLOOR, V_CEIL] and coefficients are <= 2048, so the product fits u32.
        let mut i = 0;
        while (i < n) {
            let lo = c.gap_ptr[i] as u64; let hi = c.gap_ptr[i + 1] as u64;
            let vi = b.v[i];
            let mut k = lo;
            while (k < hi) {
                let j = c.gap_col[k] as u64; let vj = b.v[j]; let g = c.gap_w[k] as u32;
                if (vj > vi) { *&mut exc[i] = exc[i] + (((vj - vi) * g) >> GAP_SHIFT) }
                else { *&mut inh[i] = inh[i] + (((vi - vj) * g) >> GAP_SHIFT) };
                k = k + 1;
            };
            i = i + 1;
        };
        // 3) sensory drive
        let mut s = 0;
        while (s < sensor_idx.length()) {
            let j = sensor_idx[s] as u64; *&mut exc[j] = exc[j] + sensor_drive[s]; s = s + 1;
        };
        // 4) membrane update for EVERY neuron
        let mut i = 0;
        while (i < n) {
            let mut v = b.v[i];
            if (v > REST) { v = v - ((v - REST) >> LEAK_SHIFT) } else { v = v + ((REST - v) >> LEAK_SHIFT) };
            v = v + exc[i];
            v = if (v > inh[i]) { v - inh[i] } else { 0 };
            if (v < V_FLOOR) { v = V_FLOOR };
            if (v > V_CEIL) { v = V_CEIL };
            let mut a = b.adapt[i];
            a = a - (a >> ADAPT_SHIFT);
            let fired = v >= THRESH + a;
            if (fired) { v = RESET; a = a + ADAPT_INC; b.spikes_total = b.spikes_total + 1; };
            *&mut b.v[i] = v;
            *&mut b.adapt[i] = a;
            *&mut b.spiked[i] = fired;
            i = i + 1;
        };
        b.tick = b.tick + 1;
        t = t + 1;
    }
}

entry fun create(
    n: u64, row_ptr: vector<u16>, col: vector<u8>, w: vector<u16>, inhib: vector<bool>,
    gap_ptr: vector<u16>, gap_col: vector<u8>, gap_w: vector<u16>, ctx: &mut TxContext,
) {
    let c = new_connectome(n, row_ptr, col, w, inhib, gap_ptr, gap_col, gap_w, ctx);
    let b = new_brain(&c, false, ctx);
    transfer::public_transfer(c, ctx.sender());
    transfer::public_transfer(b, ctx.sender());
}

/// Production shape: connectome frozen (immutable, never rewritten), brain owned.
entry fun create_frozen(
    n: u64, row_ptr: vector<u16>, col: vector<u8>, w: vector<u16>, inhib: vector<bool>,
    gap_ptr: vector<u16>, gap_col: vector<u8>, gap_w: vector<u16>, ctx: &mut TxContext,
) {
    let c = new_connectome(n, row_ptr, col, w, inhib, gap_ptr, gap_col, gap_w, ctx);
    let b = new_brain(&c, false, ctx);
    transfer::public_freeze_object(c);
    transfer::public_transfer(b, ctx.sender());
}

/// Control: same tx shape, no brain work.
public fun noop(_c: &Connectome, b: &mut Brain) { b.tick = b.tick; }

public fun spikes_total(b: &Brain): u64 { b.spikes_total }
