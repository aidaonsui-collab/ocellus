/// A creature that owns a brain and a body from ocellus_brain.
/// Founders hatch as larvae. Settlement and fossils are implemented. Breeding is not.
module ocellus_game::ciona;

use ocellus_brain::brain::{Self, Body, Brain, Connectome};
use ocellus_game::gauntlet::{Self, Gauntlet};
use ocellus_game::market::Game;
use ocellus_game::race::{Self, LightRace};
use ocellus_game::reef::{Self, Reef};
use ocellus_game::swarm::{Self, SwarmBoard};
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
    gauntlet: Option<ID>,
    race_lock_until_ms: u64,
    best_distance: Option<u64>,
    travel: u64,
    failed: bool,
    record: Option<ID>,
    energy: u64,
    last_feed_ms: u64,
    last_spawn_ms: u64,
    marking: bool,
    mark_tick: u64,
    mark_hash: vector<u8>,
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
    parents: vector<ID>,
}

public struct Spikes has copy, drop {
    creature: ID,
    tick: u64,
    bits: vector<u64>,
}

public struct ClipClosed has copy, drop {
    creature: ID,
    start_tick: u64,
    end_tick: u64,
    start_hash: vector<u8>,
    end_hash: vector<u8>,
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
    neighbors: u64,
    current: u64,
}

/// Held by the publisher. The free hatch exists for local testing. Players use hatch_paid.
public struct FounderCap has key, store { id: UID }

fun init(ctx: &mut TxContext) {
    transfer::public_transfer(FounderCap { id: object::new(ctx) }, ctx.sender());
}

fun canonical_hash(): vector<u8> { canonical_hash_bytes() }

public fun canonical_hash_bytes(): vector<u8> {
    x"9004dac630dbed5d88438c892deab08bb3a927f75e6337301cc720eeac65cf16"
}

entry fun hatch_founder(
    _cap: &FounderCap,
    r: &Random,
    clock: &Clock,
    connectome: &Connectome,
    ctx: &mut TxContext,
) {
    let mut gen = r.new_generator(ctx);
    let bytes = gen.generate_bytes(64);
    let creature = mint(bytes, clock, connectome, vector[], 0, ctx);
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
    step(ciona, connectome, clock, lure_x, lure_y, light, shadow, pulse, 0, 0);
}

public(package) fun swim_current(
    ciona: &mut Ciona,
    connectome: &Connectome,
    clock: &Clock,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
    current: u64,
) {
    assert!(clock.timestamp_ms() >= ciona.race_lock_until_ms, E_RACING);
    step(ciona, connectome, clock, lure_x, lure_y, light, shadow, pulse, 0, current);
}

public fun swim_reef(
    ciona: &mut Ciona,
    connectome: &Connectome,
    reef: &Reef,
    clock: &Clock,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
) {
    swim_current(ciona, connectome, clock, lure_x, lure_y, light, shadow, pulse, reef::current_of(reef));
}

public fun join_swarm(ciona: &Ciona, board: &mut SwarmBoard, clock: &Clock, ctx: &TxContext) {
    swarm::join(board, object::id(ciona), clock, ctx);
}

public fun swim_swarm(
    ciona: &mut Ciona,
    connectome: &Connectome,
    board: &mut SwarmBoard,
    clock: &Clock,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
    ctx: &TxContext,
) {
    assert!(clock.timestamp_ms() >= ciona.race_lock_until_ms, E_RACING);
    let id = object::id(ciona);
    let n = swarm::shade(board, id, brain::body_x(&ciona.body), brain::body_y(&ciona.body));
    step(ciona, connectome, clock, lure_x, lure_y, light, shadow, pulse, n, 0);
    swarm::post(
        board, id, brain::body_x(&ciona.body), brain::body_y(&ciona.body),
        brain::brain_tick(&ciona.brain), clock, ctx,
    );
}

/// Open a highlight on the first call and close it on the second. Spike bits are emitted only while it is open.
public fun mark(ciona: &mut Ciona) {
    if (!ciona.marking) {
        ciona.marking = true;
        ciona.mark_tick = brain::brain_tick(&ciona.brain);
        ciona.mark_hash = brain::state_hash_bytes(&ciona.brain);
    } else {
        event::emit(ClipClosed {
            creature: object::id(ciona),
            start_tick: ciona.mark_tick,
            end_tick: brain::brain_tick(&ciona.brain),
            start_hash: ciona.mark_hash,
            end_hash: brain::state_hash_bytes(&ciona.brain),
        });
        ciona.marking = false;
    };
}

public fun marking(c: &Ciona): bool { c.marking }

entry fun hatch_paid<T>(
    game: &mut Game<T>,
    sink: &mut Sink<T>,
    payment: Coin<T>,
    r: &Random,
    clock: &Clock,
    connectome: &Connectome,
    ctx: &mut TxContext,
) {
    let refund = ocellus_game::market::pay_hatch(game, sink, payment, clock, ctx);
    transfer::public_transfer(refund, ctx.sender());
    let mut gen = r.new_generator(ctx);
    let bytes = gen.generate_bytes(64);
    transfer::public_transfer(mint(bytes, clock, connectome, vector[], 0, ctx), ctx.sender());
}

fun alleles_block(a: &vector<u8>, b: &vector<u8>): bool {
    a[38] == b[38] || a[39] == b[39] || a[40] == b[40]
}

fun cross(a: &vector<u8>, b: &vector<u8>, rolls: &vector<u8>): vector<u8> {
    let mut g = vector[];
    let mut i = 0;
    while (i < 64) {
        let pick = if (rolls[i] % 2 == 0) a[i] else b[i];
        // Bit 0 of rolls[i] chose the parent, so the flipped bit comes from bits 1-3.
        let mutated = if (rolls[64 + i] < 3) pick ^ (1u8 << ((rolls[i] >> 1) % 8)) else pick;
        g.push_back(mutated);
        i = i + 1;
    };
    g
}

fun breed(
    a: &Ciona,
    b: &Ciona,
    rolls: vector<u8>,
    clock: &Clock,
    connectome: &Connectome,
    ctx: &mut TxContext,
): Ciona {
    assert!(object::id(a) != object::id(b), E_GENOME);
    assert!(a.stage == STAGE_ADULT && b.stage == STAGE_ADULT, E_STAGE);
    assert!(rolls.length() == 128, E_GENOME);
    let now = clock.timestamp_ms();
    assert!(a.last_spawn_ms == 0 || now >= a.last_spawn_ms + rules::spawn_gap_ms(), E_EARLY);
    assert!(b.last_spawn_ms == 0 || now >= b.last_spawn_ms + rules::spawn_gap_ms(), E_EARLY);
    assert!(!alleles_block(&a.genome, &b.genome), E_GENOME);
    let genome = cross(&a.genome, &b.genome, &rolls);
    let gen = if (a.generation > b.generation) a.generation else b.generation;
    let parents = vector[object::id(a), object::id(b)];
    mint(genome, clock, connectome, parents, gen + 1, ctx)
}

entry fun spawn<T>(
    a: &mut Ciona,
    b: &mut Ciona,
    game: &mut Game<T>,
    sink: &mut Sink<T>,
    payment: Coin<T>,
    r: &Random,
    clock: &Clock,
    connectome: &Connectome,
    ctx: &mut TxContext,
) {
    let mut gen = r.new_generator(ctx);
    let rolls = gen.generate_bytes(128);
    let refund = ocellus_game::market::pay_hatch(game, sink, payment, clock, ctx);
    transfer::public_transfer(refund, ctx.sender());
    let child = breed(a, b, rolls, clock, connectome, ctx);
    a.last_spawn_ms = clock.timestamp_ms();
    b.last_spawn_ms = clock.timestamp_ms();
    transfer::public_transfer(child, ctx.sender());
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
    neighbors: u64,
    current: u64,
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
    let cut = neighbors * 16;
    let shaded = if ((light as u64) > cut) (((light as u64) - cut) as u16) else 0;
    let digest = brain::tick_current(
        connectome, &mut ciona.brain, &mut ciona.body, &params,
        lure_x, lure_y, shaded, shadow, pulse, current,
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
        neighbors,
        current,
    });
    if (ciona.marking) {
        event::emit(Spikes {
            creature: object::id(ciona),
            tick: brain::brain_tick(&ciona.brain),
            bits: brain::spike_bits(&ciona.brain),
        });
    };
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

fun mint(
    bytes: vector<u8>,
    clock: &Clock,
    connectome: &Connectome,
    parents: vector<ID>,
    generation: u32,
    ctx: &mut TxContext,
): Ciona {
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
        parents,
    });
    Ciona {
        id,
        generation,
        stage: STAGE_LARVA,
        genome: bytes,
        brain: brain_state,
        body,
        born_ms: now,
        stage_since_ms: now,
        ticked: false,
        last_tick_ms: 0,
        parents,
        connectome: connectome_id,
        home: option::none(),
        settling_cell: 0,
        race: option::none(),
        gauntlet: option::none(),
        race_lock_until_ms: 0,
        best_distance: option::none(),
        travel: 0,
        failed: false,
        record: option::none(),
        energy: 0,
        last_feed_ms: 0,
        last_spawn_ms: 0,
        marking: false,
        mark_tick: 0,
        mark_hash: vector[],
    }
}

public fun claim(ciona: &mut Ciona, reef: &mut Reef, cell: u32, clock: &Clock) {
    assert!(ciona.stage == STAGE_LARVA, E_STAGE);
    let now = clock.timestamp_ms();
    assert!(brain::brain_tick(&ciona.brain) >= rules::competence_ticks(), E_COMPETENCE);
    assert!(now >= ciona.born_ms + rules::competence_ms(), E_COMPETENCE);
    assert!(near(ciona, cell), E_FAR);
    assert!(depth_near(ciona, cell), E_FAR);
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

fun release_expired(ciona: &mut Ciona, now: u64) {
    if (now > ciona.race_lock_until_ms + rules::race_grace_ms()) {
        ciona.race = option::none();
        ciona.gauntlet = option::none();
    };
}

public(package) fun enter_race(ciona: &mut Ciona, race: &mut LightRace, clock: &Clock) {
    assert!(ciona.stage == STAGE_LARVA, E_STAGE);
    let now = clock.timestamp_ms();
    release_expired(ciona, now);
    assert!(option::is_none(&ciona.gauntlet), E_RACE);
    // A larva can race again once its last race is finalized or its results window has passed.
    assert!(option::is_none(&ciona.race) || now > ciona.race_lock_until_ms + rules::race_grace_ms(), E_RACE);
    race::enter(race, object::id(ciona), clock);
    let (_start, end) = race::window(race);
    ciona.race = option::some(race::id_of(race));
    ciona.race_lock_until_ms = end;
    ciona.best_distance = option::none();
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
    let kind = race::kind_of(race);
    let (lx, ly, light) = brain::race_lure_at(race::seed_of(race), next, kind);
    let shadow = brain::race_shadow(race::seed_of(race), next);
    step(ciona, connectome, clock, lx, ly, light, shadow, false, 0, 0);
    let dist = apart(brain::body_x(&ciona.body), brain::body_y(&ciona.body), lx, ly);
    let better = option::is_none(&ciona.best_distance) || dist < *option::borrow(&ciona.best_distance);
    if (better) ciona.best_distance = option::some(dist);
}

public fun finalize_race(ciona: &mut Ciona, race: &mut LightRace, clock: &Clock, ctx: &TxContext) {
    assert!(option::is_some(&ciona.race) && *option::borrow(&ciona.race) == race::id_of(race), E_RACE);
    assert!(option::is_some(&ciona.best_distance), E_RACE);
    race::finish(race, object::id(ciona), *option::borrow(&ciona.best_distance), ctx.sender(), clock);
    ciona.race = option::none();
}

public fun enter_gauntlet_paid<T>(
    ciona: &mut Ciona,
    g: &mut Gauntlet,
    game: &mut Game<T>,
    sink: &mut Sink<T>,
    payment: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    let refund = ocellus_game::market::pay_listed(
        game, sink, gauntlet::id_of(g), gauntlet::is_open(g, clock.timestamp_ms()), payment, clock, ctx,
    );
    enter_gauntlet(ciona, g, clock);
    refund
}

public(package) fun enter_gauntlet(ciona: &mut Ciona, g: &mut Gauntlet, clock: &Clock) {
    assert!(ciona.stage == STAGE_LARVA, E_STAGE);
    let now = clock.timestamp_ms();
    release_expired(ciona, now);
    assert!(option::is_none(&ciona.race), E_RACE);
    assert!(option::is_none(&ciona.gauntlet) || now > ciona.race_lock_until_ms + rules::race_grace_ms(), E_RACE);
    gauntlet::enter(g, object::id(ciona), clock);
    let (_start, end) = gauntlet::window(g);
    ciona.gauntlet = option::some(gauntlet::id_of(g));
    ciona.race_lock_until_ms = end;
    ciona.travel = 0;
    ciona.failed = false;
}

public fun gauntlet_tick(
    ciona: &mut Ciona,
    g: &Gauntlet,
    connectome: &Connectome,
    clock: &Clock,
) {
    assert!(ciona.stage == STAGE_LARVA, E_STAGE);
    assert!(option::is_some(&ciona.gauntlet) && *option::borrow(&ciona.gauntlet) == gauntlet::id_of(g), E_RACE);
    assert!(gauntlet::has_entered(g, object::id(ciona)), E_RACE);
    let now = clock.timestamp_ms();
    assert!(gauntlet::in_window(g, now), E_RACE);
    assert!(gauntlet::is_revealed(g), E_RACE);
    let next = brain::brain_tick(&ciona.brain) + 1;
    let (cx, cy, radius) = brain::shadow_circle(gauntlet::seed_of(g), next);
    let shadow = apart(brain::body_x(&ciona.body), brain::body_y(&ciona.body), cx, cy) <= radius * radius;
    let x0 = brain::body_x(&ciona.body);
    let y0 = brain::body_y(&ciona.body);
    step(ciona, connectome, clock, cx, cy, 256, shadow, false, 0, 0);
    let x1 = brain::body_x(&ciona.body);
    let y1 = brain::body_y(&ciona.body);
    let dx = if (x1 > x0) { x1 - x0 } else { x0 - x1 };
    let dy = if (y1 > y0) { y1 - y0 } else { y0 - y1 };
    ciona.travel = ciona.travel + dx + dy;
    if (brain::body_yolk(&ciona.body) == 0) ciona.failed = true;
}

public fun finish_gauntlet(ciona: &mut Ciona, g: &mut Gauntlet, clock: &Clock, ctx: &TxContext) {
    assert!(option::is_some(&ciona.gauntlet) && *option::borrow(&ciona.gauntlet) == gauntlet::id_of(g), E_RACE);
    gauntlet::mark(g, object::id(ciona), ciona.travel, ciona.failed, ctx.sender(), clock);
    ciona.gauntlet = option::none();
}

public fun feed(ciona: &mut Ciona, reef: &Reef, clock: &Clock) {
    assert!(ciona.stage == STAGE_ADULT, E_STAGE);
    assert!(option::is_some(&ciona.home) && *option::borrow(&ciona.home) == reef::id_of(reef), E_RACE);
    let now = clock.timestamp_ms();
    assert!(ciona.last_feed_ms == 0 || now >= ciona.last_feed_ms + rules::feed_gap_ms(), E_EARLY);
    ciona.energy = ciona.energy + rules::cell_current(ciona.settling_cell);
    ciona.last_feed_ms = now;
}

#[test_only]
public fun hatch_with_genome(
    bytes: vector<u8>,
    clock: &Clock,
    connectome: &Connectome,
    ctx: &mut TxContext,
): Ciona {
    mint(bytes, clock, connectome, vector[], 0, ctx)
}

#[test_only]
public fun breed_for_test(
    a: &Ciona,
    b: &Ciona,
    rolls: vector<u8>,
    clock: &Clock,
    connectome: &Connectome,
    ctx: &mut TxContext,
): Ciona {
    breed(a, b, rolls, clock, connectome, ctx)
}

#[test_only]
public fun test_adult(c: &mut Ciona) { c.stage = STAGE_ADULT; }

#[test_only]
public fun founder_cap_for_test(ctx: &mut TxContext): FounderCap {
    FounderCap { id: object::new(ctx) }
}

#[test_only]
public fun destroy_founder_cap(cap: FounderCap) {
    let FounderCap { id } = cap;
    id.delete();
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
        home: _, settling_cell: _, race: _, gauntlet: _, race_lock_until_ms: _, best_distance: _, travel: _, failed: _, record: _, energy: _, last_feed_ms: _, last_spawn_ms: _, marking: _, mark_tick: _, mark_hash: _,
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
    c.best_distance = option::some(distance);
}

fun is_home(ciona: &Ciona, reef: &Reef): bool {
    option::is_some(&ciona.home) && *option::borrow(&ciona.home) == reef::id_of(reef)
}

fun depth_near(ciona: &Ciona, cell: u32): bool {
    let band = rules::depth_band(cell);
    let d = brain::body_depth(&ciona.body) as u64;
    let diff = if (d > band) { d - band } else { band - d };
    diff <= rules::depth_radius()
}

fun near(ciona: &Ciona, cell: u32): bool {
    let (cx, cy) = reef::center(cell);
    let d2 = apart(brain::body_x(&ciona.body), brain::body_y(&ciona.body), cx, cy);
    let r = rules::claim_radius();
    d2 <= r * r
}

// Stored coordinates include pos_bias, so a body below the origin is still a positive u64.
fun apart(stored_x: u64, stored_y: u64, lure_x: u64, lure_y: u64): u64 {
    let bx = lure_x + brain::pos_bias();
    let by = lure_y + brain::pos_bias();
    let dx = if (stored_x > bx) { stored_x - bx } else { bx - stored_x };
    let dy = if (stored_y > by) { stored_y - by } else { by - stored_y };
    dx * dx + dy * dy
}

public fun stage_of(c: &Ciona): u8 { c.stage }
public fun generation_of(c: &Ciona): u32 { c.generation }

public fun parents_of(c: &Ciona): vector<ID> {
    let mut out = vector[];
    let mut i = 0;
    while (i < c.parents.length()) {
        out.push_back(c.parents[i]);
        i = i + 1;
    };
    out
}
public fun yolk_of(c: &Ciona): u64 { brain::body_yolk(&c.body) }
public fun x_of(c: &Ciona): u64 { brain::body_x(&c.body) }
public fun y_of(c: &Ciona): u64 { brain::body_y(&c.body) }
public fun heading_of(c: &Ciona): u16 { brain::body_heading(&c.body) }
public fun hash_of(c: &Ciona): vector<u8> { brain::state_hash_bytes(&c.brain) }
public fun tick_of(c: &Ciona): u64 { brain::brain_tick(&c.brain) }
public fun settled_hash(s: &Settled): vector<u8> { s.state_hash }
public fun settled_tick(s: &Settled): u64 { s.tick }
public fun has_score(c: &Ciona): bool { option::is_some(&c.best_distance) }

public fun best_of(c: &Ciona): u64 { *option::borrow(&c.best_distance) }
public fun energy_of(c: &Ciona): u64 { c.energy }
public fun depth_of(c: &Ciona): u32 { brain::body_depth(&c.body) }
public fun travel_of(c: &Ciona): u64 { c.travel }
public fun failed_of(c: &Ciona): bool { c.failed }
public fun spikes_of(c: &Ciona): u64 { brain::spike_count(&c.brain) }

public fun genome_of(c: &Ciona): vector<u8> {
    let mut out = vector[];
    let mut i = 0;
    while (i < c.genome.length()) {
        out.push_back(c.genome[i]);
        i = i + 1;
    };
    out
}

#[test_only]
public fun test_tilt(c: &mut Ciona, tilt: u32) {
    brain::set_body_tilt(&mut c.body, tilt);
}

#[test_only]
public fun test_depth(c: &mut Ciona, depth: u32) {
    brain::set_body_depth(&mut c.body, depth);
}

#[test_only]
public fun test_heading(c: &mut Ciona, heading: u16) {
    brain::set_body_heading(&mut c.body, heading);
}
