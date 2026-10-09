/// Shared reef grid. A claim holds a cell until the larva attaches or its settle window runs out.
/// Only ciona can claim, attach, or release cells. Anyone can evict a claim whose window expired.
module ocellus_game::reef;

use ocellus_game::rules;
use sui::clock::Clock;
use sui::random::{Self, Random};
use sui::event;
use sui::object::{Self, ID, UID};
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::TxContext;

const E_RANGE: u64 = 1;
const E_TAKEN: u64 = 2;
const E_ABSENT: u64 = 3;
const E_HOLDER: u64 = 4;
const E_ATTACHED: u64 = 5;
const E_NOT_EXPIRED: u64 = 6;

public struct ReefAdminCap has key, store { id: UID }

public struct Occupant has store, drop {
    creature: ID,
    settle_by_ms: u64,
    attached: bool,
}

public struct Reef has key {
    id: UID,
    shard: u32,
    cells: Table<u32, Occupant>,
    current_seed: u64,
    current_until_ms: u64,
}

public struct CellReleased has copy, drop {
    reef: ID,
    cell: u32,
    creature: ID,
}

public(package) fun create(shard: u32, ctx: &mut TxContext): Reef {
    Reef {
        id: object::new(ctx),
        shard,
        cells: table::new(ctx),
        current_seed: 1,
        current_until_ms: 0,
    }
}

entry fun share_first(ctx: &mut TxContext) {
    transfer::share_object(create(0, ctx));
    transfer::transfer(ReefAdminCap { id: object::new(ctx) }, ctx.sender());
}

public fun add_shard(_cap: &ReefAdminCap, shard: u32, ctx: &mut TxContext) {
    transfer::share_object(create(shard, ctx));
}

public(package) fun occupy(reef: &mut Reef, cell: u32, creature: ID, settle_by_ms: u64) {
    let n = rules::grid() * rules::grid();
    assert!((cell as u64) < n, E_RANGE);
    assert!(!table::contains(&reef.cells, cell), E_TAKEN);
    table::add(&mut reef.cells, cell, Occupant { creature, settle_by_ms, attached: false });
}

/// The settling larva attaches for good. Aborts if its claim was evicted.
public(package) fun attach(reef: &mut Reef, cell: u32, creature: ID) {
    assert!(table::contains(&reef.cells, cell), E_ABSENT);
    let o = table::borrow_mut(&mut reef.cells, cell);
    assert!(o.creature == creature, E_HOLDER);
    o.attached = true;
}

/// The holder gives up an unattached claim. Returns false if the claim is already gone.
public(package) fun release(reef: &mut Reef, cell: u32, creature: ID): bool {
    if (!table::contains(&reef.cells, cell)) return false;
    let o = table::borrow(&reef.cells, cell);
    if (o.creature != creature || o.attached) return false;
    table::remove(&mut reef.cells, cell);
    event::emit(CellReleased { reef: object::id(reef), cell, creature });
    true
}

/// Anyone can free a cell whose claimant never attached within its settle window.
public fun evict_expired(reef: &mut Reef, cell: u32, clock: &Clock) {
    assert!(table::contains(&reef.cells, cell), E_ABSENT);
    let o = table::borrow(&reef.cells, cell);
    assert!(!o.attached, E_ATTACHED);
    assert!(clock.timestamp_ms() > o.settle_by_ms, E_NOT_EXPIRED);
    let creature = o.creature;
    table::remove(&mut reef.cells, cell);
    event::emit(CellReleased { reef: object::id(reef), cell, creature });
}

public fun is_taken(reef: &Reef, cell: u32): bool { table::contains(&reef.cells, cell) }

public fun center(cell: u32): (u64, u64) {
    let g = rules::grid();
    let span = rules::cell_span();
    let x = ((cell as u64) % g) * span + span / 2;
    let y = ((cell as u64) / g) * span + span / 2;
    (x, y)
}

public fun current_of(reef: &Reef): u64 { reef.current_seed }

/// Draws the next drift seed. A zero seed is rejected so drift stays distinct from the no-current swim.
entry fun roll_current(reef: &mut Reef, r: &Random, clock: &Clock, ctx: &mut TxContext) {
    assert!(clock.timestamp_ms() >= reef.current_until_ms, E_NOT_EXPIRED);
    let mut gen = r.new_generator(ctx);
    let bytes = gen.generate_bytes(8);
    let mut seed = 0u64;
    let mut i = 0;
    while (i < 8) {
        seed = (seed << 8) | (bytes[i] as u64);
        i = i + 1;
    };
    if (seed == 0) seed = 1;
    reef.current_seed = seed;
    reef.current_until_ms = clock.timestamp_ms() + rules::current_window_ms();
}

public fun id_of(reef: &Reef): ID { object::id(reef) }

#[test_only]
public fun set_current(reef: &mut Reef, seed: u64) { reef.current_seed = seed; }

#[test_only]
public fun destroy(reef: Reef) {
    let Reef { id, shard: _, cells, current_seed: _, current_until_ms: _ } = reef;
    table::drop(cells);
    id.delete();
}
