// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The keyframe-delta composition layer, its refusals, and the byte-compatibility promise
//! the Chunk Index makes to `gaussian-birth` files.
//!
//! The refusal codes are contract: they are the same strings the Python reference's tests
//! assert on, so a condition that produces `bin-overflow` in one implementation produces it
//! in the other. Correct-file behaviour is proven end to end by `rust/encode-roundtrip.sh`;
//! these are the paths a correct file never reaches.

use std::collections::BTreeMap;

use fourdgs::keyframe_delta::{
    apply_delta, chain_for, check_tiling, keyframe_state, BinArray, State, BIN_MAX,
};
use fourdgs::opcode as op;
use fourdgs::records::{ChunkIndexEntry, DELTA_MODE_CHAINED};
use fourdgs::serialization::{read_record, Cursor, MAGIC};

fn bins(pairs: &[(u8, &[i64], usize)]) -> BTreeMap<u8, BinArray> {
    pairs
        .iter()
        .map(|(a, v, ch)| (*a, BinArray::new(v.to_vec(), *ch)))
        .collect()
}

/// A minimal but complete keyframe: one attribute per gaussian is enough for the composition
/// checks, which never look at what an attribute means.
fn keyframe(ids: &[i64], position: &[i64]) -> State {
    keyframe_state(ids.to_vec(), bins(&[(op::A_POSITION, position, 3)])).expect("valid keyframe")
}

#[test]
fn a_delta_telescopes_over_bins() {
    let state = keyframe(&[10, 20], &[0, 0, 0, 100, 100, 100]);
    // Move both gaussians by the same integer twice; the composed bin is the sum.
    let step = bins(&[(op::A_POSITION, &[1, 2, 3, 1, 2, 3], 3)]);
    let empty = BTreeMap::new();
    let once = apply_delta(&state, &[10, 20], &step, &[], &empty, &[]).expect("first");
    let twice = apply_delta(&once, &[10, 20], &step, &[], &empty, &[]).expect("second");
    let pos = &twice.bins[&op::A_POSITION].values;
    assert_eq!(pos, &[2, 4, 6, 102, 104, 106]);
}

#[test]
fn a_delta_finds_gaussians_by_identity_not_row() {
    // The state lists 20 before 10; a delta naming 10 must reach the right row.
    let state = keyframe(&[20, 10], &[7, 7, 7, 0, 0, 0]);
    let empty = BTreeMap::new();
    let out = apply_delta(
        &state,
        &[10],
        &bins(&[(op::A_POSITION, &[5, 5, 5], 3)]),
        &[],
        &empty,
        &[],
    )
    .expect("update by id");
    let row = out.ids.iter().position(|id| *id == 10).unwrap();
    assert_eq!(
        &out.bins[&op::A_POSITION].values[row * 3..row * 3 + 3],
        &[5, 5, 5]
    );
}

#[test]
fn deaths_then_births_reuse_is_still_refused() {
    let state = keyframe(&[1, 2], &[0, 0, 0, 0, 0, 0]);
    let empty = BTreeMap::new();
    // Kill 1, then try to create 2 which is still live: a birth clash.
    let err = apply_delta(
        &state,
        &[],
        &empty,
        &[2],
        &bins(&[(op::A_POSITION, &[9, 9, 9], 3)]),
        &[1],
    )
    .unwrap_err();
    assert_eq!(err.code, "duplicate-gaussian-id");
}

fn refusal_code(
    state: &State,
    update_ids: &[i64],
    update_bins: &BTreeMap<u8, BinArray>,
    birth_ids: &[i64],
    birth_bins: &BTreeMap<u8, BinArray>,
    death_ids: &[i64],
) -> &'static str {
    apply_delta(
        state,
        update_ids,
        update_bins,
        birth_ids,
        birth_bins,
        death_ids,
    )
    .unwrap_err()
    .code
}

#[test]
fn every_apply_delta_refusal_has_its_code() {
    let state = keyframe(&[1, 2], &[0, 0, 0, 0, 0, 0]);
    let empty = BTreeMap::new();

    // bin-overflow: pushing a composed bin past the signed 32-bit range.
    let at_max = {
        let mut s = state.clone();
        s.bins.get_mut(&op::A_POSITION).unwrap().values[0] = BIN_MAX;
        s
    };
    assert_eq!(
        refusal_code(
            &at_max,
            &[1],
            &bins(&[(op::A_POSITION, &[1, 0, 0], 3)]),
            &[],
            &empty,
            &[],
        ),
        "bin-overflow"
    );

    // invariant-changed-in-update: a GOP-invariant attribute in an update group.
    assert_eq!(
        refusal_code(
            &state,
            &[1],
            &bins(&[(op::A_SIGMA_T, &[1], 1)]),
            &[],
            &empty,
            &[],
        ),
        "invariant-changed-in-update"
    );

    // unknown-attribute-in-update: an attribute the reference state does not carry.
    assert_eq!(
        refusal_code(
            &state,
            &[1],
            &bins(&[(op::A_MOTION, &[1, 1, 1], 3)]),
            &[],
            &empty,
            &[],
        ),
        "unknown-attribute-in-update"
    );

    // unknown-gaussian-id: an update naming a gaussian that is not live.
    assert_eq!(
        refusal_code(
            &state,
            &[99],
            &bins(&[(op::A_POSITION, &[1, 1, 1], 3)]),
            &[],
            &empty,
            &[],
        ),
        "unknown-gaussian-id"
    );

    // stream-element-count-mismatch: an update whose attribute has the wrong row count.
    assert_eq!(
        refusal_code(
            &state,
            &[1, 2],
            &bins(&[(op::A_POSITION, &[1, 1, 1], 3)]),
            &[],
            &empty,
            &[],
        ),
        "stream-element-count-mismatch"
    );

    // incomplete-birth: a birth missing an attribute the state carries.
    assert_eq!(
        refusal_code(&state, &[], &empty, &[3], &BTreeMap::new(), &[]),
        "incomplete-birth"
    );

    // id-in-two-groups: the same id updated and killed by one delta.
    assert_eq!(
        refusal_code(
            &state,
            &[1],
            &bins(&[(op::A_POSITION, &[1, 1, 1], 3)]),
            &[],
            &empty,
            &[1],
        ),
        "id-in-two-groups"
    );

    // duplicate-gaussian-id: a group naming one id twice.
    assert_eq!(
        refusal_code(
            &state,
            &[1, 1],
            &bins(&[(op::A_POSITION, &[1, 1, 1, 2, 2, 2], 3)]),
            &[],
            &empty,
            &[],
        ),
        "duplicate-gaussian-id"
    );

    // unknown-gaussian-id from a death naming a gaussian that is not live.
    assert_eq!(
        refusal_code(&state, &[], &empty, &[], &empty, &[42]),
        "unknown-gaussian-id"
    );
}

#[test]
fn rotation_is_restated_absolutely_in_an_update() {
    let state = keyframe_state(
        vec![1],
        bins(&[
            (op::A_POSITION, &[0, 0, 0], 3),
            (op::A_ROTATION_INDEX, &[3], 1),
            (op::A_ROTATION, &[10, 20, 30], 3),
        ]),
    )
    .unwrap();
    let empty = BTreeMap::new();
    let out = apply_delta(
        &state,
        &[1],
        &bins(&[
            (op::A_ROTATION_INDEX, &[2], 1),
            (op::A_ROTATION, &[1, 2, 3], 3),
        ]),
        &[],
        &empty,
        &[],
    )
    .expect("absolute rotation update");
    // Restated, not summed: 1/2/3, not 11/22/33.
    assert_eq!(out.bins[&op::A_ROTATION].values, vec![1, 2, 3]);
    assert_eq!(out.bins[&op::A_ROTATION_INDEX].values, vec![2]);
}

// --- the chain a seek walks --------------------------------------------------

fn entry(t0: f64, t1: f64, offset: u64, kind: u8, reference: u64, depth: u16) -> ChunkIndexEntry {
    ChunkIndexEntry {
        t0,
        t1,
        chunk_offset: offset,
        chunk_length: 10,
        gaussian_count: 0,
        bands: Vec::new(),
        extended: true,
        kind,
        delta_mode: DELTA_MODE_CHAINED,
        reference_offset: reference,
        keyframe_offset: if kind == 0 { offset } else { 0 },
        depth,
        live_count: 0,
    }
}

#[test]
fn a_chain_walks_back_to_its_keyframe() {
    let index = vec![
        entry(0.0, 1.0, 100, 0, 0, 0),
        entry(1.0, 2.0, 200, 1, 100, 1),
        entry(2.0, 3.0, 300, 1, 200, 2),
    ];
    let chain = chain_for(&index, 2.5).expect("chain");
    let offsets: Vec<u64> = chain.iter().map(|e| e.chunk_offset).collect();
    assert_eq!(offsets, vec![100, 200, 300]);
}

#[test]
fn chain_refusals_have_their_codes() {
    // forward-reference: a delta referencing something not behind it.
    let forward = vec![
        entry(0.0, 1.0, 100, 0, 0, 0),
        entry(1.0, 2.0, 200, 1, 300, 1),
    ];
    assert_eq!(
        chain_for(&forward, 1.5).unwrap_err().code,
        "forward-reference"
    );

    // broken-reference: a reference the index does not name.
    let broken = vec![
        entry(0.0, 1.0, 100, 0, 0, 0),
        entry(1.0, 2.0, 200, 1, 150, 1),
    ];
    assert_eq!(
        chain_for(&broken, 1.5).unwrap_err().code,
        "broken-reference"
    );

    // depth-mismatch: the declared depth disagrees with the walk.
    let wrong_depth = vec![
        entry(0.0, 1.0, 100, 0, 0, 0),
        entry(1.0, 2.0, 200, 1, 100, 5),
    ];
    assert_eq!(
        chain_for(&wrong_depth, 1.5).unwrap_err().code,
        "depth-mismatch"
    );

    // non-tiling-chunks: no chunk covers the instant.
    let gap = vec![entry(0.0, 1.0, 100, 0, 0, 0)];
    assert_eq!(chain_for(&gap, 5.0).unwrap_err().code, "non-tiling-chunks");
}

#[test]
fn tiling_is_enforced() {
    let overlap = vec![entry(0.0, 1.5, 100, 0, 0, 0), entry(1.0, 2.0, 200, 0, 0, 0)];
    assert_eq!(
        check_tiling(&overlap).unwrap_err().code,
        "non-tiling-chunks"
    );

    let gap = vec![entry(0.0, 1.0, 100, 0, 0, 0), entry(1.5, 2.0, 200, 0, 0, 0)];
    assert_eq!(check_tiling(&gap).unwrap_err().code, "non-tiling-chunks");

    let clean = vec![entry(0.0, 1.0, 100, 0, 0, 0), entry(1.0, 2.0, 200, 0, 0, 0)];
    assert!(check_tiling(&clean).is_ok());
}

// --- the byte-compatibility promise -----------------------------------------

#[test]
fn a_non_extended_chunk_index_entry_is_byte_identical() {
    // The shape a gaussian-birth file writes: no keyframe-delta block, so `extended` is
    // false and the encoded bytes carry nothing past the band array.
    let plain = ChunkIndexEntry {
        t0: 0.0,
        t1: 1.5,
        chunk_offset: 42,
        chunk_length: 128,
        gaussian_count: 64,
        bands: vec![(1, 200, 30), (2, 230, 40)],
        ..Default::default()
    };
    let encoded = plain.encode();
    let mut c = Cursor::new(&encoded);
    let record = read_record(&mut c).unwrap();
    let parsed = ChunkIndexEntry::parse(record.content).unwrap();
    assert!(!parsed.extended, "a plain entry must not read as extended");
    assert_eq!(parsed, plain);
    assert_eq!(
        parsed.encode(),
        encoded,
        "re-encoding must be byte-identical"
    );
}

#[test]
fn an_extended_chunk_index_entry_round_trips() {
    let ext = ChunkIndexEntry {
        t0: 1.0,
        t1: 2.0,
        chunk_offset: 500,
        chunk_length: 64,
        gaussian_count: 12,
        bands: Vec::new(),
        extended: true,
        kind: 1,
        delta_mode: DELTA_MODE_CHAINED,
        reference_offset: 400,
        keyframe_offset: 100,
        depth: 3,
        live_count: 48,
    };
    let encoded = ext.encode();
    let mut c = Cursor::new(&encoded);
    let record = read_record(&mut c).unwrap();
    let parsed = ChunkIndexEntry::parse(record.content).unwrap();
    assert_eq!(parsed, ext);
}

/// Every `gaussian-birth` corpus file's Chunk Index entries must parse to non-extended and
/// re-encode byte-for-byte. This is the promise that the appended block never disturbs a
/// file written before it existed. Skipped when the corpus has not been generated.
#[test]
fn gaussian_birth_corpus_chunk_index_is_byte_identical() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/data");
    if !dir.exists() {
        eprintln!("corpus not generated; skipping byte-identity check");
        return;
    }
    let mut checked = 0usize;
    for file in std::fs::read_dir(&dir).unwrap() {
        let path = file.unwrap().path();
        if path.extension().and_then(|e| e.to_str()) != Some("4dgs") {
            continue;
        }
        let data = std::fs::read(&path).unwrap();
        let mut c = Cursor::new(&data[MAGIC.len()..]);
        while c.remaining() >= 9 {
            let Ok(record) = read_record(&mut c) else {
                break;
            };
            if record.opcode != op::CHUNK_INDEX {
                continue;
            }
            let entry = ChunkIndexEntry::parse(record.content).unwrap();
            assert!(
                !entry.extended,
                "{:?}: a gaussian-birth entry read as extended",
                path.file_name().unwrap()
            );
            assert_eq!(
                entry.encode(),
                record.reencoded(op::CHUNK_INDEX),
                "{:?}: re-encoding a chunk index entry changed its bytes",
                path.file_name().unwrap()
            );
            checked += 1;
        }
    }
    assert!(checked > 0, "the corpus carried no chunk index entries");
}

/// Helper: the exact record bytes for `RawRecord`, framed again from its content.
trait Reencode {
    fn reencoded(&self, opcode: u8) -> Vec<u8>;
}
impl Reencode for fourdgs::serialization::RawRecord<'_> {
    fn reencoded(&self, opcode: u8) -> Vec<u8> {
        let mut out = Vec::new();
        fourdgs::serialization::put_record(&mut out, opcode, self.content);
        out
    }
}
