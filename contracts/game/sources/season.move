/// A season names the connectome and the package version. Larvae stay in the event stream.
/// The hash is checked off-chain against research/connectome.v1.bin. Move does not rehash the graph.
module ocellus_game::season;

use ocellus_brain::brain::Connectome;
use ocellus_game::ciona::canonical_hash_bytes;
use sui::clock::Clock;
use sui::object::{Self, ID, UID};
use sui::tx_context::TxContext;

const VERSION: u64 = 1;
const E_HASH: u64 = 1;
const E_OPEN: u64 = 2;

public struct Season has key {
    id: UID,
    start_ms: u64,
    end_ms: u64,
    connectome: ID,
    data_hash: vector<u8>,
    encoding: vector<u8>,
    package_version: u64,
    closed: bool,
}

public fun open(connectome: &Connectome, clock: &Clock, ctx: &mut TxContext): Season {
    let hash = ocellus_brain::brain::data_hash_of(connectome);
    assert!(hash == canonical_hash_bytes(), E_HASH);
    Season {
        id: object::new(ctx),
        start_ms: clock.timestamp_ms(),
        end_ms: 0,
        connectome: object::id(connectome),
        data_hash: hash,
        encoding: b"connectome.v1.bin",
        package_version: VERSION,
        closed: false,
    }
}

public fun close(season: &mut Season, clock: &Clock) {
    assert!(!season.closed, E_OPEN);
    season.end_ms = clock.timestamp_ms();
    season.closed = true;
}

public fun version(): u64 { VERSION }
public fun hash_of(season: &Season): vector<u8> { season.data_hash }
public fun encoding_of(season: &Season): vector<u8> { season.encoding }
public fun connectome_of(season: &Season): ID { season.connectome }

#[test_only]
public fun destroy(season: Season) {
    let Season {
        id, start_ms: _, end_ms: _, connectome: _, data_hash: _, encoding: _, package_version: _, closed: _,
    } = season;
    id.delete();
}
