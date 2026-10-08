#[test_only]
module ocellus_game::reef_tests;

use ocellus_brain::brain;
use ocellus_game::ciona;
use ocellus_game::race;
use ocellus_game::reef;
use ocellus_game::rules;
use ocellus_game::swim_tests;
use sui::clock;
use sui::event;
use sui::object;

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

fun hatch(ctx: &mut TxContext, clock: &clock::Clock, conn: &brain::Connectome): ciona::Ciona {
    ciona::hatch_with_genome(neutral(), clock, conn, ctx)
}

#[test, expected_failure(abort_code = 6, location = ocellus_game::ciona)]
fun never_swam_cannot_claim() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut larva = hatch(&mut ctx, &clock, &conn);
    clock::set_for_testing(&mut clock, rules::competence_ms());
    let mut home = reef::create(0, &mut ctx);
    ciona::claim(&mut larva, &mut home, 0, &clock);
    abort 0
}

#[test]
fun contest_settle_and_record() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut a = hatch(&mut ctx, &clock, &conn);
    let mut b = hatch(&mut ctx, &clock, &conn);
    ciona::test_ticks(&mut a, rules::competence_ticks());
    ciona::test_ticks(&mut b, rules::competence_ticks());
    let (cx, cy) = reef::center(0);
    ciona::test_pose(&mut a, cx, cy);
    let (bx, by) = reef::center(1);
    ciona::test_pose(&mut b, bx, by);
    clock::set_for_testing(&mut clock, rules::competence_ms());
    let mut home = reef::create(0, &mut ctx);
    ciona::claim(&mut a, &mut home, 0, &clock);
    ciona::claim(&mut b, &mut home, 1, &clock);
    clock::set_for_testing(&mut clock, rules::competence_ms() + rules::attach_ms());
    let hash = ciona::hash_of(&a);
    let tick = ciona::tick_of(&a);
    ciona::complete_settle(&mut a, &clock, &mut ctx);
    let settled = event::events_by_type<ciona::Settled>();
    assert!(settled.length() == 1, 1);
    assert!(ciona::settled_hash(&settled[0]) == hash, 2);
    assert!(ciona::settled_tick(&settled[0]) == tick, 3);
    assert!(ciona::stage_of(&a) == 3, 4);
    assert!(ciona::stage_of(&b) == 2, 5);
    ciona::feed(&mut a, &home, &clock);
    assert!(ciona::energy_of(&a) > 0, 6);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(a);
    ciona::destroy_ciona(b);
    reef::destroy(home);
    brain_destroy(conn);
}

#[test, expected_failure(abort_code = 2, location = ocellus_game::reef)]
fun second_claim_loses_the_cell() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut a = hatch(&mut ctx, &clock, &conn);
    let mut b = hatch(&mut ctx, &clock, &conn);
    ciona::test_ticks(&mut a, rules::competence_ticks());
    ciona::test_ticks(&mut b, rules::competence_ticks());
    let (cx, cy) = reef::center(0);
    ciona::test_pose(&mut a, cx, cy);
    ciona::test_pose(&mut b, cx, cy);
    clock::set_for_testing(&mut clock, rules::competence_ms());
    let mut home = reef::create(0, &mut ctx);
    ciona::claim(&mut a, &mut home, 0, &clock);
    ciona::claim(&mut b, &mut home, 0, &clock);
    abort 0
}

#[test]
fun two_racers_finalize_from_their_own_positions() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut a = hatch(&mut ctx, &clock, &conn);
    let mut b = hatch(&mut ctx, &clock, &conn);
    let seed = x"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
    let mut light = race::create(seed, &clock, &mut ctx);
    ciona::enter_race(&mut a, &mut light, &clock);
    ciona::enter_race(&mut b, &mut light, &clock);
    clock::increment_for_testing(&mut clock, 1);
    ciona::race_tick(&mut a, &light, &conn, &clock);
    clock::increment_for_testing(&mut clock, 1);
    ciona::race_tick(&mut b, &light, &conn, &clock);
    let (_start, end) = race::window(&light);
    clock::set_for_testing(&mut clock, end);
    ciona::finalize_race(&mut a, &mut light, &clock, &ctx);
    ciona::finalize_race(&mut b, &mut light, &clock, &ctx);
    let da = race::distance_of(&light, object::id(&a));
    let db = race::distance_of(&light, object::id(&b));
    assert!(da == ciona::best_of(&a), 1);
    assert!(db == ciona::best_of(&b), 2);
    assert!(da < 1000000000, 3);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(a);
    ciona::destroy_ciona(b);
    race::destroy(light);
    brain_destroy(conn);
}

fun brain_destroy(c: brain::Connectome) {
    brain::destroy_connectome(c);
}
