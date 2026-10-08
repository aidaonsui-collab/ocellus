#[test_only]
module ocellus_game::market_tests;

use ocellus_brain::brain;
use ocellus_game::ciona;
use ocellus_game::market;
use ocellus_game::race;
use ocellus_game::rules;
use ocellus_game::swim_tests;
use ocellus_sink::sink;
use sui::clock;
use sui::coin;
use sui::object;

public struct TEST has drop {}

fun bind(ctx: &mut TxContext, clock: &clock::Clock, min: u64, price: u64, max: u64, target: u64): (market::Game<TEST>, sink::Sink<TEST>) {
    market::bind<TEST>(market::cap_for_test(ctx), clock, min, price, max, target, ctx)
}

#[test]
fun hatch_fee_splits_and_price_stops_at_the_cap() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    let (mut game, mut vault) = bind(&mut ctx, &clock, 40, 160, 160, 0);
    let payment = coin::mint_for_testing<TEST>(500, &mut ctx);
    let refund = market::pay_hatch(&mut game, &mut vault, payment, &clock, &mut ctx);
    assert!(coin::value(&refund) == 340, 1);
    assert!(sink::locked(&vault) == 128, 2);
    assert!(market::pool_of(&game) == 32, 3);
    clock::set_for_testing(&mut clock, 60 * 60 * 1000);
    market::sync(&mut game, &clock);
    assert!(market::price_of(&game) == 160, 4);
    let (lo, hi) = market::bounds_of(&game);
    assert!(lo == 40 && hi == 160, 5);
    coin::burn_for_testing(refund);
    clock::destroy_for_testing(clock);
    market::destroy_for_testing(game);
    sink::destroy_for_testing(vault);
}

#[test]
fun quiet_hour_lowers_the_price_and_a_proposal_waits_a_day() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    let (mut game, vault) = bind(&mut ctx, &clock, 40, 80, 160, 5);
    clock::set_for_testing(&mut clock, 60 * 60 * 1000);
    market::sync(&mut game, &clock);
    assert!(market::price_of(&game) == 70, 1);
    let admin = market::admin_for_test(&mut ctx);
    let proposal = market::propose(&admin, 9, &clock, &mut ctx);
    clock::set_for_testing(&mut clock, 60 * 60 * 1000 + 24 * 60 * 60 * 1000);
    market::execute(&mut game, proposal, &clock);
    assert!(market::target_of(&game) == 9, 2);
    let (lo, hi) = market::bounds_of(&game);
    assert!(lo == 40 && hi == 160, 3);
    let early = market::propose(&admin, 1, &clock, &mut ctx);
    let after = clock::timestamp_ms(&clock) + 24 * 60 * 60 * 1000;
    clock::set_for_testing(&mut clock, after);
    market::execute(&mut game, early, &clock);
    market::destroy_admin(admin);
    clock::destroy_for_testing(clock);
    market::destroy_for_testing(game);
    sink::destroy_for_testing(vault);
}

#[test, expected_failure(abort_code = 3, location = ocellus_game::market)]
fun proposal_cannot_execute_early() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    let (mut game, vault) = bind(&mut ctx, &clock, 40, 80, 160, 5);
    let admin = market::admin_for_test(&mut ctx);
    let proposal = market::propose(&admin, 3, &clock, &mut ctx);
    market::execute(&mut game, proposal, &clock);
    abort 0
}

#[test]
fun race_pot_pays_the_closer_larva_after_the_grace() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let (mut game, mut vault) = bind(&mut ctx, &clock, 40, 100, 400, 10);
    let mut a = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
    let mut b = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
    let seed = x"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
    let mut light = race::create(seed, &clock, &mut ctx);
    let refund_a = ciona::enter_paid(&mut a, &mut light, &mut game, &mut vault, coin::mint_for_testing<TEST>(100, &mut ctx), &clock, &mut ctx);
    let refund_b = ciona::enter_paid(&mut b, &mut light, &mut game, &mut vault, coin::mint_for_testing<TEST>(250, &mut ctx), &clock, &mut ctx);
    assert!(coin::value(&refund_b) == 150, 1);
    assert!(sink::locked(&vault) == 160, 2);
    ciona::test_set_best(&mut a, 10);
    ciona::test_set_best(&mut b, 50);
    let (_start, end) = race::window(&light);
    clock::set_for_testing(&mut clock, end);
    ciona::finalize_race(&mut a, &mut light, &clock, &ctx);
    ciona::finalize_race(&mut b, &mut light, &clock, &ctx);
    clock::set_for_testing(&mut clock, end + rules::race_grace_ms() + 1);
    let (prize, player) = market::claim_prize(&mut game, &mut light, &clock, &mut ctx);
    assert!(coin::value(&prize) == 40, 3);
    assert!(player == ctx.sender(), 4);
    coin::burn_for_testing(prize);
    coin::burn_for_testing(refund_a);
    coin::burn_for_testing(refund_b);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(a);
    ciona::destroy_ciona(b);
    race::destroy(light);
    market::destroy_for_testing(game);
    sink::destroy_for_testing(vault);
    brain::destroy_connectome(conn);
}

fun neutral(): vector<u8> {
    let mut g = vector[];
    let mut i = 0;
    while (i < 64) {
        let b = if (i < 16) 128u8 else if (i < 24) 64 else if (i < 32) 85 else if (i < 38) 128 else 0;
        g.push_back(b);
        i = i + 1;
    };
    g
}
