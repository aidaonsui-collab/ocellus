#[test_only]
module ocellus_game::modes_tests;

use ocellus_brain::brain;
use ocellus_game::ciona;
use ocellus_game::gauntlet;
use ocellus_game::race;
use ocellus_game::reef;
use ocellus_game::rules;
use ocellus_game::swim_tests;
use sui::clock;
use sui::object;

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

fun hatch(ctx: &mut TxContext, clock: &clock::Clock, conn: &brain::Connectome): ciona::Ciona {
    ciona::hatch_with_genome(neutral(), clock, conn, ctx)
}

fun reveal(g: &mut gauntlet::Gauntlet, clock: &mut clock::Clock) {
    let (start, _end) = gauntlet::window(g);
    clock::set_for_testing(clock, start);
    gauntlet::reveal_for_testing(g, SEED, clock);
}

fun run(larva: &mut ciona::Ciona, g: &gauntlet::Gauntlet, conn: &brain::Connectome, clock: &mut clock::Clock, n: u64) {
    let mut i = 0;
    while (i < n) {
        clock::increment_for_testing(clock, 1);
        ciona::gauntlet_tick(larva, g, conn, clock);
        i = i + 1;
    };
}

#[test]
fun shadow_circle_matches_the_formula() {
    let seed = SEED;
    let (x, y, r) = brain::shadow_circle(&seed, 1);
    assert!(x == 110 && y == 80 && r == 503, 1);
}

#[test]
fun an_intact_larva_travels_farther_and_burns_more_yolk() {
    let mut ctx = tx_context::dummy();
    let mut intact_conn = swim_tests::conn(&mut ctx);
    let mut blank_conn = swim_tests::conn(&mut ctx);
    brain::blank_pr2_for_test(&mut blank_conn);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut intact = hatch(&mut ctx, &clock, &intact_conn);
    let mut blank = hatch(&mut ctx, &clock, &blank_conn);
    let mut g = gauntlet::create(&clock, &mut ctx);
    ciona::enter_gauntlet(&mut intact, &mut g, &clock);
    ciona::enter_gauntlet(&mut blank, &mut g, &clock);
    reveal(&mut g, &mut clock);
    run(&mut intact, &g, &intact_conn, &mut clock, 8);
    run(&mut blank, &g, &blank_conn, &mut clock, 8);
    assert!(ciona::travel_of(&intact) > ciona::travel_of(&blank), 1);
    assert!(ciona::yolk_of(&intact) < ciona::yolk_of(&blank), 2);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(intact);
    ciona::destroy_ciona(blank);
    gauntlet::destroy(g);
    brain::destroy_connectome(intact_conn);
    brain::destroy_connectome(blank_conn);
}

#[test]
fun empty_yolk_is_marked_failed_and_the_larva_is_not_deleted() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut larva = hatch(&mut ctx, &clock, &conn);
    ciona::set_yolk(&mut larva, 1);
    let mut g = gauntlet::create(&clock, &mut ctx);
    ciona::enter_gauntlet(&mut larva, &mut g, &clock);
    reveal(&mut g, &mut clock);
    clock::increment_for_testing(&mut clock, 1);
    ciona::gauntlet_tick(&mut larva, &g, &conn, &clock);
    assert!(ciona::failed_of(&larva), 1);
    assert!(ciona::stage_of(&larva) == 1, 2);
    let (_start, end) = gauntlet::window(&g);
    clock::set_for_testing(&mut clock, end);
    ciona::finish_gauntlet(&mut larva, &mut g, &clock, &ctx);
    assert!(gauntlet::failed_of(&g, object::id(&larva)), 3);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(larva);
    gauntlet::destroy(g);
    brain::destroy_connectome(conn);
}

#[test]
fun steady_light_holds_depth_and_dimming_follows_tilt() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut held = hatch(&mut ctx, &clock, &conn);
    let mut up = hatch(&mut ctx, &clock, &conn);
    let mut down = hatch(&mut ctx, &clock, &conn);
    let bias = brain::depth_bias();
    ciona::test_tilt(&mut held, bias + 200);
    ciona::test_tilt(&mut up, bias + 200);
    ciona::test_tilt(&mut down, bias - 200);
    clock::increment_for_testing(&mut clock, 1);
    ciona::swim(&mut held, &conn, &clock, 1500, 0, 256, false, false);
    clock::increment_for_testing(&mut clock, 1);
    ciona::swim(&mut up, &conn, &clock, 1500, 0, 0, false, false);
    clock::increment_for_testing(&mut clock, 1);
    ciona::swim(&mut down, &conn, &clock, 1500, 0, 0, false, false);
    assert!(ciona::depth_of(&held) == bias, 1);
    assert!(ciona::depth_of(&up) > bias, 2);
    assert!(ciona::depth_of(&down) < bias, 3);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(held);
    ciona::destroy_ciona(up);
    ciona::destroy_ciona(down);
    brain::destroy_connectome(conn);
}

#[test, expected_failure(abort_code = 7, location = ocellus_game::ciona)]
fun claim_rejects_a_cell_that_is_close_but_deep() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut larva = hatch(&mut ctx, &clock, &conn);
    ciona::test_ticks(&mut larva, rules::competence_ticks());
    let (x, y) = reef::center(8);
    ciona::test_pose(&mut larva, x, y);
    clock::set_for_testing(&mut clock, rules::competence_ms());
    let mut home = reef::create(0, &mut ctx);
    ciona::claim(&mut larva, &mut home, 8, &clock);
    abort 0
}

#[test]
fun the_far_column_is_claimable_at_its_own_depth() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut larva = hatch(&mut ctx, &clock, &conn);
    ciona::test_ticks(&mut larva, rules::competence_ticks());
    let (x, y) = reef::center(15);
    ciona::test_pose(&mut larva, x, y);
    let band = rules::depth_band(15);
    let hi = rules::depth_bias() + 512;
    assert!(band <= hi && band >= rules::depth_bias(), 1);
    ciona::test_depth(&mut larva, (band as u32));
    clock::set_for_testing(&mut clock, rules::competence_ms());
    let mut home = reef::create(0, &mut ctx);
    ciona::claim(&mut larva, &mut home, 15, &clock);
    assert!(ciona::stage_of(&larva) == 2, 2);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(larva);
    reef::destroy(home);
    brain::destroy_connectome(conn);
}

#[test]
fun a_missed_race_does_not_block_the_gauntlet() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut larva = hatch(&mut ctx, &clock, &conn);
    let mut light = race::create(&clock, &mut ctx);
    ciona::enter_race(&mut larva, &mut light, &clock);
    let (_start, end) = race::window(&light);
    clock::set_for_testing(&mut clock, end + rules::race_grace_ms() + 1);
    let mut g = gauntlet::create(&clock, &mut ctx);
    ciona::enter_gauntlet(&mut larva, &mut g, &clock);
    assert!(gauntlet::has_entered(&g, object::id(&larva)), 1);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(larva);
    race::destroy(light);
    gauntlet::destroy(g);
    brain::destroy_connectome(conn);
}

#[test]
fun the_higher_current_cell_feeds_more() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut shallow = hatch(&mut ctx, &clock, &conn);
    let mut deep = hatch(&mut ctx, &clock, &conn);
    ciona::test_ticks(&mut shallow, rules::competence_ticks());
    ciona::test_ticks(&mut deep, rules::competence_ticks());
    let (sx, sy) = reef::center(0);
    let (dx, dy) = reef::center(16);
    ciona::test_pose(&mut shallow, sx, sy);
    ciona::test_pose(&mut deep, dx, dy);
    clock::set_for_testing(&mut clock, rules::competence_ms());
    let mut home = reef::create(0, &mut ctx);
    ciona::claim(&mut shallow, &mut home, 0, &clock);
    ciona::claim(&mut deep, &mut home, 16, &clock);
    clock::set_for_testing(&mut clock, rules::competence_ms() + rules::attach_ms());
    ciona::complete_settle(&mut shallow, &mut home, &clock, &mut ctx);
    ciona::complete_settle(&mut deep, &mut home, &clock, &mut ctx);
    ciona::feed(&mut shallow, &home, &clock);
    ciona::feed(&mut deep, &home, &clock);
    assert!(ciona::energy_of(&deep) > ciona::energy_of(&shallow), 1);
    assert!(ciona::yolk_of(&shallow) > 0, 2);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(shallow);
    ciona::destroy_ciona(deep);
    reef::destroy(home);
    brain::destroy_connectome(conn);
}

fun swim_n(larva: &mut ciona::Ciona, conn: &brain::Connectome, clock: &mut clock::Clock, n: u64, light: u16) {
    let mut i = 0;
    while (i < n) {
        clock::increment_for_testing(clock, 1);
        ciona::swim(larva, conn, clock, 1500, 0, light, false, false);
        i = i + 1;
    };
}

#[test]
fun a_swum_larva_is_not_quieter_and_a_rest_matches_a_fresh_one() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let before = brain::data_hash_of(&conn);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut fresh = hatch(&mut ctx, &clock, &conn);
    let genome = ciona::genome_of(&fresh);
    swim_n(&mut fresh, &conn, &mut clock, 1, 256);
    let fresh_spikes = ciona::spikes_of(&fresh);

    let mut swum = hatch(&mut ctx, &clock, &conn);
    swim_n(&mut swum, &conn, &mut clock, 4, 256);
    let mid = ciona::spikes_of(&swum);
    ciona::test_pose(&mut swum, 0, 0);
    ciona::test_heading(&mut swum, 0);
    ciona::test_tilt(&mut swum, (brain::depth_bias() as u32));
    swim_n(&mut swum, &conn, &mut clock, 1, 256);
    assert!(ciona::spikes_of(&swum) - mid > fresh_spikes, 1);

    swim_n(&mut swum, &conn, &mut clock, 16, 0);
    let rested = ciona::spikes_of(&swum);
    ciona::test_pose(&mut swum, 0, 0);
    ciona::test_heading(&mut swum, 0);
    ciona::test_tilt(&mut swum, (brain::depth_bias() as u32));
    swim_n(&mut swum, &conn, &mut clock, 1, 256);
    let got = ciona::spikes_of(&swum) - rested;
    assert!(got > fresh_spikes, 2);
    assert!(ciona::genome_of(&swum) == genome, 3);
    assert!(brain::data_hash_of(&conn) == before, 4);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(fresh);
    ciona::destroy_ciona(swum);
    brain::destroy_connectome(conn);
}
