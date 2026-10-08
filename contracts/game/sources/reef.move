/// Shared reef grid. A cell is written once, when a larva claims it.
module ocellus_game::reef;

use ocellus_game::rules;
use sui::object::{Self, ID, UID};
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::TxContext;

const E_RANGE: u64 = 1;
const E_TAKEN: u64 = 2;

public struct ReefAdminCap has key, store { id: UID }

public struct Reef has key {
    id: UID,
    shard: u32,
    cells: Table<u32, ID>,
    current_seed: u64,
}

public fun create(shard: u32, ctx: &mut TxContext): Reef {
    Reef {
        id: object::new(ctx),
        shard,
        cells: table::new(ctx),
        current_seed: 1,
    }
}

entry fun share_first(ctx: &mut TxContext) {
    transfer::share_object(create(0, ctx));
    transfer::transfer(ReefAdminCap { id: object::new(ctx) }, ctx.sender());
}

public fun add_shard(_cap: &ReefAdminCap, shard: u32, ctx: &mut TxContext) {
    transfer::share_object(create(shard, ctx));
}

public fun occupy(reef: &mut Reef, cell: u32, creature: ID) {
    let n = rules::grid() * rules::grid();
    assert!((cell as u64) < n, E_RANGE);
    assert!(!table::contains(&reef.cells, cell), E_TAKEN);
    table::add(&mut reef.cells, cell, creature);
}

public fun center(cell: u32): (u64, u64) {
    let g = rules::grid();
    let span = rules::cell_span();
    let x = ((cell as u64) % g) * span + span / 2;
    let y = ((cell as u64) / g) * span + span / 2;
    (x, y)
}

public fun current_of(reef: &Reef): u64 { reef.current_seed }

public fun id_of(reef: &Reef): ID { object::id(reef) }

#[test_only]
public fun destroy(reef: Reef) {
    let Reef { id, shard: _, cells, current_seed: _ } = reef;
    table::drop(cells);
    id.delete();
}
