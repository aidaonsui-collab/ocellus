#[test_only]
module ocellus_game::hatch_tests;

use ocellus_game::ciona;
use ocellus_game::market;
use ocellus_game::swim_tests;
use ocellus_sink::sink;
use sui::clock;
use sui::coin;
use sui::random;
use sui::test_scenario as ts;

public struct TEST has drop {}

fun bind(ctx: &mut TxContext, clock: &clock::Clock): (market::Game<TEST>, sink::Sink<TEST>) {
    market::bind<TEST>(market::cap_for_test(ctx), clock, 40, 160, 160, 0, ctx)
}

fun random_ready(s: &mut ts::Scenario): random::Random {
    random::create_for_testing(ts::ctx(s));
    ts::next_tx(s, @0x0);
    let mut r = ts::take_shared<random::Random>(s);
    random::update_randomness_state_for_testing(
        &mut r,
        0,
        x"0000000000000000000000000000000000000000000000000000000000000001",
        ts::ctx(s),
    );
    r
}

#[test]
fun the_paid_hatch_splits_the_fee_and_mints_a_larva() {
    let mut s = ts::begin(@0x0);
    let mut r = random_ready(&mut s);
    let mut clock = clock::create_for_testing(ts::ctx(&mut s));
    let conn = swim_tests::conn(ts::ctx(&mut s));
    let (mut game, mut vault) = bind(ts::ctx(&mut s), &clock);
    let payment = coin::mint_for_testing<TEST>(500, ts::ctx(&mut s));
    ciona::hatch_paid(&mut game, &mut vault, payment, &r, &clock, &conn, ts::ctx(&mut s));
    ts::next_tx(&mut s, @0x0);
    let larva = ts::take_from_sender<ciona::Ciona>(&s);
    let refund = ts::take_from_sender<coin::Coin<TEST>>(&s);
    assert!(ciona::generation_of(&larva) == 0, 1);
    assert!(ciona::parents_of(&larva).length() == 0, 2);
    assert!(coin::value(&refund) == 340, 3);
    assert!(sink::locked(&vault) == 128, 4);
    assert!(market::pool_of(&game) == 32, 5);
    coin::burn_for_testing(refund);
    ciona::destroy_ciona(larva);
    clock::destroy_for_testing(clock);
    market::destroy_for_testing(game);
    sink::destroy_for_testing(vault);
    brain_destroy(conn);
    ts::return_shared(r);
    ts::end(s);
}

#[test]
fun the_founder_cap_mints_without_a_fee() {
    let mut s = ts::begin(@0x0);
    let mut r = random_ready(&mut s);
    let mut clock = clock::create_for_testing(ts::ctx(&mut s));
    let conn = swim_tests::conn(ts::ctx(&mut s));
    let cap = ciona::founder_cap_for_test(ts::ctx(&mut s));
    ciona::hatch_founder(&cap, &r, &clock, &conn, ts::ctx(&mut s));
    ts::next_tx(&mut s, @0x0);
    let larva = ts::take_from_sender<ciona::Ciona>(&s);
    assert!(ciona::stage_of(&larva) == 1, 1);
    ciona::destroy_ciona(larva);
    ciona::destroy_founder_cap(cap);
    clock::destroy_for_testing(clock);
    brain_destroy(conn);
    ts::return_shared(r);
    ts::end(s);
}

#[test, expected_failure(abort_code = 2, location = ocellus_game::market)]
fun a_short_payment_does_not_mint() {
    let mut s = ts::begin(@0x0);
    let mut r = random_ready(&mut s);
    let clock = clock::create_for_testing(ts::ctx(&mut s));
    let conn = swim_tests::conn(ts::ctx(&mut s));
    let (mut game, mut vault) = bind(ts::ctx(&mut s), &clock);
    let payment = coin::mint_for_testing<TEST>(10, ts::ctx(&mut s));
    ciona::hatch_paid(&mut game, &mut vault, payment, &r, &clock, &conn, ts::ctx(&mut s));
    abort 0
}

fun brain_destroy(c: ocellus_brain::brain::Connectome) {
    ocellus_brain::brain::destroy_connectome(c);
}
