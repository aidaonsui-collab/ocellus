/// One signature opens a session. The delegate may only step that larva until the budget or the deadline.
module ocellus_game::session;

use ocellus_brain::brain::Connectome;
use ocellus_game::ciona::{Self, Ciona};
use ocellus_game::gauntlet::Gauntlet;
use ocellus_game::race::LightRace;
use sui::clock::Clock;
use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::TxContext;

const MODE_SWIM: u8 = 0;
const MODE_RACE: u8 = 1;
const MODE_GAUNTLET: u8 = 2;

const E_MODE: u64 = 1;
const E_BUDGET: u64 = 2;
const E_SENDER: u64 = 3;
const E_TIME: u64 = 4;

public struct SwimSession has key {
    id: UID,
    larva: Ciona,
    owner: address,
    delegate: address,
    left: u64,
    expires_ms: u64,
    mode: u8,
}

public fun open(
    larva: Ciona,
    delegate: address,
    max_ticks: u64,
    expires_ms: u64,
    mode: u8,
    ctx: &mut TxContext,
): SwimSession {
    assert!(mode <= MODE_GAUNTLET, E_MODE);
    assert!(max_ticks > 0, E_BUDGET);
    SwimSession {
        id: object::new(ctx),
        larva,
        owner: ctx.sender(),
        delegate,
        left: max_ticks,
        expires_ms,
        mode,
    }
}

entry fun share_session(
    larva: Ciona,
    delegate: address,
    max_ticks: u64,
    expires_ms: u64,
    mode: u8,
    ctx: &mut TxContext,
) {
    transfer::share_object(open(larva, delegate, max_ticks, expires_ms, mode, ctx));
}

fun allowed(session: &SwimSession, clock: &Clock, ctx: &TxContext) {
    let sender = ctx.sender();
    assert!(sender == session.delegate || sender == session.owner, E_SENDER);
    assert!(session.left > 0, E_BUDGET);
    assert!(clock.timestamp_ms() <= session.expires_ms, E_TIME);
}

public fun step_swim(
    session: &mut SwimSession,
    connectome: &Connectome,
    clock: &Clock,
    lure_x: u64,
    lure_y: u64,
    light: u16,
    shadow: bool,
    pulse: bool,
    ctx: &TxContext,
) {
    allowed(session, clock, ctx);
    assert!(session.mode == MODE_SWIM, E_MODE);
    ciona::swim(&mut session.larva, connectome, clock, lure_x, lure_y, light, shadow, pulse);
    session.left = session.left - 1;
}

public fun step_race(
    session: &mut SwimSession,
    race: &LightRace,
    connectome: &Connectome,
    clock: &Clock,
    ctx: &TxContext,
) {
    allowed(session, clock, ctx);
    assert!(session.mode == MODE_RACE, E_MODE);
    ciona::race_tick(&mut session.larva, race, connectome, clock);
    session.left = session.left - 1;
}

public fun step_gauntlet(
    session: &mut SwimSession,
    g: &Gauntlet,
    connectome: &Connectome,
    clock: &Clock,
    ctx: &TxContext,
) {
    allowed(session, clock, ctx);
    assert!(session.mode == MODE_GAUNTLET, E_MODE);
    ciona::gauntlet_tick(&mut session.larva, g, connectome, clock);
    session.left = session.left - 1;
}

public fun close(session: SwimSession, clock: &Clock, ctx: &TxContext): Ciona {
    let sender = ctx.sender();
    assert!(sender == session.owner || clock.timestamp_ms() > session.expires_ms, E_TIME);
    let SwimSession { id, larva, owner: _, delegate: _, left: _, expires_ms: _, mode: _ } = session;
    id.delete();
    larva
}

public fun left(session: &SwimSession): u64 { session.left }

#[test_only]
public fun destroy(session: SwimSession) {
    let SwimSession { id, larva, owner: _, delegate: _, left: _, expires_ms: _, mode: _ } = session;
    id.delete();
    ciona::destroy_ciona(larva);
}
