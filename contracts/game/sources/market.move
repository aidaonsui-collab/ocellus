/// Hatch and race-entry prices, the prize pot, and the one-way sink.
/// Hard bounds are fixed in `bind`. The live price can only step by one eighth.
module ocellus_game::market;

use ocellus_game::gauntlet::{Self, Gauntlet};
use ocellus_game::race::{Self, LightRace};
use ocellus_sink::sink::{Self, Sink};
use std::option::{Self, Option};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, ID, UID};
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::TxContext;

const E_BOUNDS: u64 = 1;
const E_PRICE: u64 = 2;
const E_EARLY: u64 = 3;
const E_BIND: u64 = 4;
const E_GAME: u64 = 5;
const E_CLOSED: u64 = 6;

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

/// Owned by the admin who proposed it; executable on its own game after the timelock.
public struct Proposal has key {
    id: UID,
    game: ID,
    execute_after: u64,
    target: u64,
}

public struct TargetProposed has copy, drop { game: ID, proposal: ID, target: u64, execute_after: u64 }
public struct TargetChanged has copy, drop { game: ID, target: u64 }
public struct PrizePaid has copy, drop { race: ID, player: address, amount: u64 }

fun init(ctx: &mut TxContext) {
    transfer::public_transfer(BindCap { id: object::new(ctx) }, ctx.sender());
    transfer::public_transfer(PriceAdminCap { id: object::new(ctx) }, ctx.sender());
}

/// Binds the coin type once and shares the game and its sink.
public fun bind_shared<T>(
    cap: BindCap,
    clock: &Clock,
    min: u64,
    price: u64,
    max: u64,
    target: u64,
    ctx: &mut TxContext,
) {
    let (game, sink) = bind<T>(cap, clock, min, price, max, target, ctx);
    transfer::share_object(game);
    sink::share(sink);
}

public(package) fun bind<T>(
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

/// Entry fees are paid through ciona::enter_paid, which also enters the larva.
public(package) fun pay_listed<T>(
    game: &mut Game<T>,
    sink: &mut Sink<T>,
    pot: ID,
    open: bool,
    payment: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(object::id(sink) == game.sink, E_BIND);
    assert!(open, E_CLOSED);
    charge(game, sink, payment, option::some(pot), clock, ctx)
}

public(package) fun pay_entry<T>(
    game: &mut Game<T>,
    sink: &mut Sink<T>,
    race: &LightRace,
    payment: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    pay_listed(game, sink, race::id_of(race), race::is_open(race, clock.timestamp_ms()), payment, clock, ctx)
}

/// Anyone can trigger the payout once results close; the pot always goes to the winner.
fun pay_out<T>(game: &mut Game<T>, pot_id: ID, player: address, ctx: &mut TxContext) {
    assert!(table::contains(&game.pots, pot_id), E_PRICE);
    let pot = table::remove(&mut game.pots, pot_id);
    event::emit(PrizePaid { race: pot_id, player, amount: balance::value(&pot) });
    transfer::public_transfer(coin::from_balance(pot, ctx), player);
}

public fun claim_prize<T>(
    game: &mut Game<T>,
    race: &mut LightRace,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (player, _distance) = race::take_winner(race, clock);
    pay_out(game, race::id_of(race), player, ctx);
}

public fun claim_gauntlet<T>(
    game: &mut Game<T>,
    g: &mut Gauntlet,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (player, _travel) = gauntlet::take_winner(g, clock);
    pay_out(game, gauntlet::id_of(g), player, ctx);
}

/// Creates a proposal for this game and gives it to the admin. It can execute after one day.
public fun propose<T>(cap: &PriceAdminCap, game: &Game<T>, target: u64, clock: &Clock, ctx: &mut TxContext) {
    let p = new_proposal(cap, game, target, clock, ctx);
    transfer::transfer(p, ctx.sender());
}

fun new_proposal<T>(cap: &PriceAdminCap, game: &Game<T>, target: u64, clock: &Clock, ctx: &mut TxContext): Proposal {
    let _cap = cap;
    let p = Proposal {
        id: object::new(ctx),
        game: object::id(game),
        execute_after: clock.timestamp_ms() + DAY,
        target,
    };
    event::emit(TargetProposed { game: p.game, proposal: object::id(&p), target, execute_after: p.execute_after });
    p
}

public fun execute<T>(game: &mut Game<T>, proposal: Proposal, clock: &Clock) {
    let Proposal { id, game: gid, execute_after, target } = proposal;
    assert!(gid == object::id(game), E_GAME);
    assert!(clock.timestamp_ms() >= execute_after, E_EARLY);
    id.delete();
    game.target = target;
    event::emit(TargetChanged { game: gid, target });
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
public fun propose_for_testing<T>(cap: &PriceAdminCap, game: &Game<T>, target: u64, clock: &Clock, ctx: &mut TxContext): Proposal {
    new_proposal(cap, game, target, clock, ctx)
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
