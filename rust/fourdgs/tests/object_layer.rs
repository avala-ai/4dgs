// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The object layer: the two records round-trip, and a track composes onto base state.
//!
//! The test that earns its keep is `track_composes_onto_base_center`. It checks the claim
//! the layer rests on — that a track transforms the base state rather than replacing it —
//! and the record round-trips prove the wire format. The `object_id` stream through a full
//! chunk decode is covered cross-implementation by the conformance corpus (Python writes,
//! Rust decodes), which is where an end-to-end object file is exercised.

use fourdgs::object_layer::ObjectLayer;
use fourdgs::records::{ObjectTable, ObjectTableEntry, ObjectTrack, TRAJECTORY_LINEAR};

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
    let parsed = ObjectTable::parse(content(&table.encode(b""))).unwrap();
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
    let parsed = ObjectTable::parse(content(&table.encode(b""))).unwrap();
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
    let parsed = ObjectTrack::parse(content(&track.encode(b""))).unwrap();
    assert_eq!(parsed, track);
}

#[test]
fn track_composes_onto_base_center() {
    // A tracked object (id 7) of two gaussians and one background gaussian (id 0). The
    // base centre here stands in for position + motion*(t - mu_t): the per-gaussian motion
    // has already moved the gaussian inside the object's frame, and the track transports
    // it. That is the compose, base first, the design turns on.
    let mut centers: Vec<f32> = vec![1.0, 0.0, 0.0, 2.0, 0.0, 0.0, -5.0, -5.0, -5.0];
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
    layer.apply(&mut centers, &object_ids, 0.5).unwrap();

    // (1,0,0) rotated +90 about z is (0,1,0), then +T -> (10,1,0); likewise (2,0,0)->(10,2,0).
    assert!((centers[0] - 10.0).abs() < 1e-4 && (centers[1] - 1.0).abs() < 1e-4);
    assert!((centers[3] - 10.0).abs() < 1e-4 && (centers[4] - 2.0).abs() < 1e-4);
    // Background (id 0) is never touched.
    assert_eq!(&centers[6..9], &[-5.0, -5.0, -5.0]);
}

#[test]
fn no_track_is_identity() {
    let mut centers: Vec<f32> = vec![1.0, 2.0, 3.0];
    ObjectLayer::default()
        .apply(&mut centers, &[7], 0.0)
        .unwrap();
    assert_eq!(centers, vec![1.0, 2.0, 3.0]);
}

#[test]
fn track_clamps_outside_sample_range() {
    let mut centers: Vec<f32> = vec![0.0, 0.0, 0.0];
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
    layer.apply(&mut centers, &[7], 0.0).unwrap();
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
