/// A creature that owns a brain and a body from ocellus_brain.
/// Founders are hatched straight into the larval stage. Eggs, settlement,
/// and fossils come later.
module ocellus_game::ciona;

use ocellus_brain::brain::{Self, Body, Brain, Connectome};
use ocellus_game::market::Game;
use ocellus_game::race::{Self, LightRace};
use ocellus_game::reef::{Self, Reef};
use ocellus_game::rules;
use ocellus_sink::sink::Sink;
use sui::coin::Coin;
use sui::clock::Clock;
use sui::event;
use sui::object::{Self, ID, UID};
use std::option::{Self, Option};
use sui::random::{Self, Random};
use sui::transfer;
use sui::tx_context::TxContext;

const STAGE_LARVA: u8 = 1;
const STAGE_SETTLING: u8 = 2;
const STAGE_ADULT: u8 = 3;
const STAGE_FOSSIL: u8 = 4;

const E_STAGE: u64 = 1;
const E_YOLK: u64 = 2;
const E_CLOCK: u64 = 3;
const E_GENOME: u64 = 4;
const E_CONNECTOME: u64 = 5;
const E_COMPETENCE: u64 = 6;
const E_FAR: u64 = 7;
const E_EARLY: u64 = 8;
const E_LATE: u64 = 9;
const E_RACE: u64 = 10;
const E_RACING: u64 = 11;
const E_HOME: u64 = 12;

const NO_BEST: u64 = 1000000000;

public struct Ciona has key, store {
    id: UID,
    generation: u32,
    stage: u8,
    genome: vector<u8>,
    brain: Brain,
    body: Body,
    born_ms: u64,
    stage_since_ms: u64,
    ticked: bool,
    last_tick_ms: u64,
    parents: vector<ID>,
    connectome: ID,
    home: Option<ID>,
    settling_cell: u32,
    race: Option<ID>,
    race_lock_until_ms: u64,
    best_distance: u64,
    record: Option<ID>,
    energy: u64,
    last_feed_ms: u64,
}

public struct LarvalRecord has key, store {
    id: UID,
    creature: ID,
    state_hash: vector<u8>,
    tick: u64,
    spikes: u64,
    x: u64,
    y: u64,
    heading: u16,
}

public struct Settled has copy, drop {
    creature: ID,
    record: ID,
    state_hash: vector<u8>,
    tick: u64,
}

public struct Hatched has copy, drop {
    creature: ID,
    genome: vector<u8>,
    connectome: ID,
}

public struct Tick has copy, drop {
    creature: ID,
    tick: u64,
    state_hash: vector<u8>,
    spikes: u64,
    inputs_digest: u32,
    x: u64,
    y: u64,
    heading: u16,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
}

fun canonical_hash(): vector<u8> {
    x"9004dac630dbed5d88438c892deab08bb3a927f75e6337301cc720eeac65cf16"
}

entry fun hatch_founder(
    r: &Random,
    clock: &Clock,
    connectome: &Connectome,
    ctx: &mut TxContext,
) {
    let mut gen = r.new_generator(ctx);
    let bytes = gen.generate_bytes(64);
    let creature = mint(bytes, clock, connectome, ctx);
    transfer::public_transfer(creature, ctx.sender());
}

/// Free swimming with the player's own lure. Not allowed from race entry until the race ends.
public fun swim(
    ciona: &mut Ciona,
    connectome: &Connectome,
    clock: &Clock,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
) {
    assert!(clock.timestamp_ms() >= ciona.race_lock_until_ms, E_RACING);
    step(ciona, connectome, clock, lure_x, lure_y, light, shadow, pulse);
}

fun step(
    ciona: &mut Ciona,
    connectome: &Connectome,
    clock: &Clock,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
) {
    assert!(ciona.stage == STAGE_LARVA, E_STAGE);
    assert!(brain::body_yolk(&ciona.body) > 0, E_YOLK);
    assert!(object::id(connectome) == ciona.connectome, E_CONNECTOME);
    assert!(brain::data_hash_of(connectome) == canonical_hash(), E_CONNECTOME);
    let now = clock.timestamp_ms();
    if (ciona.ticked) {
        assert!(now != ciona.last_tick_ms, E_CLOCK);
    };
    let params = brain::decode(&ciona.genome);
    let digest = brain::tick_state(
        connectome, &mut ciona.brain, &mut ciona.body, &params,
        lure_x, lure_y, light, shadow, pulse,
    );
    ciona.ticked = true;
    ciona.last_tick_ms = now;
    event::emit(Tick {
        creature: object::id(ciona),
        tick: brain::brain_tick(&ciona.brain),
        state_hash: brain::state_hash_bytes(&ciona.brain),
        spikes: brain::spike_count(&ciona.brain),
        inputs_digest: digest,
        x: brain::body_x(&ciona.body),
        y: brain::body_y(&ciona.body),
        heading: brain::body_heading(&ciona.body),
        lure_x,
        lure_y,
        light,
        shadow,
        pulse,
    });
}

entry fun swim_tick(
    ciona: &mut Ciona,
    connectome: &Connectome,
    clock: &Clock,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
) {
    swim(ciona, connectome, clock, lure_x, lure_y, light, shadow, pulse);
}

fun mint(bytes: vector<u8>, clock: &Clock, connectome: &Connectome, ctx: &mut TxContext): Ciona {
    assert!(bytes.length() == 64, E_GENOME);
    assert!(brain::data_hash_of(connectome) == canonical_hash(), E_CONNECTOME);
    let params = brain::decode(&bytes);
    let (brain_state, body) = brain::new_state(connectome, &params);
    let now = clock.timestamp_ms();
    let connectome_id = object::id(connectome);
    let id = object::new(ctx);
    let creature_id = id.to_inner();
    event::emit(Hatched {
        creature: creature_id,
        genome: bytes,
        connectome: connectome_id,
    });
    Ciona {
        id,
        generation: 0,
        stage: STAGE_LARVA,
        genome: bytes,
        brain: brain_state,
        body,
        born_ms: now,
        stage_since_ms: now,
        ticked: false,
        last_tick_ms: 0,
        parents: vector[],
        connectome: connectome_id,
        home: option::none(),
        settling_cell: 0,
        race: option::none(),
        race_lock_until_ms: 0,
        best_distance: NO_BEST,
        record: option::none(),
        energy: 0,
        last_feed_ms: 0,
    }
}

public fun claim(ciona: &mut Ciona, reef: &mut Reef, cell: u32, clock: &Clock) {
    assert!(ciona.stage == STAGE_LARVA, E_STAGE);
    let now = clock.timestamp_ms();
    assert!(brain::brain_tick(&ciona.brain) >= rules::competence_ticks(), E_COMPETENCE);
    assert!(now >= ciona.born_ms + rules::competence_ms(), E_COMPETENCE);
    assert!(near(ciona, cell), E_FAR);
    reef::occupy(reef, cell, object::id(ciona), now + rules::settle_window_ms());
    ciona.stage = STAGE_SETTLING;
    ciona.stage_since_ms = now;
    ciona.home = option::some(reef::id_of(reef));
    ciona.settling_cell = cell;
}

public fun complete_settle(ciona: &mut Ciona, reef: &mut Reef, clock: &Clock, ctx: &mut TxContext) {
    assert!(ciona.stage == STAGE_SETTLING, E_STAGE);
    assert!(is_home(ciona, reef), E_HOME);
    let now = clock.timestamp_ms();
    assert!(now >= ciona.stage_since_ms + rules::attach_ms(), E_EARLY);
    assert!(now <= ciona.stage_since_ms + rules::settle_window_ms(), E_LATE);
    reef::attach(reef, ciona.settling_cell, object::id(ciona));
    let hash = brain::state_hash_bytes(&ciona.brain);
    let record_id_uid = object::new(ctx);
    let record_id = record_id_uid.to_inner();
    let record = LarvalRecord {
        id: record_id_uid,
        creature: object::id(ciona),
        state_hash: hash,
        tick: brain::brain_tick(&ciona.brain),
        spikes: brain::spike_count(&ciona.brain),
        x: brain::body_x(&ciona.body),
        y: brain::body_y(&ciona.body),
        heading: brain::body_heading(&ciona.body),
    };
    event::emit(Settled {
        creature: object::id(ciona),
        record: record_id,
        state_hash: record.state_hash,
        tick: record.tick,
    });
    transfer::public_freeze_object(record);
    brain::clear(&mut ciona.brain);
    ciona.stage = STAGE_ADULT;
    ciona.stage_since_ms = now;
    ciona.record = option::some(record_id);
}

/// The larva missed its settle window: it fails (DESIGN §6) and its claim, if still held, is released.
public fun fail_settle(ciona: &mut Ciona, reef: &mut Reef, clock: &Clock) {
    assert!(ciona.stage == STAGE_SETTLING, E_STAGE);
    assert!(is_home(ciona, reef), E_HOME);
    let now = clock.timestamp_ms();
    assert!(now > ciona.stage_since_ms + rules::settle_window_ms(), E_EARLY);
    reef::release(reef, ciona.settling_cell, object::id(ciona));
    brain::clear(&mut ciona.brain);
    ciona.stage = STAGE_FOSSIL;
    ciona.stage_since_ms = now;
    ciona.home = option::none();
}

/// The only way into a race: the entry fee goes to the sink and the race pot.
public fun enter_paid<T>(
    ciona: &mut Ciona,
    race: &mut LightRace,
    game: &mut Game<T>,
    sink: &mut Sink<T>,
    payment: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    let refund = ocellus_game::market::pay_entry(game, sink, race, payment, clock, ctx);
    enter_race(ciona, race, clock);
    refund
}

public(package) fun enter_race(ciona: &mut Ciona, race: &mut LightRace, clock: &Clock) {
    assert!(ciona.stage == STAGE_LARVA, E_STAGE);
    let now = clock.timestamp_ms();
    // A larva can race again once its last race is finalized or its results window has passed.
    assert!(option::is_none(&ciona.race) || now > ciona.race_lock_until_ms + rules::race_grace_ms(), E_RACE);
    race::enter(race, object::id(ciona), clock);
    let (_start, end) = race::window(race);
    ciona.race = option::some(race::id_of(race));
    ciona.race_lock_until_ms = end;
    ciona.best_distance = NO_BEST;
}

public fun race_tick(
    ciona: &mut Ciona,
    race: &LightRace,
    connectome: &Connectome,
    clock: &Clock,
) {
    assert!(ciona.stage == STAGE_LARVA, E_STAGE);
    assert!(option::is_some(&ciona.race) && *option::borrow(&ciona.race) == race::id_of(race), E_RACE);
    assert!(race::has_entered(race, object::id(ciona)), E_RACE);
    let now = clock.timestamp_ms();
    assert!(race::in_window(race, now), E_RACE);
    assert!(race::is_revealed(race), E_RACE);
    let next = brain::brain_tick(&ciona.brain) + 1;
    let (lx, ly) = brain::race_lure(race::seed_of(race), next);
    let shadow = brain::race_shadow(race::seed_of(race), next);
    step(ciona, connectome, clock, lx, ly, 256, shadow, false);
    let dist = apart(brain::body_x(&ciona.body), brain::body_y(&ciona.body), lx, ly);
    if (dist < ciona.best_distance) ciona.best_distance = dist;
}

public fun finalize_race(ciona: &mut Ciona, race: &mut LightRace, clock: &Clock, ctx: &TxContext) {
    assert!(option::is_some(&ciona.race) && *option::borrow(&ciona.race) == race::id_of(race), E_RACE);
    assert!(ciona.best_distance < NO_BEST, E_RACE);
    race::finish(race, object::id(ciona), ciona.best_distance, ctx.sender(), clock);
    ciona.race = option::none();
}

public fun feed(ciona: &mut Ciona, reef: &Reef, clock: &Clock) {
    assert!(ciona.stage == STAGE_ADULT, E_STAGE);
    assert!(option::is_some(&ciona.home) && *option::borrow(&ciona.home) == reef::id_of(reef), E_RACE);
    let now = clock.timestamp_ms();
    assert!(ciona.last_feed_ms == 0 || now >= ciona.last_feed_ms + rules::feed_gap_ms(), E_EARLY);
    ciona.energy = ciona.energy + (reef::current_of(reef) % 10) + 1;
    ciona.last_feed_ms = now;
}

#[test_only]
public fun hatch_with_genome(
    bytes: vector<u8>,
    clock: &Clock,
    connectome: &Connectome,
    ctx: &mut TxContext,
): Ciona {
    mint(bytes, clock, connectome, ctx)
}

#[test_only]
public fun set_yolk(c: &mut Ciona, y: u64) {
    brain::set_yolk_test(&mut c.body, y);
}

#[test_only]
public fun destroy_ciona(c: Ciona) {
    let Ciona {
        id, generation: _, stage: _, genome: _, brain: _, body: _, born_ms: _, stage_since_ms: _,
        ticked: _, last_tick_ms: _, parents: _, connectome: _,
        home: _, settling_cell: _, race: _, race_lock_until_ms: _, best_distance: _, record: _, energy: _, last_feed_ms: _,
    } = c;
    object::delete(id);
}

#[test_only]
public fun test_ticks(c: &mut Ciona, t: u64) {
    brain::set_tick_test(&mut c.brain, t);
}

#[test_only]
public fun test_pose(c: &mut Ciona, x: u64, y: u64) {
    brain::set_pose_test(&mut c.body, x, y);
}

#[test_only]
public fun test_set_best(c: &mut Ciona, distance: u64) {
    c.best_distance = distance;
}

fun is_home(ciona: &Ciona, reef: &Reef): bool {
    option::is_some(&ciona.home) && *option::borrow(&ciona.home) == reef::id_of(reef)
}

fun near(ciona: &Ciona, cell: u32): bool {
    let (cx, cy) = reef::center(cell);
    let x = brain::body_x(&ciona.body) - brain::pos_bias();
    let y = brain::body_y(&ciona.body) - brain::pos_bias();
    let dx = if (x > cx) { x - cx } else { cx - x };
    let dy = if (y > cy) { y - cy } else { cy - y };
    let r = rules::claim_radius();
    dx * dx + dy * dy <= r * r
}

fun apart(stored_x: u64, stored_y: u64, lure_x: u64, lure_y: u64): u64 {
    let x = stored_x - brain::pos_bias();
    let y = stored_y - brain::pos_bias();
    let dx = if (x > lure_x) { x - lure_x } else { lure_x - x };
    let dy = if (y > lure_y) { y - lure_y } else { lure_y - y };
    dx * dx + dy * dy
}

public fun stage_of(c: &Ciona): u8 { c.stage }
public fun yolk_of(c: &Ciona): u64 { brain::body_yolk(&c.body) }
public fun x_of(c: &Ciona): u64 { brain::body_x(&c.body) }
public fun y_of(c: &Ciona): u64 { brain::body_y(&c.body) }
public fun heading_of(c: &Ciona): u16 { brain::body_heading(&c.body) }
public fun hash_of(c: &Ciona): vector<u8> { brain::state_hash_bytes(&c.brain) }
public fun tick_of(c: &Ciona): u64 { brain::brain_tick(&c.brain) }
public fun settled_hash(s: &Settled): vector<u8> { s.state_hash }
public fun settled_tick(s: &Settled): u64 { s.tick }
public fun best_of(c: &Ciona): u64 { c.best_distance }
public fun energy_of(c: &Ciona): u64 { c.energy }
