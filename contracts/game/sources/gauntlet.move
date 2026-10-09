/// A shadow gauntlet. Ticks only read this object. The shared writes are enter, reveal, then mark.
/// The shadow is the body's escape counter, fed by PR-II spikes. It is not a motor-neuron burst.
module ocellus_game::gauntlet;

use ocellus_game::rules;
use std::option::{Self, Option};
use sui::clock::Clock;
use sui::event;
use sui::object::{Self, ID, UID};
use sui::random::{Self, Random};
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::TxContext;

const E_WINDOW: u64 = 1;
const E_ENTERED: u64 = 2;
const E_ABSENT: u64 = 3;
const E_DONE: u64 = 4;
const E_SEED: u64 = 5;
const E_CLOSED: u64 = 6;

public struct Slot has store, drop {
    done: bool,
    failed: bool,
    travel: u64,
}

public struct Gauntlet has key {
    id: UID,
    seed: vector<u8>,
    start_ms: u64,
    end_ms: u64,
    entries: Table<ID, Slot>,
    best_travel: Option<u64>,
    best_player: Option<address>,
    awarded: bool,
}

public struct Marked has copy, drop {
    gauntlet: ID,
    larva: ID,
    travel: u64,
    failed: bool,
}

public(package) fun create(clock: &Clock, ctx: &mut TxContext): Gauntlet {
    let start = clock.timestamp_ms() + rules::race_registration_ms();
    Gauntlet {
        id: object::new(ctx),
        seed: vector[],
        start_ms: start,
        end_ms: start + rules::race_window_ms(),
        entries: table::new(ctx),
        best_travel: option::none(),
        best_player: option::none(),
        awarded: false,
    }
}

entry fun create_gauntlet(clock: &Clock, ctx: &mut TxContext) {
    transfer::share_object(create(clock, ctx));
}

entry fun reveal_seed(g: &mut Gauntlet, r: &Random, clock: &Clock, ctx: &mut TxContext) {
    let mut gen = r.new_generator(ctx);
    set_seed(g, gen.generate_bytes(32), clock);
}

fun set_seed(g: &mut Gauntlet, seed: vector<u8>, clock: &Clock) {
    assert!(g.seed.is_empty(), E_SEED);
    assert!(clock.timestamp_ms() >= g.start_ms, E_WINDOW);
    assert!(seed.length() == 32, E_SEED);
    g.seed = seed;
}

public(package) fun enter(g: &mut Gauntlet, larva: ID, clock: &Clock) {
    assert!(is_open(g, clock.timestamp_ms()), E_CLOSED);
    assert!(!table::contains(&g.entries, larva), E_ENTERED);
    table::add(&mut g.entries, larva, Slot { done: false, failed: false, travel: 0 });
}

public fun is_open(g: &Gauntlet, now: u64): bool {
    now < g.start_ms && !g.awarded
}

public fun has_entered(g: &Gauntlet, larva: ID): bool {
    table::contains(&g.entries, larva)
}

public fun seed_of(g: &Gauntlet): &vector<u8> { &g.seed }

public fun is_revealed(g: &Gauntlet): bool { !g.seed.is_empty() }

public fun window(g: &Gauntlet): (u64, u64) { (g.start_ms, g.end_ms) }

public fun in_window(g: &Gauntlet, now: u64): bool {
    now >= g.start_ms && now < g.end_ms
}

public fun id_of(g: &Gauntlet): ID { object::id(g) }

public(package) fun mark(
    g: &mut Gauntlet,
    larva: ID,
    travel: u64,
    failed: bool,
    player: address,
    clock: &Clock,
) {
    let now = clock.timestamp_ms();
    let grace = g.end_ms + rules::race_grace_ms();
    assert!(now >= g.end_ms && now <= grace, E_WINDOW);
    assert!(table::contains(&g.entries, larva), E_ABSENT);
    let slot = table::borrow_mut(&mut g.entries, larva);
    assert!(!slot.done, E_DONE);
    slot.done = true;
    slot.failed = failed;
    slot.travel = travel;
    event::emit(Marked { gauntlet: object::id(g), larva, travel, failed });
    if (!failed) {
        let better = option::is_none(&g.best_travel) || travel > *option::borrow(&g.best_travel);
        if (better) {
            g.best_travel = option::some(travel);
            g.best_player = option::some(player);
        };
    };
}

public(package) fun take_winner(g: &mut Gauntlet, clock: &Clock): (address, u64) {
    let now = clock.timestamp_ms();
    assert!(now > g.end_ms + rules::race_grace_ms(), E_WINDOW);
    assert!(!g.awarded, E_DONE);
    assert!(option::is_some(&g.best_player), E_ABSENT);
    g.awarded = true;
    (*option::borrow(&g.best_player), *option::borrow(&g.best_travel))
}

public fun travel_of(g: &Gauntlet, larva: ID): u64 {
    table::borrow(&g.entries, larva).travel
}

public fun failed_of(g: &Gauntlet, larva: ID): bool {
    table::borrow(&g.entries, larva).failed
}

#[test_only]
public fun reveal_for_testing(g: &mut Gauntlet, seed: vector<u8>, clock: &Clock) {
    set_seed(g, seed, clock);
}

#[test_only]
public fun destroy(g: Gauntlet) {
    let Gauntlet {
        id, seed: _, start_ms: _, end_ms: _, entries, best_travel: _, best_player: _, awarded: _,
    } = g;
    table::drop(entries);
    id.delete();
}
