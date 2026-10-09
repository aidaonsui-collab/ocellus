#[test_only]
module ocellus_game::ladder_tests;

use ocellus_brain::brain;
use ocellus_game::ciona;
use ocellus_game::race;
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

fun hot(): vector<u8> {
    let mut g = vector[];
    let mut i = 0;
    while (i < 64) {
        let b = if (i < 16) 128u8 else if (i < 24) 64 else if (i < 38) 255 else 0;
        g.push_back(b);
        i = i + 1;
    };
    g
}

fun reveal(light: &mut race::LightRace, clock: &mut clock::Clock) {
    let (start, _end) = race::window(light);
    clock::set_for_testing(clock, start);
    race::reveal_for_testing(light, SEED, clock);
}

fun ticks(larva: &mut ciona::Ciona, light: &race::LightRace, conn: &brain::Connectome, clock: &mut clock::Clock, n: u64) {
    let mut i = 0;
    while (i < n) {
        clock::increment_for_testing(clock, 1);
        ciona::race_tick(larva, light, conn, clock);
        i = i + 1;
    };
}

#[test]
fun kind_zero_matches_the_old_lure_and_the_others_differ() {
    let seed = SEED;
    let (x, y) = brain::race_lure(&seed, 1);
    let (x0, y0, light0) = brain::race_lure_at(&seed, 1, 0);
    assert!(x == 870 && y == 267 && x0 == x && y0 == y && light0 == 256, 1);
    let (fx, fy, fl) = brain::race_lure_at(&seed, 1, 1);
    assert!(fx == 840 && fy == 250 && fl == 256, 2);
    let (ax, ay, al) = brain::race_lure_at(&seed, 1, 2);
    assert!(ax == 870 && ay == 250 && al == 256, 3);
    let (lx, ly, ll) = brain::race_lure_at(&seed, 0, 3);
    let (lx2, ly2, _) = brain::race_lure_at(&seed, 8, 3);
    assert!(ll == 256 && (lx != lx2 || ly != ly2), 4);
    assert!(lx >= 1800 && lx <= 3800 && ly >= 600 && ly <= 2200, 5);
    let (_bx, _by, on) = brain::race_lure_at(&seed, 0, 4);
    let (_cx, _cy, off) = brain::race_lure_at(&seed, 8, 4);
    assert!(on == 256 && off == 0, 6);
}

#[test, expected_failure(abort_code = 7, location = ocellus_game::race)]
fun an_unknown_kind_is_rejected() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let light = race::create_kind(5, &clock, &mut ctx);
    race::destroy(light);
    clock::destroy_for_testing(clock);
}

fun genomes_split(kind: u8, ctx: &mut TxContext) {
    let conn = swim_tests::conn(ctx);
    let mut clock = clock::create_for_testing(ctx);
    let mut calm = ciona::hatch_with_genome(neutral(), &clock, &conn, ctx);
    let mut keen = ciona::hatch_with_genome(hot(), &clock, &conn, ctx);
    let mut light = race::create_kind(kind, &clock, ctx);
    assert!(race::kind_of(&light) == kind, 1);
    ciona::enter_race(&mut calm, &mut light, &clock);
    ciona::enter_race(&mut keen, &mut light, &clock);
    reveal(&mut light, &mut clock);
    ticks(&mut calm, &light, &conn, &mut clock, 8);
    ticks(&mut keen, &light, &conn, &mut clock, 8);
    let (_start, end) = race::window(&light);
    clock::set_for_testing(&mut clock, end);
    ciona::finalize_race(&mut calm, &mut light, &clock, ctx);
    ciona::finalize_race(&mut keen, &mut light, &clock, ctx);
    let calm_d = race::distance_of(&light, object::id(&calm));
    let keen_d = race::distance_of(&light, object::id(&keen));
    assert!(calm_d == ciona::best_of(&calm), 2);
    assert!(keen_d == ciona::best_of(&keen), 3);
    assert!(calm_d != keen_d, 4);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(calm);
    ciona::destroy_ciona(keen);
    race::destroy(light);
    brain::destroy_connectome(conn);
}

#[test] fun drift_track_splits_two_genomes() { let mut ctx = tx_context::dummy(); genomes_split(0, &mut ctx); }
#[test] fun fixed_track_splits_two_genomes() { let mut ctx = tx_context::dummy(); genomes_split(1, &mut ctx); }
#[test] fun axis_track_splits_two_genomes() { let mut ctx = tx_context::dummy(); genomes_split(2, &mut ctx); }
#[test] fun loop_track_splits_two_genomes() { let mut ctx = tx_context::dummy(); genomes_split(3, &mut ctx); }
#[test] fun blink_track_splits_two_genomes() { let mut ctx = tx_context::dummy(); genomes_split(4, &mut ctx); }

#[test]
fun a_pose_below_the_origin_can_still_score() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut larva = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
    let mut i = 0;
    while (i < 10) {
        clock::increment_for_testing(&mut clock, 1);
        ciona::swim(&mut larva, &conn, &clock, 1500, 0, 256, false, false);
        i = i + 1;
    };
    assert!(ciona::y_of(&larva) == 999998, 1);
    let mut light = race::create_kind(0, &clock, &mut ctx);
    ciona::enter_race(&mut larva, &mut light, &clock);
    reveal(&mut light, &mut clock);
    clock::increment_for_testing(&mut clock, 1);
    ciona::race_tick(&mut larva, &light, &conn, &clock);
    assert!(ciona::has_score(&larva), 2);
    ciona::test_set_best(&mut larva, 2_000_000_000);
    let (_start, end) = race::window(&light);
    clock::set_for_testing(&mut clock, end);
    ciona::finalize_race(&mut larva, &mut light, &clock, &ctx);
    assert!(race::distance_of(&light, object::id(&larva)) == 2_000_000_000, 3);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(larva);
    race::destroy(light);
    brain::destroy_connectome(conn);
}
