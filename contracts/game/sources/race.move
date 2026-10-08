/// A light race. Ticks only read this object. The shared writes are enter, reveal, then finish.
///
/// Schedule, fixed at creation: registration [created, start_ms), race [start_ms, end_ms),
/// results [end_ms, end_ms + grace]. The lure seed is drawn from sui::random only after
/// registration closes (commit/reveal, DESIGN §7.1), so no entrant knows the path when entering.
/// Entrants can't swim freely until end_ms (ciona::swim), so during the race they move only by race_tick.
module ocellus_game::race;

use ocellus_game::rules;
use std::option::{Self, Option};
use sui::clock::Clock;
use sui::event;
use sui::object::{Self, ID, UID};
use sui::random::{Self, Random};
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::TxContext;

const NO_BEST: u64 = 1000000000;

const E_WINDOW: u64 = 1;
const E_ENTERED: u64 = 2;
const E_ABSENT: u64 = 3;
const E_DONE: u64 = 4;
const E_SEED: u64 = 5;
const E_CLOSED: u64 = 6;

public struct Slot has store, drop {
    done: bool,
    distance: u64,
}

public struct LightRace has key {
    id: UID,
    seed: vector<u8>,
    start_ms: u64,
    end_ms: u64,
    entries: Table<ID, Slot>,
    best_distance: u64,
    best_player: Option<address>,
    awarded: bool,
}

public struct SeedRevealed has copy, drop {
    race: ID,
    seed: vector<u8>,
}

public(package) fun create(clock: &Clock, ctx: &mut TxContext): LightRace {
    let start = clock.timestamp_ms() + rules::race_registration_ms();
    LightRace {
        id: object::new(ctx),
        seed: vector[],
        start_ms: start,
        end_ms: start + rules::race_window_ms(),
        entries: table::new(ctx),
        best_distance: NO_BEST,
        best_player: option::none(),
        awarded: false,
    }
}

entry fun create_race(clock: &Clock, ctx: &mut TxContext) {
    transfer::share_object(create(clock, ctx));
}

/// Anyone can reveal once registration has closed. Non-public entry, as sui::random requires.
entry fun reveal_seed(race: &mut LightRace, r: &Random, clock: &Clock, ctx: &mut TxContext) {
    let mut gen = r.new_generator(ctx);
    set_seed(race, gen.generate_bytes(32), clock);
}

fun set_seed(race: &mut LightRace, seed: vector<u8>, clock: &Clock) {
    assert!(race.seed.is_empty(), E_SEED);
    assert!(clock.timestamp_ms() >= race.start_ms, E_WINDOW);
    assert!(seed.length() == 32, E_SEED);
    race.seed = seed;
    event::emit(SeedRevealed { race: object::id(race), seed });
}

public(package) fun enter(race: &mut LightRace, larva: ID, clock: &Clock) {
    assert!(is_open(race, clock.timestamp_ms()), E_CLOSED);
    assert!(!table::contains(&race.entries, larva), E_ENTERED);
    table::add(&mut race.entries, larva, Slot { done: false, distance: 0 });
}

/// Registration is open: entries and entry fees are accepted.
public fun is_open(race: &LightRace, now: u64): bool {
    now < race.start_ms && !race.awarded
}

public fun has_entered(race: &LightRace, larva: ID): bool {
    table::contains(&race.entries, larva)
}

public fun seed_of(race: &LightRace): &vector<u8> { &race.seed }

public fun is_revealed(race: &LightRace): bool { !race.seed.is_empty() }

public fun window(race: &LightRace): (u64, u64) { (race.start_ms, race.end_ms) }

public fun in_window(race: &LightRace, now: u64): bool {
    now >= race.start_ms && now < race.end_ms
}

public(package) fun finish(race: &mut LightRace, larva: ID, distance: u64, player: address, clock: &Clock) {
    let now = clock.timestamp_ms();
    let grace = race.end_ms + rules::race_grace_ms();
    assert!(now >= race.end_ms && now <= grace, E_WINDOW);
    assert!(table::contains(&race.entries, larva), E_ABSENT);
    let slot = table::borrow_mut(&mut race.entries, larva);
    assert!(!slot.done, E_DONE);
    slot.done = true;
    slot.distance = distance;
    if (distance < race.best_distance) {
        race.best_distance = distance;
        race.best_player = option::some(player);
    };
}

public(package) fun take_winner(race: &mut LightRace, clock: &Clock): (address, u64) {
    let now = clock.timestamp_ms();
    assert!(now > race.end_ms + rules::race_grace_ms(), E_WINDOW);
    assert!(!race.awarded, E_DONE);
    assert!(option::is_some(&race.best_player), E_ABSENT);
    race.awarded = true;
    (*option::borrow(&race.best_player), race.best_distance)
}

public fun distance_of(race: &LightRace, larva: ID): u64 {
    table::borrow(&race.entries, larva).distance
}

public fun id_of(race: &LightRace): ID { object::id(race) }

#[test_only]
public fun reveal_for_testing(race: &mut LightRace, seed: vector<u8>, clock: &Clock) {
    set_seed(race, seed, clock);
}

#[test_only]
public fun destroy(race: LightRace) {
    let LightRace { id, seed: _, start_ms: _, end_ms: _, entries, best_distance: _, best_player: _, awarded: _ } = race;
    table::drop(entries);
    id.delete();
}
