/// Hatch and race-entry prices, the prize pot, and the one-way sink.
/// Hard bounds are fixed in `bind`. The live price can only step by one eighth.
module ocellus_game::market;

use ocellus_game::race::{Self, LightRace};
use ocellus_sink::sink::{Self, Sink};
use std::option::{Self, Option};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::object::{Self, ID, UID};
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::TxContext;

const E_BOUNDS: u64 = 1;
const E_PRICE: u64 = 2;
const E_EARLY: u64 = 3;
const E_BIND: u64 = 4;

const HOUR: u64 = 60 * 60 * 1000;
const DAY: u64 = 24 * HOUR;
const SINK_BPS: u64 = 8000;
const BPS: u64 = 10000;

public struct BindCap has key, store { id: UID }
public struct PriceAdminCap has key, store { id: UID }

public struct Game<phantom T> has key {
    id: UID,
    sink: ID,
    pool: Balance<T>,
    pots: Table<ID, Balance<T>>,
    price: u64,
    min: u64,
    max: u64,
    target: u64,
    window_ms: u64,
    window_start: u64,
    actions: u64,
    settle_bounty: u64,
}

public struct Proposal has key {
    id: UID,
    execute_after: u64,
    target: u64,
}

fun init(ctx: &mut TxContext) {
    transfer::public_transfer(BindCap { id: object::new(ctx) }, ctx.sender());
    transfer::public_transfer(PriceAdminCap { id: object::new(ctx) }, ctx.sender());
}

public fun bind<T>(
    cap: BindCap,
    clock: &Clock,
    min: u64,
    price: u64,
    max: u64,
    target: u64,
    ctx: &mut TxContext,
): (Game<T>, Sink<T>) {
    assert!(min > 0 && min <= price && price <= max, E_BOUNDS);
    let BindCap { id } = cap;
    id.delete();
    let sink = sink::create<T>(ctx);
    let sink_id = object::id(&sink);
    let game = Game<T> {
        id: object::new(ctx),
        sink: sink_id,
        pool: balance::zero<T>(),
        pots: table::new<ID, Balance<T>>(ctx),
        price,
        min,
        max,
        target,
        window_ms: HOUR,
        window_start: clock.timestamp_ms(),
        actions: 0,
        settle_bounty: price / 4,
    };
    (game, sink)
}

public fun sync<T>(game: &mut Game<T>, clock: &Clock) {
    roll(game, clock.timestamp_ms());
}

public fun pay_hatch<T>(
    game: &mut Game<T>,
    sink: &mut Sink<T>,
    payment: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(object::id(sink) == game.sink, E_BIND);
    charge(game, sink, payment, option::none(), clock, ctx)
}

public fun pay_entry<T>(
    game: &mut Game<T>,
    sink: &mut Sink<T>,
    race: &LightRace,
    payment: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(object::id(sink) == game.sink, E_BIND);
    charge(game, sink, payment, option::some(race::id_of(race)), clock, ctx)
}

public fun claim_prize<T>(
    game: &mut Game<T>,
    race: &mut LightRace,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<T>, address) {
    let (player, _distance) = race::take_winner(race, clock);
    let race_id = race::id_of(race);
    assert!(table::contains(&game.pots, race_id), E_PRICE);
    let pot = table::remove(&mut game.pots, race_id);
    (coin::from_balance(pot, ctx), player)
}

public fun propose(cap: &PriceAdminCap, target: u64, clock: &Clock, ctx: &mut TxContext): Proposal {
    let _cap = cap;
    Proposal {
        id: object::new(ctx),
        execute_after: clock.timestamp_ms() + DAY,
        target,
    }
}

public fun execute<T>(game: &mut Game<T>, proposal: Proposal, clock: &Clock) {
    let Proposal { id, execute_after, target } = proposal;
    assert!(clock.timestamp_ms() >= execute_after, E_EARLY);
    id.delete();
    game.target = target;
}

public fun price_of<T>(game: &Game<T>): u64 { game.price }
public fun bounds_of<T>(game: &Game<T>): (u64, u64) { (game.min, game.max) }
public fun target_of<T>(game: &Game<T>): u64 { game.target }
public fun pool_of<T>(game: &Game<T>): u64 { balance::value(&game.pool) }

fun charge<T>(
    game: &mut Game<T>,
    sink: &mut Sink<T>,
    payment: Coin<T>,
    race: Option<ID>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    roll(game, clock.timestamp_ms());
    assert!(coin::value(&payment) >= game.price, E_PRICE);
    let mut payment = payment;
    let mut fee = coin::split(&mut payment, game.price, ctx);
    let sink_amt = game.price * SINK_BPS / BPS;
    let to_sink = coin::split(&mut fee, sink_amt, ctx);
    sink::deposit(sink, to_sink);
    let prize = coin::into_balance(fee);
    if (option::is_some(&race)) {
        let id = *option::borrow(&race);
        if (table::contains(&game.pots, id)) {
            balance::join(table::borrow_mut(&mut game.pots, id), prize);
        } else {
            table::add(&mut game.pots, id, prize);
        };
    } else {
        balance::join(&mut game.pool, prize);
    };
    game.actions = game.actions + 1;
    payment
}

fun roll<T>(game: &mut Game<T>, now: u64) {
    if (now < game.window_start + game.window_ms) return;
    let step = game.price / 8;
    if (game.actions > game.target) {
        let next = game.price + step;
        game.price = if (next > game.max) game.max else next;
    } else if (game.actions < game.target) {
        let next = if (game.price > step) game.price - step else 0;
        game.price = if (next < game.min) game.min else next;
    };
    game.actions = 0;
    game.window_start = now;
}

#[test_only]
public fun cap_for_test(ctx: &mut TxContext): BindCap {
    BindCap { id: object::new(ctx) }
}

#[test_only]
public fun admin_for_test(ctx: &mut TxContext): PriceAdminCap {
    PriceAdminCap { id: object::new(ctx) }
}

#[test_only]
public fun destroy_admin(cap: PriceAdminCap) {
    let PriceAdminCap { id } = cap;
    id.delete();
}

#[test_only]
public fun destroy_for_testing<T>(game: Game<T>) {
    let Game {
        id, sink: _, pool, pots, price: _, min: _, max: _, target: _,
        window_ms: _, window_start: _, actions: _, settle_bounty: _,
    } = game;
    table::destroy_empty(pots);
    balance::destroy_for_testing(pool);
    id.delete();
}
