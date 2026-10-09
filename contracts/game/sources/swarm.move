/// Posted poses for one shard. A larva is stepped only by its owner. The board is the only shared write.
module ocellus_game::swarm;

use sui::clock::Clock;
use sui::event;
use sui::object::{Self, ID, UID};
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::TxContext;

const E_CAP: u64 = 1;
const E_OWNER: u64 = 2;
const E_ABSENT: u64 = 3;
const STALE_MS: u64 = 60 * 1000;
/// Not measured on a loaded localnet. Eight is the bound until that run exists.
const SHARD_CAP: u64 = 8;
const SHADE_RADIUS: u64 = 400;

public struct Pose has store, drop {
    owner: address,
    x: u64,
    y: u64,
    tick: u64,
    at_ms: u64,
}

public struct SwarmBoard has key {
    id: UID,
    shard: u32,
    ids: vector<ID>,
    poses: Table<ID, Pose>,
}

public struct Posted has copy, drop {
    board: ID,
    larva: ID,
    x: u64,
    y: u64,
    tick: u64,
}

public(package) fun create(shard: u32, ctx: &mut TxContext): SwarmBoard {
    SwarmBoard { id: object::new(ctx), shard, ids: vector[], poses: table::new(ctx) }
}

entry fun share_board(shard: u32, ctx: &mut TxContext) {
    transfer::share_object(create(shard, ctx));
}

public fun cap(): u64 { SHARD_CAP }

public fun join(board: &mut SwarmBoard, larva: ID, clock: &Clock, ctx: &TxContext) {
    expire(board, clock.timestamp_ms());
    assert!(!table::contains(&board.poses, larva), E_OWNER);
    assert!(board.ids.length() < SHARD_CAP, E_CAP);
    board.ids.push_back(larva);
    table::add(&mut board.poses, larva, Pose {
        owner: ctx.sender(), x: 0, y: 0, tick: 0, at_ms: clock.timestamp_ms(),
    });
}

public fun post(board: &mut SwarmBoard, larva: ID, x: u64, y: u64, tick: u64, clock: &Clock, ctx: &TxContext) {
    expire(board, clock.timestamp_ms());
    assert!(table::contains(&board.poses, larva), E_ABSENT);
    let pose = table::borrow_mut(&mut board.poses, larva);
    assert!(pose.owner == ctx.sender(), E_OWNER);
    pose.x = x;
    pose.y = y;
    pose.tick = tick;
    pose.at_ms = clock.timestamp_ms();
    event::emit(Posted { board: object::id(board), larva, x, y, tick });
}

public fun shade(board: &SwarmBoard, self: ID, x: u64, y: u64): u64 {
    let mut n = 0u64;
    let mut i = 0;
    while (i < board.ids.length()) {
        let id = board.ids[i];
        if (id != self) {
            let pose = table::borrow(&board.poses, id);
            let dx = if (pose.x > x) { pose.x - x } else { x - pose.x };
            let dy = if (pose.y > y) { pose.y - y } else { y - pose.y };
            if (dx * dx + dy * dy <= SHADE_RADIUS * SHADE_RADIUS) n = n + 1;
        };
        i = i + 1;
    };
    n
}

fun expire(board: &mut SwarmBoard, now: u64) {
    let mut keep = vector[];
    let mut i = 0;
    while (i < board.ids.length()) {
        let id = board.ids[i];
        let at = table::borrow(&board.poses, id).at_ms;
        if (now > at + STALE_MS) {
            table::remove(&mut board.poses, id);
        } else {
            keep.push_back(id);
        };
        i = i + 1;
    };
    board.ids = keep;
}

public fun id_of(board: &SwarmBoard): ID { object::id(board) }

#[test_only]
public fun destroy(board: SwarmBoard) {
    let SwarmBoard { id, shard: _, ids: _, poses } = board;
    table::drop(poses);
    id.delete();
}
