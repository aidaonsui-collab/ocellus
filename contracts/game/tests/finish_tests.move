#[test_only]
module ocellus_game::finish_tests;

use ocellus_brain::brain;
use ocellus_game::ciona;
use ocellus_game::reef;
use ocellus_game::season;
use ocellus_game::session;
use ocellus_game::swarm;
use ocellus_game::swim_tests;
use sui::clock;
use sui::object;
use sui::test_scenario as ts;

fun rolls(): vector<u8> {
    let mut g = vector[];
    let mut i = 0;
    while (i < 128) {
        g.push_back(0);
        i = i + 1;
    };
    g
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

fun adult(ctx: &mut TxContext, clock: &clock::Clock, conn: &brain::Connectome, allele: u8): ciona::Ciona {
    let mut bytes = neutral();
    *vector::borrow_mut(&mut bytes, 38) = allele;
    *vector::borrow_mut(&mut bytes, 39) = allele;
    *vector::borrow_mut(&mut bytes, 40) = allele;
    let mut c = ciona::hatch_with_genome(bytes, clock, conn, ctx);
    ciona::test_adult(&mut c);
    c
}

#[test]
fun two_currents_land_in_different_places() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut a = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
    let mut b = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
    clock::increment_for_testing(&mut clock, 1);
    ciona::swim_current(&mut a, &conn, &clock, 1500, 0, 256, false, false, 1);
    clock::increment_for_testing(&mut clock, 1);
    ciona::swim_current(&mut b, &conn, &clock, 1500, 0, 256, false, false, 2);
    assert!(ciona::x_of(&a) != ciona::x_of(&b), 1);
    let (dx, dy) = brain::drift(1, 1000000, 1000000);
    assert!(dx == 1 && dy == 1, 2);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(a);
    ciona::destroy_ciona(b);
    brain::destroy_connectome(conn);
}

#[test, expected_failure(abort_code = 4, location = ocellus_game::ciona)]
fun shared_allele_blocks_spawning() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let a = adult(&mut ctx, &clock, &conn, 7);
    let b = adult(&mut ctx, &clock, &conn, 7);
    let child = ciona::breed_for_test(&a, &b, rolls(), &clock, &conn, &mut ctx);
    ciona::destroy_ciona(child);
    abort 0
}

#[test]
fun a_compatible_pair_mints_a_child_with_both_parents() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let a = adult(&mut ctx, &clock, &conn, 1);
    let b = adult(&mut ctx, &clock, &conn, 2);
    let child = ciona::breed_for_test(&a, &b, rolls(), &clock, &conn, &mut ctx);
    let parents = ciona::parents_of(&child);
    assert!(parents.length() == 2, 1);
    assert!(parents[0] == object::id(&a) && parents[1] == object::id(&b), 2);
    assert!(ciona::generation_of(&child) == 1, 3);
    assert!(ciona::stage_of(&child) == 1, 4);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(a);
    ciona::destroy_ciona(b);
    ciona::destroy_ciona(child);
    brain::destroy_connectome(conn);
}

#[test, expected_failure(abort_code = 2, location = ocellus_game::swarm)]
fun a_stranger_cannot_post_for_someone_else() {
    let owner = @0xA11;
    let stranger = @0xB0B;
    let mut scenario = ts::begin(owner);
    let conn = swim_tests::conn(ts::ctx(&mut scenario));
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    let mut board = swarm::create(0, ts::ctx(&mut scenario));
    let mut a = ciona::hatch_with_genome(neutral(), &clock, &conn, ts::ctx(&mut scenario));
    let mut b = ciona::hatch_with_genome(neutral(), &clock, &conn, ts::ctx(&mut scenario));
    swarm::join(&mut board, object::id(&a), &clock, ts::ctx(&mut scenario));
    swarm::join(&mut board, object::id(&b), &clock, ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, stranger);
    swarm::post(&mut board, object::id(&a), 1, 1, 1, &clock, ts::ctx(&mut scenario));
    abort 0
}

#[test]
fun a_neighbor_shades_the_next_tick() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut board = swarm::create(0, &mut ctx);
    let mut a = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
    let mut b = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
    swarm::join(&mut board, object::id(&a), &clock, &ctx);
    swarm::join(&mut board, object::id(&b), &clock, &ctx);
    swarm::post(&mut board, object::id(&a), brain::pos_bias(), brain::pos_bias(), 0, &clock, &ctx);
    clock::increment_for_testing(&mut clock, 1);
    ciona::swim_swarm(&mut b, &conn, &mut board, &clock, 1500, 0, 256, false, false, &ctx);
    assert!(swarm::shade(&board, object::id(&b), brain::pos_bias(), brain::pos_bias()) >= 1, 1);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(a);
    ciona::destroy_ciona(b);
    swarm::destroy(board);
    brain::destroy_connectome(conn);
}

#[test]
fun marking_opens_and_closes_a_clip() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut larva = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
    ciona::mark(&mut larva);
    assert!(ciona::marking(&larva), 1);
    clock::increment_for_testing(&mut clock, 1);
    ciona::swim(&mut larva, &conn, &clock, 1500, 0, 256, false, false);
    ciona::mark(&mut larva);
    assert!(!ciona::marking(&larva), 2);
    clock::destroy_for_testing(clock);
    ciona::destroy_ciona(larva);
    brain::destroy_connectome(conn);
}

#[test]
fun a_season_names_the_published_connectome() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let mut season = season::open(&conn, &clock, &mut ctx);
    let cap = season::cap_for_test(&mut ctx);
    assert!(season::hash_of(&season) == ciona::canonical_hash_bytes(), 1);
    assert!(season::encoding_of(&season) == b"connectome.v1.bin", 2);
    assert!(season::version() == 1, 3);
    clock::increment_for_testing(&mut clock, 5);
    season::close(&cap, &mut season, &clock);
    season::destroy_cap(cap);
    clock::destroy_for_testing(clock);
    season::destroy(season);
    brain::destroy_connectome(conn);
}

#[test]
fun a_delegate_can_spend_one_swim_and_the_owner_gets_the_larva_back() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    let larva = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
    let mut session = session::open(larva, @0x0, 2, 1000, 0, &mut ctx);
    clock::increment_for_testing(&mut clock, 1);
    session::step_swim(&mut session, &conn, &clock, 1500, 0, 256, false, false, &ctx);
    assert!(session::left(&session) == 1, 1);
    session::destroy(session);
    clock::destroy_for_testing(clock);
    brain::destroy_connectome(conn);
}

#[test]
fun a_stranger_closing_an_expired_session_returns_the_larva_to_the_owner() {
    let owner = @0xA;
    let stranger = @0xB;
    let mut sc = ts::begin(owner);
    let conn = swim_tests::conn(sc.ctx());
    let mut clock = clock::create_for_testing(sc.ctx());
    let larva = ciona::hatch_with_genome(neutral(), &clock, &conn, sc.ctx());
    let larva_id = object::id(&larva);
    let s = session::open(larva, @0x0, 2, 1000, 0, sc.ctx());
    sc.next_tx(stranger);
    clock::increment_for_testing(&mut clock, 1001);
    session::close(s, &clock, sc.ctx());
    sc.next_tx(owner);
    assert!(!ts::has_most_recent_for_address<ciona::Ciona>(stranger), 1);
    let back = sc.take_from_address_by_id<ciona::Ciona>(owner, larva_id);
    ciona::destroy_ciona(back);
    clock::destroy_for_testing(clock);
    brain::destroy_connectome(conn);
    sc.end();
}

#[test, expected_failure(abort_code = 1, location = ocellus_game::swarm)]
fun the_ninth_larva_is_over_the_cap() {
    let mut ctx = tx_context::dummy();
    let conn = swim_tests::conn(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let mut board = swarm::create(0, &mut ctx);
    let mut i = 0;
    while (i < 9) {
        let larva = ciona::hatch_with_genome(neutral(), &clock, &conn, &mut ctx);
        swarm::join(&mut board, object::id(&larva), &clock, &ctx);
        ciona::destroy_ciona(larva);
        i = i + 1;
    };
    abort 0
}
