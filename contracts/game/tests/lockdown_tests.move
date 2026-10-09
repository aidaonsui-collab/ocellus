#[test_only]
module ocellus_game::lockdown_tests;

use ocellus_brain::brain;
use ocellus_game::ciona;
use ocellus_game::market;
use ocellus_game::race;
use ocellus_game::reef;
use ocellus_game::rules;
use ocellus_game::swim_tests;
use ocellus_sink::sink;
use sui::clock;
use sui::coin;
use sui::event;
use sui::test_scenario as ts;

public struct TEST has drop {}

const SEED: vector<u8> = x"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";

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

fun ready(ctx: &mut TxContext, clock: &clock::Clock, conn: &brain::Connectome, cell: u32): ciona::Ciona {
    let mut c = ciona::hatch_with_genome(neutral(), clock, conn, ctx);
    ciona::test_ticks(&mut c, rules::competence_ticks());
    let (x, y) = reef::center(cell);
    ciona::test_pose(&mut c, x, y);
    ciona::test_depth(&mut c, (rules::depth_band(cell) as u32));
    c
}

// ---- races: free swimming is locked from entry until the race ends

#[test, expected_failure(abort_code = 11, location = ocellus_game::ciona)]
fun swim_while_entered_aborts() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut a = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
    let mut light = race::create(&clock, &mut ctx);
    ciona::enter_race(&mut a, &mut light, &clock);
    clock::increment_for_testing(&mut clock, 1);
    ciona::swim(&mut a, &conn, &clock, 1500, 0, 256, false, false);
    abort 0
}

#[test]
fun swim_is_free_again_after_the_race_ends() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut a = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
    let mut light = race::create(&clock, &mut ctx);
    ciona::enter_race(&mut a, &mut light, &clock);
    let (_start, end) = race::window(&light);
    clock::set_for_testing(&mut clock, end);
    ciona::swim(&mut a, &conn, &clock, 1500, 0, 256, false, false);
    assert!(ciona::tick_of(&a) == 1, 1);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(a);
    race::destroy(light);
    brain::destroy_connectome(conn);
}

#[test, expected_failure(abort_code = 10, location = ocellus_game::ciona)]
fun race_tick_before_the_seed_is_revealed_aborts() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut a = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
    let mut light = race::create(&clock, &mut ctx);
    ciona::enter_race(&mut a, &mut light, &clock);
    let (start, _end) = race::window(&light);
    clock::set_for_testing(&mut clock, start + 1);
    ciona::race_tick(&mut a, &light, &conn, &clock);
    abort 0
}

#[test, expected_failure(abort_code = 1, location = ocellus_game::race)]
fun seed_cannot_be_revealed_during_registration() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let mut light = race::create(&clock, &mut ctx);
    race::reveal_for_testing(&mut light, SEED, &clock);
    abort 0
}

#[test, expected_failure(abort_code = 6, location = ocellus_game::market)]
fun paid_entry_after_registration_closes_aborts() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let (mut game, mut vault) = market::bind<TEST>(market::cap_for_test(&mut ctx), &clock, 40, 100, 400, 10, &mut ctx);
    let mut a = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
    let mut light = race::create(&clock, &mut ctx);
    let (start, _end) = race::window(&light);
    clock::set_for_testing(&mut clock, start);
    let refund = ciona::enter_paid(&mut a, &mut light, &mut game, &mut vault, coin::mint_for_testing<TEST>(100, &mut ctx), &clock, &mut ctx);
    coin::burn_for_testing(refund);
    abort 0
}

#[test]
fun a_finalized_larva_can_enter_the_next_race() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut a = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
    let mut first = race::create(&clock, &mut ctx);
    ciona::enter_race(&mut a, &mut first, &clock);
    ciona::test_set_best(&mut a, 7);
    let (_start, end) = race::window(&first);
    clock::set_for_testing(&mut clock, end);
    ciona::finalize_race(&mut a, &mut first, &clock, &ctx);
    let mut second = race::create(&clock, &mut ctx);
    ciona::enter_race(&mut a, &mut second, &clock);
    assert!(race::has_entered(&second, sui::object::id(&a)), 1);
    assert!(!ciona::has_score(&a), 2);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(a);
    race::destroy(first);
    race::destroy(second);
    brain::destroy_connectome(conn);
}

// ---- settlement: claims expire, can be evicted by anyone, and the larva can fail

#[test]
fun expired_claim_is_evicted_and_the_cell_reclaimed() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut a = ready(&mut ctx, &clock, &conn, 0);
    let mut b = ready(&mut ctx, &clock, &conn, 0);
    clock::set_for_testing(&mut clock, rules::competence_ms());
    let mut home = reef::create(0, &mut ctx);
    ciona::claim(&mut a, &mut home, 0, &clock);
    clock::set_for_testing(&mut clock, rules::competence_ms() + rules::settle_window_ms() + 1);
    reef::evict_expired(&mut home, 0, &clock);
    assert!(!reef::is_taken(&home, 0), 1);
    assert!(event::events_by_type<reef::CellReleased>().length() == 1, 2);
    ciona::claim(&mut b, &mut home, 0, &clock);
    assert!(ciona::stage_of(&b) == 2, 3);
    // the evicted larva fails its settlement and becomes a fossil; b's claim is untouched
    ciona::fail_settle(&mut a, &mut home, &clock);
    assert!(ciona::stage_of(&a) == 4, 4);
    assert!(reef::is_taken(&home, 0), 5);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(a);
    ciona::destroy_ciona(b);
    reef::destroy(home);
    brain::destroy_connectome(conn);
}

#[test]
fun failing_a_settle_releases_its_own_claim() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut a = ready(&mut ctx, &clock, &conn, 3);
    clock::set_for_testing(&mut clock, rules::competence_ms());
    let mut home = reef::create(0, &mut ctx);
    ciona::claim(&mut a, &mut home, 3, &clock);
    clock::set_for_testing(&mut clock, rules::competence_ms() + rules::settle_window_ms() + 1);
    ciona::fail_settle(&mut a, &mut home, &clock);
    assert!(ciona::stage_of(&a) == 4, 1);
    assert!(!reef::is_taken(&home, 3), 2);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(a);
    reef::destroy(home);
    brain::destroy_connectome(conn);
}

#[test, expected_failure(abort_code = 6, location = ocellus_game::reef)]
fun eviction_inside_the_settle_window_aborts() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut a = ready(&mut ctx, &clock, &conn, 0);
    clock::set_for_testing(&mut clock, rules::competence_ms());
    let mut home = reef::create(0, &mut ctx);
    ciona::claim(&mut a, &mut home, 0, &clock);
    clock::set_for_testing(&mut clock, rules::competence_ms() + rules::settle_window_ms());
    reef::evict_expired(&mut home, 0, &clock);
    abort 0
}

#[test, expected_failure(abort_code = 5, location = ocellus_game::reef)]
fun an_attached_adult_cannot_be_evicted() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut a = ready(&mut ctx, &clock, &conn, 0);
    clock::set_for_testing(&mut clock, rules::competence_ms());
    let mut home = reef::create(0, &mut ctx);
    ciona::claim(&mut a, &mut home, 0, &clock);
    clock::set_for_testing(&mut clock, rules::competence_ms() + rules::attach_ms());
    ciona::complete_settle(&mut a, &mut home, &clock, &mut ctx);
    clock::set_for_testing(&mut clock, rules::competence_ms() + rules::settle_window_ms() + 1);
    reef::evict_expired(&mut home, 0, &clock);
    abort 0
}

#[test, expected_failure(abort_code = 8, location = ocellus_game::ciona)]
fun failing_a_settle_inside_the_window_aborts() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut a = ready(&mut ctx, &clock, &conn, 0);
    clock::set_for_testing(&mut clock, rules::competence_ms());
    let mut home = reef::create(0, &mut ctx);
    ciona::claim(&mut a, &mut home, 0, &clock);
    ciona::fail_settle(&mut a, &mut home, &clock);
    abort 0
}

// ---- market: the game and sink are shared; proposals belong to one game and wait a day

#[test]
fun bind_shares_the_game_and_sink_and_the_admin_executes_after_a_day() {
    let mut s = ts::begin(@0xAD);
    let mut clock = clock::create_for_testing(ts::ctx(&mut s));
    market::bind_shared<TEST>(market::cap_for_test(ts::ctx(&mut s)), &clock, 40, 80, 160, 5, ts::ctx(&mut s));
    let admin = market::admin_for_test(ts::ctx(&mut s));
    ts::next_tx(&mut s, @0xAD);
    let mut game = ts::take_shared<market::Game<TEST>>(&s);
    let vault = ts::take_shared<sink::Sink<TEST>>(&s);
    market::propose(&admin, &game, 9, &clock, ts::ctx(&mut s));
    ts::next_tx(&mut s, @0xAD);
    let proposal = ts::take_from_sender<market::Proposal>(&s);
    clock::set_for_testing(&mut clock, 24 * 60 * 60 * 1000);
    market::execute(&mut game, proposal, &clock);
    assert!(market::target_of(&game) == 9, 1);
    ts::return_shared(game);
    ts::return_shared(vault);
    market::destroy_admin(admin);
    clock::destroy_for_testing(clock);
    ts::end(s);
}

#[test, expected_failure(abort_code = 5, location = ocellus_game::market)]
fun a_proposal_cannot_move_another_game() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    let (one, _v1) = market::bind<TEST>(market::cap_for_test(&mut ctx), &clock, 40, 80, 160, 5, &mut ctx);
    let (mut other, _v2) = market::bind<TEST>(market::cap_for_test(&mut ctx), &clock, 40, 80, 160, 5, &mut ctx);
    let admin = market::admin_for_test(&mut ctx);
    let p = market::propose_for_testing(&admin, &one, 9, &clock, &mut ctx);
    clock::set_for_testing(&mut clock, 24 * 60 * 60 * 1000);
    market::execute(&mut other, p, &clock);
    abort 0
}
