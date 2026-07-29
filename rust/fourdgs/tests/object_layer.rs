// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The object layer: the two records round-trip, and a track composes onto base state.
//!
//! The test that earns its keep is `track_composes_onto_base_center`. It checks the claim
//! the layer rests on — that a track transforms the base state rather than replacing it —
//! and the record round-trips prove the wire format. The `object_id` stream through a full
//! chunk decode is covered here across the full u32 range and cross-implementation by
//! the conformance corpus (Python writes, Rust decodes), which is where an end-to-end
//! object file is exercised.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use fourdgs::chunk::DecodedChunk;
use fourdgs::codec;
use fourdgs::object_layer::ObjectLayer;
use fourdgs::opcode as op;
use fourdgs::quantization::Steps;
use fourdgs::readable::BytesReadable;
use fourdgs::reader::OpenMode;
use fourdgs::records::{
    ChunkIndexEntry, Footer, Header, ObjectTable, ObjectTableEntry, ObjectTrack, Quantization,
    WindowTable, TRAJECTORY_LINEAR,
};
use fourdgs::serialization::MAGIC;
use fourdgs::stream::encode_stream;
use fourdgs::SceneReader;

// xyzw quaternion for a +90 degree rotation about z: R*(1,0,0) = (0,1,0).
const Q_Z90: [f64; 4] = [
    0.0,
    0.0,
    std::f64::consts::FRAC_1_SQRT_2,
    std::f64::consts::FRAC_1_SQRT_2,
];
const Q_ID: [f64; 4] = [0.0, 0.0, 0.0, 1.0];

fn content(encoded: &[u8]) -> &[u8] {
    // Strip the 1-byte opcode and 8-byte length framing.
    &encoded[9..]
}

fn quantization() -> Quantization {
    Quantization {
        scheme: "uniform-v1".into(),
        pos_origin: vec![0.0; 3],
        step_pos: 1.0,
        step_scale_log: 1.0,
        step_rot: 1.0,
        step_rgb: 1.0,
        step_alpha: 1.0,
        step_motion: 1.0,
        step_time: 1.0,
        step_sigma_log: 1.0,
        step_sh: 1,
        bounds: BTreeMap::new(),
        sh_bit_depths: Vec::new(),
    }
}

fn streams_with_object_id(values: &[i64], channels: usize) -> Vec<u8> {
    let count = values.len() / channels;
    let mut streams = Vec::new();
    let rows: [(u8, Vec<i64>, usize); 11] = [
        (op::A_POSITION, [1, 0, 0].repeat(count), 3),
        (op::A_SCALE, [0, 0, 0].repeat(count), 3),
        (op::A_ROTATION_INDEX, vec![3; count], 1),
        (op::A_ROTATION, [0, 0, 0].repeat(count), 3),
        (op::A_COLOR, [0, 0, 0].repeat(count), 3),
        (op::A_OPACITY, vec![1; count], 1),
        (op::A_MOTION, [0, 0, 0].repeat(count), 3),
        (op::A_MU_T, vec![0; count], 1),
        (op::A_SIGMA_T, vec![0; count], 1),
        (op::A_FLAGS, vec![op::FLAG_NEVER_FADES; count], 1),
        (op::A_WINDOW_INDEX, vec![0; count], 1),
    ];
    for (attribute, bins, width) in rows {
        streams.extend(encode_stream(attribute, &bins, width, codec::DEFLATE, 1, false).unwrap());
    }
    streams.extend(
        encode_stream(op::A_OBJECT_ID, values, channels, codec::DEFLATE, 1, false).unwrap(),
    );
    streams
}

fn object_file(indexed: bool, duplicate_table: bool) -> Vec<u8> {
    let mut out = MAGIC.to_vec();
    out.extend(
        Header {
            duration_sec: 1.0,
            gaussian_count: 1,
            aabb: vec![0.0, 0.0, 0.0, 1.0, 0.0, 0.0],
            cutoff: 0.05,
            temporal_model: "gaussian-birth".into(),
            ..Default::default()
        }
        .encode(&[]),
    );
    out.extend(quantization().encode(&[]));
    out.extend(
        WindowTable {
            windows: vec![(0.0, 1.0)],
        }
        .encode(),
    );
    let table = ObjectTable {
        embedding_dim: 0,
        entries: vec![ObjectTableEntry {
            object_id: 7,
            label: "tracked".into(),
            ..Default::default()
        }],
    }
    .encode(b"")
    .unwrap();
    out.extend(&table);
    if duplicate_table {
        out.extend(&table);
    }
    out.extend(
        ObjectTrack {
            object_id: 7,
            interpolation: TRAJECTORY_LINEAR,
            times: vec![0.0, 1.0],
            rotations: vec![Q_Z90, Q_Z90],
            translations: vec![[10.0, 0.0, 0.0], [10.0, 0.0, 0.0]],
        }
        .encode(b"")
        .unwrap(),
    );

    let chunk_at = out.len() as u64;
    let chunk = fourdgs::records::encode_chunk(0.0, 1.0, 0, 1, &streams_with_object_id(&[7], 1));
    out.extend(&chunk);

    let summary_start = if indexed {
        let start = out.len() as u64;
        out.extend(
            ChunkIndexEntry {
                t0: 0.0,
                t1: 1.0,
                chunk_offset: chunk_at,
                chunk_length: chunk.len() as u64,
                gaussian_count: 1,
                bands: Vec::new(),
            }
            .encode(),
        );
        start
    } else {
        0
    };
    out.extend(
        Footer {
            summary_start,
            summary_offset_start: 0,
            summary_crc: 0,
        }
        .encode(),
    );
    out.extend(MAGIC);
    out
}

type ByteRange = (u64, u64);

fn object_file_with_unrelated_ranges() -> (Vec<u8>, ByteRange, ByteRange, ByteRange) {
    let mut out = MAGIC.to_vec();
    out.extend(
        Header {
            duration_sec: 1.0,
            gaussian_count: 1,
            aabb: vec![0.0, 0.0, 0.0, 1.0, 0.0, 0.0],
            cutoff: 0.05,
            temporal_model: "gaussian-birth".into(),
            ..Default::default()
        }
        .encode(&[]),
    );
    out.extend(quantization().encode(&[]));
    out.extend(
        WindowTable {
            windows: vec![(0.0, 1.0)],
        }
        .encode(),
    );

    let table = ObjectTable {
        embedding_dim: 4096,
        entries: vec![
            ObjectTableEntry {
                object_id: 7,
                label: "visible".into(),
                ..Default::default()
            },
            ObjectTableEntry {
                object_id: 8,
                label: "unrelated".into(),
                embedding: Some(vec![0.0; 4096]),
                ..Default::default()
            },
        ],
    }
    .encode(b"")
    .unwrap();
    let table_range = (out.len() as u64, table.len() as u64);
    out.extend(table);

    let track7 = ObjectTrack {
        object_id: 7,
        interpolation: TRAJECTORY_LINEAR,
        times: vec![0.0, 1.0],
        rotations: vec![Q_Z90, Q_Z90],
        translations: vec![[10.0, 0.0, 0.0], [10.0, 0.0, 0.0]],
    }
    .encode(b"")
    .unwrap();
    let track7_range = (out.len() as u64, track7.len() as u64);
    out.extend(track7);

    let track8 = ObjectTrack {
        object_id: 8,
        interpolation: TRAJECTORY_LINEAR,
        times: vec![0.0, 1.0],
        rotations: vec![Q_ID, Q_ID],
        translations: vec![[0.0; 3], [1.0, 0.0, 0.0]],
    }
    .encode(b"")
    .unwrap();
    let track8_range = (out.len() as u64, track8.len() as u64);
    out.extend(track8);
    // A future registry value on an unrelated track must not affect object 7's instant.
    out[track8_range.0 as usize + 9 + 4] = 2;

    let chunk_at = out.len() as u64;
    let chunk = fourdgs::records::encode_chunk(0.0, 1.0, 0, 1, &streams_with_object_id(&[7], 1));
    out.extend(&chunk);
    let summary_start = out.len() as u64;
    out.extend(
        ChunkIndexEntry {
            t0: 0.0,
            t1: 1.0,
            chunk_offset: chunk_at,
            chunk_length: chunk.len() as u64,
            gaussian_count: 1,
            bands: Vec::new(),
        }
        .encode(),
    );
    out.extend(
        Footer {
            summary_start,
            summary_offset_start: 0,
            summary_crc: 0,
        }
        .encode(),
    );
    out.extend(MAGIC);
    (out, table_range, track7_range, track8_range)
}

struct CountingSource {
    bytes: Vec<u8>,
    reads: Rc<RefCell<Vec<ByteRange>>>,
}

impl fourdgs::Readable for CountingSource {
    fn size(&mut self) -> fourdgs::Result<u64> {
        Ok(self.bytes.len() as u64)
    }

    fn read(&mut self, offset: u64, length: u64) -> fourdgs::Result<Vec<u8>> {
        self.reads.borrow_mut().push((offset, length));
        fourdgs::BytesReadable::new(&self.bytes).read(offset, length)
    }
}

fn overlaps(a: ByteRange, b: ByteRange) -> bool {
    a.0 < b.0 + b.1 && b.0 < a.0 + a.1
}

#[test]
fn object_table_round_trips_with_and_without_optional_fields() {
    let table = ObjectTable {
        embedding_dim: 4,
        entries: vec![
            ObjectTableEntry {
                object_id: 7,
                label: "vehicle".to_string(),
                anchor: [1.5, 0.0, -3.25],
                dynamics: Some(([1.0, 0.0, 0.0], [0.0, 0.0, 0.5], [0.0, 0.0, 0.0])),
                embedding: Some(vec![0.1, 0.2, 0.3, 0.4]),
            },
            ObjectTableEntry {
                object_id: 8,
                ..Default::default()
            },
        ],
    };
    let parsed = ObjectTable::parse(content(&table.encode(b"").unwrap())).unwrap();
    assert_eq!(parsed, table);
    // Object 8 carried neither dynamics nor an embedding, and reads back that way.
    assert!(parsed.entries[1].dynamics.is_none());
    assert!(parsed.entries[1].embedding.is_none());
}

#[test]
fn object_table_no_embedding_space_omits_the_flag() {
    let table = ObjectTable {
        embedding_dim: 0,
        entries: vec![ObjectTableEntry {
            object_id: 3,
            label: "x".to_string(),
            ..Default::default()
        }],
    };
    let parsed = ObjectTable::parse(content(&table.encode(b"").unwrap())).unwrap();
    assert_eq!(parsed.embedding_dim, 0);
    assert!(parsed.entries[0].embedding.is_none());
}

#[test]
fn object_track_round_trips() {
    let track = ObjectTrack {
        object_id: 7,
        interpolation: TRAJECTORY_LINEAR,
        times: vec![0.0, 1.0, 2.0],
        rotations: vec![Q_ID, Q_ID, Q_Z90],
        translations: vec![[0.0, 0.0, 0.0], [5.0, 0.0, 0.0], [10.0, 0.0, 0.0]],
    };
    let parsed = ObjectTrack::parse(content(&track.encode(b"").unwrap())).unwrap();
    assert_eq!(parsed, track);
}

#[test]
fn track_composes_onto_base_center_and_orientation() {
    // A tracked object (id 7) of two gaussians and one background gaussian (id 0). The
    // base centre here stands in for position + motion*(t - mu_t): the per-gaussian motion
    // has already moved the gaussian inside the object's frame, and the track transports
    // it. That is the compose, base first, the design turns on.
    let mut centers: Vec<f32> = vec![1.0, 0.0, 0.0, 2.0, 0.0, 0.0, -5.0, -5.0, -5.0];
    let mut orientations: Vec<f32> = vec![
        0.0, 0.0, 0.0, 1.0, // tracked identity
        0.0, 0.0, 0.0, 1.0, // tracked identity
        0.0, 0.0, 0.0, 1.0, // background identity
    ];
    let object_ids = [7, 7, 0];
    let layer = ObjectLayer {
        table: None,
        tracks: vec![ObjectTrack {
            object_id: 7,
            interpolation: TRAJECTORY_LINEAR,
            times: vec![0.0, 1.0],
            rotations: vec![Q_Z90, Q_Z90],
            translations: vec![[10.0, 0.0, 0.0], [10.0, 0.0, 0.0]],
        }],
    };
    layer
        .apply(&mut centers, &mut orientations, &object_ids, 0.5)
        .unwrap();

    // (1,0,0) rotated +90 about z is (0,1,0), then +T -> (10,1,0); likewise (2,0,0)->(10,2,0).
    assert!((centers[0] - 10.0).abs() < 1e-4 && (centers[1] - 1.0).abs() < 1e-4);
    assert!((centers[3] - 10.0).abs() < 1e-4 && (centers[4] - 2.0).abs() < 1e-4);
    for row in 0..2 {
        for axis in 0..4 {
            assert!(
                (orientations[row * 4 + axis] - Q_Z90[axis] as f32).abs() < 1e-5,
                "tracked orientation row {row}, axis {axis}"
            );
        }
    }
    // Background (id 0) is never touched.
    assert_eq!(&centers[6..9], &[-5.0, -5.0, -5.0]);
    assert_eq!(&orientations[8..12], &[0.0, 0.0, 0.0, 1.0]);
}

#[test]
fn no_track_is_identity() {
    let mut centers: Vec<f32> = vec![1.0, 2.0, 3.0];
    let mut orientations: Vec<f32> = vec![0.0, 0.0, 0.0, 1.0];
    ObjectLayer::default()
        .apply(&mut centers, &mut orientations, &[7], 0.0)
        .unwrap();
    assert_eq!(centers, vec![1.0, 2.0, 3.0]);
    assert_eq!(orientations, vec![0.0, 0.0, 0.0, 1.0]);
}

#[test]
fn track_clamps_outside_sample_range() {
    let mut centers: Vec<f32> = vec![0.0, 0.0, 0.0];
    let mut orientations: Vec<f32> = vec![0.0, 0.0, 0.0, 1.0];
    let layer = ObjectLayer {
        table: None,
        tracks: vec![ObjectTrack {
            object_id: 7,
            interpolation: TRAJECTORY_LINEAR,
            times: vec![1.0, 2.0],
            rotations: vec![Q_ID, Q_ID],
            translations: vec![[3.0, 0.0, 0.0], [9.0, 0.0, 0.0]],
        }],
    };
    // Before the first sample the pose is clamped to the first, never extrapolated.
    layer
        .apply(&mut centers, &mut orientations, &[7], 0.0)
        .unwrap();
    assert_eq!(&centers[..], &[3.0, 0.0, 0.0]);
}

#[test]
fn refusals_name_their_fault() {
    // Duplicate object id in the table.
    let dup = ObjectTable {
        embedding_dim: 0,
        entries: vec![
            ObjectTableEntry {
                object_id: 7,
                ..Default::default()
            },
            ObjectTableEntry {
                object_id: 7,
                ..Default::default()
            },
        ],
    };
    assert!(dup.check().is_err());

    // A track that names the background.
    let bg = ObjectTrack {
        object_id: 0,
        interpolation: TRAJECTORY_LINEAR,
        times: vec![0.0],
        rotations: vec![Q_ID],
        translations: vec![[0.0, 0.0, 0.0]],
    };
    assert!(bg.check().is_err());

    // Non-increasing track times.
    let backwards = ObjectTrack {
        object_id: 7,
        interpolation: TRAJECTORY_LINEAR,
        times: vec![1.0, 1.0],
        rotations: vec![Q_ID, Q_ID],
        translations: vec![[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]],
    };
    assert!(backwards.check().is_err());

    // A zero-norm track quaternion is not a rotation.
    let no_rotation = ObjectTrack {
        object_id: 7,
        interpolation: TRAJECTORY_LINEAR,
        times: vec![0.0],
        rotations: vec![[0.0, 0.0, 0.0, 0.0]],
        translations: vec![[0.0, 0.0, 0.0]],
    };
    assert!(no_rotation.check().is_err());

    // Two tracks for one object.
    let two = ObjectLayer {
        table: None,
        tracks: vec![
            ObjectTrack {
                object_id: 7,
                times: vec![0.0],
                rotations: vec![Q_ID],
                translations: vec![[0.0, 0.0, 0.0]],
                ..Default::default()
            },
            ObjectTrack {
                object_id: 7,
                times: vec![0.0],
                rotations: vec![Q_ID],
                translations: vec![[1.0, 0.0, 0.0]],
                ..Default::default()
            },
        ],
    };
    assert!(two.check().is_err());
}

#[test]
fn scene_reader_composes_authoritative_object_motion_on_both_paths() {
    let streamed = fourdgs::read_bytes(&object_file(false, false)).expect("stream object file");
    let state = streamed
        .state_at(0.5)
        .expect("reconstruct streamed public state");
    assert_eq!(state.count(), 1);
    assert!((state.centers[0] - 10.0).abs() < 1e-4);
    assert!((state.centers[1] - 1.0).abs() < 1e-4);
    for (got, want) in state.orientations.iter().zip(Q_Z90) {
        assert!((*got - want as f32).abs() < 1e-5);
    }

    for mode in [OpenMode::Sequential, OpenMode::Indexed] {
        let bytes = object_file(mode == OpenMode::Indexed, false);
        let mut reader =
            SceneReader::open_with(BytesReadable::new(&bytes), mode).expect("open object file");
        let state = reader.state_at(0.5, 0).expect("reconstruct tracked state");
        assert_eq!(state.count(), 1);
        assert!((state.centers[0] - 10.0).abs() < 1e-4);
        assert!((state.centers[1] - 1.0).abs() < 1e-4);
        for (got, want) in state.orientations.iter().zip(Q_Z90) {
            assert!((*got - want as f32).abs() < 1e-5);
        }
        assert_eq!(reader.provenance_count(), 0);
        assert_eq!(reader.objects().unwrap().tracks.len(), 1);
    }
}

#[test]
fn indexed_state_fetches_and_caches_only_referenced_object_tracks() {
    let (bytes, table_range, track7_range, track8_range) = object_file_with_unrelated_ranges();
    let reads = Rc::new(RefCell::new(Vec::new()));
    let source = CountingSource {
        bytes,
        reads: Rc::clone(&reads),
    };
    let mut reader = SceneReader::open_with(source, OpenMode::Indexed).expect("open indexed");
    reads.borrow_mut().clear();

    let state = reader.state_at(0.5, 0).expect("reconstruct object 7");
    assert!((state.centers[0] - 10.0).abs() < 1e-4);
    let state_reads = reads.borrow().clone();
    assert!(
        state_reads.contains(&track7_range),
        "the visible object's track is fetched: {state_reads:?}"
    );
    assert!(
        state_reads
            .iter()
            .all(|range| !overlaps(*range, table_range)),
        "state_at must leave the Object Table lazy: {state_reads:?}"
    );
    assert!(
        state_reads
            .iter()
            .all(|range| !overlaps(*range, track8_range)),
        "state_at must leave unrelated tracks lazy: {state_reads:?}"
    );

    reads.borrow_mut().clear();
    reader.state_at(0.5, 0).expect("reuse the same instant");
    assert!(
        reads.borrow().is_empty(),
        "the gaussian chunk and object track are cached"
    );
}

#[test]
fn applying_a_layer_does_not_sample_unreferenced_tracks() {
    let layer = ObjectLayer {
        table: None,
        tracks: vec![
            ObjectTrack {
                object_id: 7,
                interpolation: TRAJECTORY_LINEAR,
                times: vec![0.0],
                rotations: vec![Q_ID],
                translations: vec![[3.0, 0.0, 0.0]],
            },
            ObjectTrack {
                object_id: 8,
                interpolation: 2,
                times: vec![0.0, 1.0],
                rotations: vec![Q_ID, Q_ID],
                translations: vec![[0.0; 3], [1.0, 0.0, 0.0]],
            },
        ],
    };
    let mut centers = vec![0.0, 0.0, 0.0];
    let mut orientations = vec![0.0, 0.0, 0.0, 1.0];
    layer
        .apply(&mut centers, &mut orientations, &[7], 0.5)
        .expect("object 8 is unrelated to this state");
    assert_eq!(centers, [3.0, 0.0, 0.0]);
}

#[test]
fn provenance_does_not_fetch_object_ranges() {
    let (bytes, table_range, track7_range, track8_range) = object_file_with_unrelated_ranges();
    let reads = Rc::new(RefCell::new(Vec::new()));
    let source = CountingSource {
        bytes,
        reads: Rc::clone(&reads),
    };
    let mut reader = SceneReader::open_with(source, OpenMode::Indexed).expect("open indexed");
    reads.borrow_mut().clear();

    assert!(reader.provenance().expect("read provenance").is_empty());
    let provenance_reads = reads.borrow().clone();
    assert!(
        provenance_reads.iter().all(|range| {
            !overlaps(*range, table_range)
                && !overlaps(*range, track7_range)
                && !overlaps(*range, track8_range)
        }),
        "provenance must skip every object range before reading: {provenance_reads:?}"
    );
}

#[test]
fn omitted_object_stream_defaults_only_that_chunk_to_background() {
    fn chunk(object_id: Option<Vec<u32>>) -> DecodedChunk {
        DecodedChunk {
            count: 1,
            positions: vec![0.0; 3],
            scales: vec![1.0; 3],
            rotations: vec![0.0, 0.0, 0.0, 1.0],
            colors: vec![0.0; 4],
            motions: vec![0.0; 3],
            mu_t: vec![0.0],
            sigma_t: vec![f32::INFINITY],
            window_index: vec![0],
            object_id,
            ..Default::default()
        }
    }
    let chunks = vec![chunk(Some(vec![7])), chunk(None), chunk(Some(vec![8]))];
    let bands = vec![BTreeMap::new(); chunks.len()];
    let assembled =
        fourdgs::stream_reader::assemble(&chunks, &bands, &[(0.0, 1.0)], &Header::default())
            .unwrap();
    assert_eq!(assembled.object_id, Some(vec![7, 0, 8]));
}

#[test]
fn object_stream_preserves_all_u32_bit_patterns_and_refuses_wrong_shape() {
    let steps = Steps {
        pos: 1.0,
        scale_log: 1.0,
        rot: 1.0,
        rgb: 1.0,
        alpha: 1.0,
        motion: 1.0,
        time: 1.0,
        sigma_log: 1.0,
        sh: 1,
    };
    let signed_codes = [0, i32::MAX as i64, i32::MIN as i64, -1];
    let decoded = fourdgs::chunk::decode_streams(
        &streams_with_object_id(&signed_codes, 1),
        signed_codes.len(),
        &steps,
        &[0.0; 3],
        &[(0.0, 1.0)],
        0.05,
    )
    .unwrap();
    assert_eq!(
        decoded.object_id,
        Some(vec![0, 0x7fff_ffff, 0x8000_0000, 0xffff_ffff])
    );

    let err = fourdgs::chunk::decode_streams(
        &streams_with_object_id(&[7, 8], 2),
        1,
        &steps,
        &[0.0; 3],
        &[(0.0, 1.0)],
        0.05,
    )
    .unwrap_err();
    assert!(err.to_string().contains("channels"), "{err}");

    // A malicious delta stream can leave the signed 32-bit domain even though each
    // encoded delta fits in it. Reject that value before reinterpreting its bits.
    let values = [i32::MAX as i64, 1];
    let encoded_object =
        encode_stream(op::A_OBJECT_ID, &values, 1, codec::DEFLATE, 1, false).unwrap();
    let mut streams = streams_with_object_id(&values, 1);
    let mode_offset = streams.len() - encoded_object.len() + 2;
    streams[mode_offset] = fourdgs::stream::MODE_DELTA;
    let err = fourdgs::chunk::decode_streams(
        &streams,
        values.len(),
        &steps,
        &[0.0; 3],
        &[(0.0, 1.0)],
        0.05,
    )
    .unwrap_err();
    assert!(err.to_string().contains("element 1"), "{err}");
    assert!(err.to_string().contains("2147483648"), "{err}");
}

#[test]
fn duplicate_scene_wide_object_tables_are_refused_on_both_paths() {
    let sequential = object_file(false, true);
    let err = fourdgs::read_bytes(&sequential).unwrap_err();
    assert!(err.to_string().contains("second ObjectTable"), "{err}");

    let indexed = object_file(true, true);
    let mut reader =
        SceneReader::open_with(BytesReadable::new(&indexed), OpenMode::Indexed).unwrap();
    let err = reader.objects().unwrap_err();
    assert!(err.to_string().contains("second ObjectTable"), "{err}");
}

#[test]
fn record_counts_are_bounded_by_the_record_before_allocation() {
    let mut table = Vec::new();
    table.extend(u32::MAX.to_le_bytes());
    table.extend(0u16.to_le_bytes());
    let err = ObjectTable::parse(&table).unwrap_err();
    assert!(err.to_string().contains("4294967295"), "{err}");
    assert!(err.to_string().contains("each entry"), "{err}");

    let mut track = Vec::new();
    track.extend(7u32.to_le_bytes());
    track.push(TRAJECTORY_LINEAR);
    track.extend(u32::MAX.to_le_bytes());
    let err = ObjectTrack::parse(&track).unwrap_err();
    assert!(err.to_string().contains("4294967295"), "{err}");
    assert!(err.to_string().contains("each sample"), "{err}");

    // The count itself fits, but the present embedding does not. Its dimensionality is
    // checked against the bytes before `f32s` reserves from it.
    let mut embedding = Vec::new();
    embedding.extend(1u32.to_le_bytes());
    embedding.extend(u16::MAX.to_le_bytes());
    embedding.extend(7u32.to_le_bytes());
    embedding.extend(0u32.to_le_bytes()); // empty label
    embedding.extend([0u8; 12]); // anchor
    embedding.push(0); // no dynamics
    embedding.push(1); // embedding present, but no vector follows
    let err = ObjectTable::parse(&embedding).unwrap_err();
    assert!(err.to_string().contains("65535 f32"), "{err}");
    assert!(err.to_string().contains("0 bytes remain"), "{err}");
}

#[test]
fn object_table_encoder_refuses_an_embedding_width_mismatch() {
    let table = ObjectTable {
        embedding_dim: 4,
        entries: vec![ObjectTableEntry {
            object_id: 7,
            embedding: Some(vec![1.0, 2.0, 3.0]),
            ..Default::default()
        }],
    };
    let err = table.encode(b"").unwrap_err();
    assert!(err.to_string().contains("3 values"), "{err}");
    assert!(err.to_string().contains("declares 4"), "{err}");
}

#[test]
fn object_record_encoders_refuse_structurally_ambiguous_values() {
    let track = ObjectTrack {
        object_id: 7,
        times: vec![0.0],
        rotations: Vec::new(),
        translations: vec![[0.0; 3]],
        ..Default::default()
    };
    let err = track.encode(b"").unwrap_err();
    assert!(err.to_string().contains("1 times, 0 rotations"), "{err}");

    let unknown_interpolation = ObjectTrack {
        object_id: 7,
        interpolation: 2,
        ..Default::default()
    };
    let err = unknown_interpolation
        .check()
        .expect_err("future interpolation is unsupported at parse time");
    assert!(
        err.to_string().contains("interpolation 2")
            && err.to_string().contains("0 (linear)")
            && err.to_string().contains("1 (step)"),
        "{err}"
    );

    let mut table = Vec::new();
    table.extend(1u32.to_le_bytes());
    table.extend(0u16.to_le_bytes());
    table.extend(7u32.to_le_bytes());
    table.extend(0u32.to_le_bytes());
    table.extend([0u8; 12]);
    table.push(2); // dynamics_present must be a boolean
    let err = ObjectTable::parse(&table).unwrap_err();
    assert!(err.to_string().contains("dynamics_present=2"), "{err}");
}

#[test]
fn object_id_cannot_carry_a_quantization_bound() {
    let mut quantization = quantization();
    quantization.bounds.insert("object_id".into(), "0".into());
    let encoded = quantization.encode(b"");
    let err = Quantization::parse(content(&encoded)).unwrap_err();
    assert!(err.to_string().contains("object_id"), "{err}");
    assert!(err.to_string().contains("MUST NOT"), "{err}");
}

#[test]
fn composition_scales_with_objects_plus_gaussians_and_preserves_membership() {
    const COUNT: usize = 2048;
    let tracks = (1..=COUNT)
        .map(|id| ObjectTrack {
            object_id: id as u32,
            interpolation: TRAJECTORY_LINEAR,
            times: vec![0.0],
            rotations: vec![Q_ID],
            translations: vec![[id as f64, 0.0, 0.0]],
        })
        .collect();
    let layer = ObjectLayer {
        table: None,
        tracks,
    };
    let mut centers = vec![0.0; COUNT * 3];
    let mut orientations = vec![0.0; COUNT * 4];
    for q in orientations.chunks_exact_mut(4) {
        q[3] = 1.0;
    }
    let object_ids: Vec<u32> = (1..=COUNT).rev().map(|id| id as u32).collect();
    layer
        .apply(&mut centers, &mut orientations, &object_ids, 0.0)
        .unwrap();
    for (row, object_id) in object_ids.iter().enumerate() {
        assert_eq!(centers[row * 3], *object_id as f32);
    }
}
