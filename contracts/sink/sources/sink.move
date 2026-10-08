/// Coins locked here stay locked. This module has no withdraw.
module ocellus_sink::sink;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::object::{Self, UID};
use sui::tx_context::TxContext;

public struct Sink<phantom T> has key {
    id: UID,
    locked: Balance<T>,
}

public fun create<T>(ctx: &mut TxContext): Sink<T> {
    Sink { id: object::new(ctx), locked: balance::zero<T>() }
}

public fun deposit<T>(sink: &mut Sink<T>, coin: Coin<T>) {
    balance::join(&mut sink.locked, coin.into_balance());
}

public fun locked<T>(sink: &Sink<T>): u64 { balance::value(&sink.locked) }

#[test_only]
public fun destroy_for_testing<T>(sink: Sink<T>) {
    let Sink { id, locked } = sink;
    id.delete();
    balance::destroy_for_testing(locked);
}
