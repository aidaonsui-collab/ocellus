/// Tunable life-cycle numbers. A game-package upgrade can change these.
/// The brain package does not read them.
module ocellus_game::rules;

const MINUTE: u64 = 60 * 1000;
const DAY: u64 = 24 * 60 * MINUTE;

public fun incubation_ms(): u64 { 5 * MINUTE }
public fun competence_ticks(): u64 { 1200 }
public fun competence_ms(): u64 { 20 * MINUTE }
public fun settle_window_ms(): u64 { 15 * MINUTE }
public fun attach_ms(): u64 { MINUTE }
public fun adult_life_ms(): u64 { 14 * DAY }
public fun race_registration_ms(): u64 { 10 * MINUTE }
public fun race_window_ms(): u64 { 30 * MINUTE }
public fun race_grace_ms(): u64 { 10 * MINUTE }
public fun grid(): u64 { 16 }
public fun cell_span(): u64 { 400 }
public fun claim_radius(): u64 { 250 }
public fun depth_bias(): u64 { 1024 }
public fun depth_radius(): u64 { 80 }
public fun depth_band(cell: u32): u64 { 1024 + ((cell as u64) % 16) * 32 }
public fun cell_current(cell: u32): u64 { 1 + ((cell as u64) % 10) }
public fun feed_gap_ms(): u64 { 60 * MINUTE }
public fun spawn_gap_ms(): u64 { 60 * MINUTE }
public fun current_window_ms(): u64 { 60 * MINUTE }
