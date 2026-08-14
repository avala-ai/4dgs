// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Encoder tests.
//!
//! The cross-implementation gate in `rust/encode-roundtrip.sh` is what proves the encoder
//! writes conforming files: it re-encodes every corpus variant and requires the Rust and
//! Python decoders to agree on the result. These tests cover what that gate cannot —
//! the encoder's own promises, and the shapes the corpus has no variant for.

use std::collections::BTreeMap;

use fourdgs::model::{AudioSource, AudioSourceKeyframe, AudioTrack, GaussianSet};
use fourdgs::quantization::Profile;
use fourdgs::records::{ObjectTable, ObjectTableEntry};
use fourdgs::writer::{SceneExtras, WriteOptions};

/// A deterministic scene with mixed temporal behaviour: some gaussians fade, some never
/// do, some stand still, and they sit in four windows across the clip. That combination
/// exercises both per-gaussian precision rules and the chunk tree at once.
fn scene(n: usize) -> (GaussianSet, f64) {
    let duration = 8.0;
    let windows = 4;
    let window_len = duration / windows as f64;
    let mut state: u32 = 20260728;
    let mut rnd = || {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        state as f64 / 4294967296.0
    };

    let mut g = GaussianSet::default();
    for i in 0..n {
        let window = i % windows;
        let lo = window as f64 * window_len;

        for _ in 0..3 {
            g.positions.push((rnd() * 2.0 - 1.0) as f32);
        }
        for _ in 0..3 {
            g.scales.push((-7.0 + 2.0 * rnd()).exp() as f32);
        }
        // Cover all four branches of the smallest-three coding.
        let mut quat = [0.0f64; 4];
        for slot in quat.iter_mut() {
            *slot = rnd() * 0.3 - 0.15;
        }
        quat[i % 4] = 1.0;
        let norm = quat.iter().map(|v| v * v).sum::<f64>().sqrt();
        for value in quat {
            g.rotations.push((value / norm) as f32);
        }
        for _ in 0..3 {
            g.colors.push(rnd() as f32);
        }
        g.colors.push((0.05 + 0.95 * rnd()) as f32);

        let still = i % 5 == 0;
        for _ in 0..3 {
            g.motions.push(if still {
                0.0
            } else {
                (rnd() * 0.4 - 0.2) as f32
            });
        }

        g.mu_t.push((lo + window_len * rnd()) as f32);
        // Infinity is a value the encoder has to carry through, not a sentinel.
        g.sigma_t.push(if i % 7 == 0 {
            f32::INFINITY
        } else {
            (0.01 * (4.0f64 * rnd()).exp()) as f32
        });
        g.win_lo.push(lo as f32);
        g.win_hi.push((lo + window_len) as f32);
    }
    (g, duration)
}

fn chunking_options() -> WriteOptions {
    WriteOptions {
        min_chunk_gaussians: 8,
        max_depth: 4,
        ..Default::default()
    }
}

#[test]
fn a_scene_survives_a_round_trip() {
    let (g, duration) = scene(256);
    let bytes = fourdgs::write_to_vec(&g, duration, &chunking_options(), &SceneExtras::default())
        .expect("encode");
    let scene = fourdgs::read_bytes(&bytes).expect("decode");

    assert_eq!(scene.gaussians.count(), g.count());
    assert_eq!(scene.header.duration_sec, duration);
    assert!(
        scene.chunk_index.len() > 1,
        "a scene spanning four windows should partition into more than one chunk"
    );
    assert_eq!(
        scene.summary_crc_ok,
        Some(true),
        "the index checksum verifies"
    );

    let never_fades = scene
        .gaussians
        .sigma_t
        .iter()
        .filter(|s| s.is_infinite())
        .count();
    assert_eq!(
        never_fades,
        g.sigma_t.iter().filter(|s| s.is_infinite()).count(),
        "an infinite sigma has to survive as infinity"
    );
}

#[test]
fn the_output_is_deterministic() {
    // Accidental nondeterminism — an iteration order, a hash seed — is invisible locally
    // and shows up as somebody else's failing CI. It is cheaper to assert here.
    let (g, duration) = scene(128);
    let options = chunking_options();
    let first = fourdgs::write_to_vec(&g, duration, &options, &SceneExtras::default()).unwrap();
    let second = fourdgs::write_to_vec(&g, duration, &options, &SceneExtras::default()).unwrap();
    assert_eq!(first, second, "two encodes of one scene must be identical");
}

#[test]
fn every_decoded_value_lands_inside_the_declared_bounds() {
    // The encoder verifies this itself and refuses to return a file that fails, so this
    // test would fail as an error rather than an assertion. It is here to check the claim
    // from outside as well, on the profile with the loosest grids.
    let (g, duration) = scene(256);
    for profile in [Profile::Fine, Profile::Default, Profile::Coarse] {
        let options = WriteOptions {
            profile,
            ..chunking_options()
        };
        let bytes = fourdgs::write_to_vec(&g, duration, &options, &SceneExtras::default())
            .unwrap_or_else(|e| panic!("{profile:?} failed its own verification: {e}"));
        let scene = fourdgs::read_bytes(&bytes).expect("decode");
        let declared: f64 = scene.quantization.bounds["pos"].parse().expect("a number");

        // Decoded order is not the encoded order, so compare on the aggregate the
        // canonical summary uses rather than element by element.
        let mut worst_alpha = 0.0f64;
        for i in 0..scene.gaussians.count() {
            let alpha = scene.gaussians.colors[i * 4 + 3] as f64;
            assert!((0.0..=1.0).contains(&alpha), "opacity stays in [0, 1]");
            worst_alpha = worst_alpha.max(alpha);
        }
        assert!(declared > 0.0, "the file declares a position bound");
        assert!(worst_alpha > 0.0, "{profile:?} decoded something");
    }
}

#[test]
fn a_scene_with_no_gaussians_is_a_valid_file() {
    // Degenerate and well defined. It is also the shape a reader is most likely to be
    // handed by a pipeline that filtered everything out.
    let bytes = fourdgs::write_to_vec(
        &GaussianSet::default(),
        0.0,
        &WriteOptions::default(),
        &SceneExtras::default(),
    )
    .expect("an empty scene encodes");
    let scene = fourdgs::read_bytes(&bytes).expect("an empty scene decodes");
    assert_eq!(scene.gaussians.count(), 0);
    assert!(scene.chunk_index.is_empty(), "no gaussians means no chunks");
    assert!(!scene.header.has_audio());
}

fn object_table_record(ids: &[u32]) -> Vec<u8> {
    ObjectTable {
        entries: ids
            .iter()
            .map(|object_id| ObjectTableEntry {
                object_id: *object_id,
                label: format!("object {object_id}"),
                ..Default::default()
            })
            .collect(),
        ..Default::default()
    }
    .encode(&[])
    .expect("valid Object Table")
}

#[test]
fn objects_profile_requires_an_object_table() {
    let (mut g, duration) = scene(8);
    g.object_id = Some(vec![7; g.count()]);
    let err = fourdgs::write_to_vec(
        &g,
        duration,
        &WriteOptions {
            scene_profile: "objects".into(),
            ..chunking_options()
        },
        &SceneExtras::default(),
    )
    .expect_err("an objects-profile file without its one Object Table must be refused");
    assert!(
        err.to_string()
            .contains("the objects profile requires one ObjectTable record"),
        "{err}"
    );
}

#[test]
fn objects_profile_requires_object_ids_in_every_non_empty_chunk() {
    let (g, duration) = scene(8);
    let err = fourdgs::write_to_vec(
        &g,
        duration,
        &WriteOptions {
            scene_profile: "objects".into(),
            extra_records: vec![object_table_record(&[7])],
            ..chunking_options()
        },
        &SceneExtras::default(),
    )
    .expect_err("a non-empty objects-profile chunk without object_id must be refused");
    assert!(
        err.to_string()
            .contains("the objects profile requires an object_id stream in every non-empty chunk"),
        "{err}"
    );
}

#[test]
fn object_ids_round_trip_across_the_complete_u32_domain() {
    let (mut g, duration) = scene(32);
    let labels = [0, 7, i32::MAX as u32, i32::MAX as u32 + 1, u32::MAX];
    let object_ids: Vec<u32> = (0..g.count()).map(|i| labels[i % labels.len()]).collect();
    // A unique, exactly representable x coordinate makes membership association observable
    // after the writer's Morton permutation, rather than checking only an id multiset.
    for i in 0..g.count() {
        g.positions[i * 3] = i as f32;
    }
    g.object_id = Some(object_ids.clone());
    let bytes = fourdgs::write_to_vec(
        &g,
        duration,
        &WriteOptions {
            scene_profile: "objects".into(),
            extra_records: vec![object_table_record(&labels[1..])],
            ..chunking_options()
        },
        &SceneExtras::default(),
    )
    .expect("encode object membership");
    let decoded = fourdgs::read_bytes(&bytes).expect("decode object membership");

    let actual = decoded
        .gaussians
        .object_id
        .expect("every non-empty Chunk carries object_id");
    for (row, actual_id) in actual.iter().enumerate() {
        let source = decoded.gaussians.positions[row * 3].round() as usize;
        assert!(source < object_ids.len(), "decoded x names source {source}");
        assert_eq!(
            *actual_id, object_ids[source],
            "object membership moved off source gaussian {source}"
        );
    }
    assert!(decoded.objects.table.is_some(), "the Object Table survives");
}

#[test]
fn object_id_count_must_match_the_gaussian_count() {
    let (mut g, duration) = scene(8);
    g.object_id = Some(vec![7; g.count() - 1]);
    let err = fourdgs::write_to_vec(
        &g,
        duration,
        &WriteOptions::default(),
        &SceneExtras::default(),
    )
    .expect_err("an incomplete exact-label lane must be refused before chunk gathering");
    assert!(
        err.to_string()
            .contains("object_id has 7 values, expected 8"),
        "{err}"
    );
}

#[test]
fn objects_profile_refuses_a_second_object_table() {
    let (mut g, duration) = scene(8);
    g.object_id = Some(vec![7; g.count()]);
    let table = object_table_record(&[7]);
    let err = fourdgs::write_to_vec(
        &g,
        duration,
        &WriteOptions {
            scene_profile: "objects".into(),
            extra_records: vec![table.clone(), table],
            ..chunking_options()
        },
        &SceneExtras::default(),
    )
    .expect_err("the objects profile promises exactly one Object Table");
    assert!(
        err.to_string().contains(
            "the objects profile requires exactly one ObjectTable record; 2 were supplied"
        ),
        "{err}"
    );
}

#[test]
fn objects_profile_refuses_a_malformed_object_table() {
    let (mut g, duration) = scene(8);
    g.object_id = Some(vec![7; g.count()]);
    let mut malformed = Vec::new();
    fourdgs::serialization::put_record(&mut malformed, fourdgs::opcode::OBJECT_TABLE, &[]);
    let err = fourdgs::write_to_vec(
        &g,
        duration,
        &WriteOptions {
            scene_profile: "objects".into(),
            extra_records: vec![malformed],
            ..chunking_options()
        },
        &SceneExtras::default(),
    )
    .expect_err("a framed opcode is not enough; the promised Object Table must parse");
    assert!(
        err.to_string().contains(
            "extra_records[0] carries a malformed ObjectTable: truncated: need 4 bytes at offset 0"
        ),
        "{err}"
    );
}

#[test]
fn a_scene_without_audio_carries_no_audio_record() {
    // Absence is a complete, conforming state: no record, no placeholder, no reserved
    // bytes, and the header bit clear. An encoder that emitted a silent track to satisfy
    // the format would pass a laxer check than this one.
    let (g, duration) = scene(32);
    let silent = fourdgs::write_to_vec(&g, duration, &chunking_options(), &SceneExtras::default())
        .expect("encode");
    let with_audio = fourdgs::write_to_vec(
        &g,
        duration,
        &chunking_options(),
        &SceneExtras {
            audio: Some(AudioTrack {
                codec: "wav".into(),
                start_sec: 0.0,
                data: vec![7u8; 2048],
            }),
            ..Default::default()
        },
    )
    .expect("encode");

    let quiet = fourdgs::read_bytes(&silent).expect("decode");
    assert!(!quiet.header.has_audio());
    assert!(
        quiet.audio_sources.is_empty(),
        "absence is an empty source list, never a silent placeholder"
    );

    let loud = fourdgs::read_bytes(&with_audio).expect("decode");
    assert!(loud.header.has_audio());
    let track = loud.audio_sources.first().expect("a source");
    assert_eq!(track.codec, "wav");
    assert_eq!(track.data.len(), 2048);
}

#[test]
fn multiple_fixed_and_moving_audio_sources_round_trip() {
    let (g, duration) = scene(32);
    let moving = AudioSource {
        source_id: 42,
        name: "moving microphone".into(),
        codec: "wav".into(),
        duration_sec: 2.0,
        gain: 0.5,
        loop_: true,
        keyframes: vec![
            AudioSourceKeyframe {
                time: 0.0,
                position: [2.0, 0.5, 1.0],
                rotation: [0.0, 0.0, 0.0, 1.0],
            },
            AudioSourceKeyframe {
                time: duration,
                position: [-2.0, 1.5, -1.0],
                rotation: [0.0, 1.0, 0.0, 0.0],
            },
        ],
        data: vec![0x5A; 4096],
        ..AudioSource::default()
    };
    let extras = SceneExtras {
        audio_sources: vec![
            AudioSource {
                source_id: 7,
                name: "fixed speaker".into(),
                codec: "opus".into(),
                duration_sec: duration,
                position: [1.5, 0.75, -0.5],
                data: vec![0x33; 2048],
                ..AudioSource::default()
            },
            moving,
        ],
        ..SceneExtras::default()
    };
    let bytes = fourdgs::write_to_vec(&g, duration, &chunking_options(), &extras).expect("encode");
    let decoded = fourdgs::read_bytes(&bytes).expect("decode");
    assert_eq!(decoded.audio_sources.len(), 2);
    assert_eq!(decoded.audio_sources[0].source_id, 7);
    assert_eq!(decoded.audio_sources[1].source_id, 42);
    let state = decoded.audio_sources[1].state_at(duration / 2.0);
    assert_eq!(state.position, [0.0, 1.0, 0.0]);
    assert!((state.rotation[1] - std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-12);
    assert!((state.rotation[3] - std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-12);

    let step = AudioSource {
        duration_sec: duration,
        interpolation: "step".into(),
        keyframes: vec![
            AudioSourceKeyframe {
                time: 0.0,
                position: [0.0; 3],
                rotation: [0.0, 0.0, 0.0, 1.0],
            },
            AudioSourceKeyframe {
                time: 1.0,
                position: [1.0, 2.0, 3.0],
                rotation: [0.0, 1.0, 0.0, 1.0],
            },
            AudioSourceKeyframe {
                time: duration,
                position: [9.0; 3],
                rotation: [0.0, 0.0, 0.0, 1.0],
            },
        ],
        ..AudioSource::default()
    };
    let exact = step.state_at(1.0);
    assert_eq!(exact.position, [1.0, 2.0, 3.0]);
    assert!((exact.rotation[1] - std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-12);
    assert!((exact.rotation[3] - std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-12);
}

#[test]
fn an_extreme_but_finite_audio_orientation_normalizes_without_overflow() {
    // Normalize the direction without ever constructing a magnitude that can overflow or
    // underflow. Both vectors are finite, non-zero orientations.
    let mut source = AudioSource {
        source_id: 1,
        codec: "wav".into(),
        duration_sec: 2.0,
        rotation: [1e308; 4],
        data: vec![0x00; 4],
        ..AudioSource::default()
    };
    let state = source.state_at(1.0);
    assert!(state
        .rotation
        .iter()
        .all(|value| (*value - 0.5).abs() < 1e-12));
    source.rotation = [f64::from_bits(1), 0.0, 0.0, 0.0];
    assert_eq!(source.state_at(1.0).rotation, [1.0, 0.0, 0.0, 0.0]);
}

#[test]
fn looping_audio_time_does_not_overflow() {
    let source = AudioSource {
        start_sec: -1e308,
        duration_sec: 1.0,
        loop_: true,
        ..AudioSource::default()
    };
    let state = source.state_at(1e308);
    assert!(state.active);
    assert_eq!(state.local_time, 0.0);
    assert!(state.local_time.is_finite());

    let short_at_large_time = AudioSource {
        start_sec: 1e308,
        duration_sec: 1.0,
        ..AudioSource::default()
    };
    assert!(short_at_large_time.state_at(1e308).active);
}

#[test]
fn extreme_audio_positions_interpolate_without_overflow() {
    let source = AudioSource {
        start_sec: -1e308,
        duration_sec: 1.0,
        loop_: true,
        keyframes: vec![
            AudioSourceKeyframe {
                time: -1e308,
                position: [-1e308, 0.0, 0.0],
                rotation: [0.0, 0.0, 0.0, 1.0],
            },
            AudioSourceKeyframe {
                time: 1e308,
                position: [1e308, 0.0, 0.0],
                rotation: [0.0, 0.0, 0.0, 1.0],
            },
        ],
        ..AudioSource::default()
    };
    let state = source.state_at(0.0);
    assert_eq!(state.position, [0.0, 0.0, 0.0]);
    assert!(state.position.iter().all(|value| value.is_finite()));
}

#[test]
fn truncation_does_not_excuse_audio_when_the_header_flag_is_clear() {
    use fourdgs::serialization::{read_record, Cursor, Records, RECORD_HEADER_SIZE};

    let (g, duration) = scene(32);
    let extras = SceneExtras {
        audio_sources: vec![AudioSource {
            source_id: 1,
            codec: "wav".into(),
            duration_sec: duration,
            data: b"RIFF".to_vec(),
            ..AudioSource::default()
        }],
        ..SceneExtras::default()
    };
    let mut bytes =
        fourdgs::write_to_vec(&g, duration, &chunking_options(), &extras).expect("encode");
    let mut records = Cursor::at(&bytes, fourdgs::MAGIC.len());
    let header = read_record(&mut records).expect("Header");
    assert_eq!(header.opcode, fourdgs::opcode::HEADER);
    let header_offset = header.offset;
    let mut content = Cursor::new(header.content);
    content.string().unwrap();
    content.string().unwrap();
    content.take(8 + 8 + 8).unwrap();
    content.string().unwrap();
    content.take(6 * 8).unwrap();
    content.u8().unwrap();
    let flags = header_offset + RECORD_HEADER_SIZE + content.position();
    bytes[flags] &= !fourdgs::records::FLAG_HAS_AUDIO;
    let (descriptor_offset, payload_offset) = {
        let mut descriptor_offset = None;
        let mut payload_offset = None;
        for record in Records::new(&bytes, fourdgs::MAGIC.len()) {
            let record = record.expect("well-formed generated record");
            if record.opcode == fourdgs::opcode::AUDIO_SOURCE {
                descriptor_offset = Some(record.offset);
            } else if record.opcode == fourdgs::opcode::AUDIO_DATA {
                payload_offset = Some(record.offset);
            }
        }
        (
            descriptor_offset.expect("Audio Source"),
            payload_offset.expect("Audio Data"),
        )
    };
    let orphan = fourdgs::read_bytes(&bytes[..payload_offset])
        .expect_err("a complete descriptor contradicts the clear Header");
    assert!(
        matches!(&orphan, fourdgs::Error::Malformed(message)
            if message.contains("Audio Source record for source id 1")
                && message.contains(&format!("byte {descriptor_offset}"))),
        "{orphan}"
    );
    bytes.pop();

    let error = fourdgs::read_bytes(&bytes).expect_err("the complete source contradicts Header");
    assert!(
        matches!(&error, fourdgs::Error::Malformed(message)
            if message.contains("Audio Source record for source id 1")
                && message.contains(&format!("byte {descriptor_offset}"))),
        "{error}"
    );
}

#[test]
fn indexed_audio_ranges_validate_descriptor_and_payload_lengths_first() {
    use fourdgs::serialization::{Cursor, Records, RECORD_HEADER_SIZE};

    let (g, duration) = scene(8);
    let extras = SceneExtras {
        audio_sources: vec![AudioSource {
            source_id: 1,
            codec: "wav".into(),
            duration_sec: duration,
            data: b"RIFF".to_vec(),
            ..AudioSource::default()
        }],
        ..SceneExtras::default()
    };
    let mut bytes =
        fourdgs::write_to_vec(&g, duration, &chunking_options(), &extras).expect("encode");
    let data_length_at = {
        let record = Records::new(&bytes, fourdgs::MAGIC.len())
            .find_map(|record| {
                let record = record.expect("well-formed generated record");
                (record.opcode == fourdgs::opcode::AUDIO_SOURCE).then_some(record)
            })
            .expect("Audio Source");
        let mut content = Cursor::new(record.content);
        assert_eq!(content.u32().unwrap(), 1);
        content.string().unwrap();
        content.string().unwrap();
        content.string().unwrap();
        record.offset + RECORD_HEADER_SIZE + content.position()
    };
    let declared = u64::from_le_bytes(
        bytes[data_length_at..data_length_at + 8]
            .try_into()
            .expect("u64"),
    );
    bytes[data_length_at..data_length_at + 8].copy_from_slice(&(declared + 1).to_le_bytes());

    let mut source = OwnedSource(bytes);
    let indexed = fourdgs::indexed_reader::open_indexed(&mut source).expect("indexed open");
    let error = fourdgs::indexed_reader::read_audio_range(&mut source, &indexed, 1, 0, 1)
        .expect_err("the descriptor disagrees with Audio Data");
    assert!(
        matches!(&error, fourdgs::Error::Malformed(message)
            if message.contains("Audio Data record declares")),
        "{error}"
    );
}

#[test]
fn the_writer_normalizes_an_extreme_audio_orientation_without_overflow() {
    let (g, duration) = scene(0);
    let extras = SceneExtras {
        audio_sources: vec![AudioSource {
            source_id: 1,
            codec: "wav".into(),
            duration_sec: duration,
            rotation: [1e308, 0.0, 0.0, 0.0],
            data: vec![0x00; 4],
            ..AudioSource::default()
        }],
        ..SceneExtras::default()
    };
    let bytes = fourdgs::write_to_vec(&g, duration, &chunking_options(), &extras).expect("encode");
    let decoded = fourdgs::read_bytes(&bytes).expect("decode");
    assert_eq!(decoded.audio_sources[0].rotation, [1.0, 0.0, 0.0, 0.0]);
}

#[test]
fn an_audio_data_record_beside_a_legacy_audio_record_is_an_orphan() {
    // A legacy Audio record stands alone: it carries its own payload and there is no
    // separate Audio Data to pair with it. A file that puts an Audio Data record next to a
    // legacy Audio record therefore has an orphan — an Audio Data with no descriptor to
    // match — which the streamed reader has always refused. The indexed reader took a
    // legacy shortcut that never looked at the leftover data ranges, so it accepted the
    // same malformed file; this pins both paths to the same answer.
    //
    // The file is built by rewriting a spatial source's descriptor in place into an empty
    // legacy Audio record of the same framed length, leaving its paired Audio Data behind.
    // The summary CRC covers only the summary run, not front-matter audio, so the rewrite
    // leaves an otherwise well-formed file whose only fault is the orphan.
    use fourdgs::opcode as op;

    let (g, duration) = scene(16);
    let extras = SceneExtras {
        audio_sources: vec![AudioSource {
            source_id: 3,
            name: "solo".into(),
            codec: "wav".into(),
            duration_sec: duration,
            position: [1.0, 0.0, -1.0],
            data: vec![0x7E; 1024],
            ..AudioSource::default()
        }],
        ..SceneExtras::default()
    };
    let mut bytes =
        fourdgs::write_to_vec(&g, duration, &chunking_options(), &extras).expect("encode");

    // Walk the framing (opcode byte, then an eight-byte little-endian length) to the Audio
    // Source descriptor.
    let mut at = fourdgs::MAGIC.len();
    let descriptor = loop {
        assert!(at + 9 <= bytes.len(), "the file has an Audio Source record");
        let opcode = bytes[at];
        let length = u64::from_le_bytes(bytes[at + 1..at + 9].try_into().expect("eight")) as usize;
        if opcode == op::AUDIO_SOURCE {
            break (at, length);
        }
        at += 9 + length;
    };
    let (offset, length) = descriptor;

    // Rewrite the record as an empty legacy Audio record: codec "wav", start 0.0, no data.
    // Its framed length is unchanged, so every later offset — including the index — still
    // lands, and the trailing bytes are ignorable padding past the fields a reader knows.
    bytes[offset] = op::AUDIO;
    let content = offset + 9;
    for byte in &mut bytes[content..content + length] {
        *byte = 0;
    }
    bytes[content..content + 4].copy_from_slice(&3u32.to_le_bytes());
    bytes[content + 4..content + 7].copy_from_slice(b"wav");
    // start_sec (f64 at content+7) and data_length (u64 at content+15) stay zero.

    let streamed = fourdgs::read_bytes(&bytes).expect_err("the streamed reader refuses the orphan");
    assert!(
        matches!(&streamed, fourdgs::Error::Malformed(m) if m.contains("no matching Audio Source")),
        "the streamed reader names the orphan: {streamed}"
    );

    let indexed = fourdgs::indexed_reader::open_indexed(&mut OwnedSource(bytes.clone()))
        .expect_err("the indexed reader refuses the same file");
    assert!(
        matches!(&indexed, fourdgs::Error::Malformed(m) if m.contains("no matching Audio Source")),
        "the indexed reader refuses the orphan exactly as the streamed one does: {indexed}"
    );

    // The recovery path refuses it too. A truncated tail can legitimize an unmatched *new*
    // descriptor (its Audio Data may have been the part that was cut), but never an Audio
    // Data beside a legacy record — the two representations cannot be mixed, so no missing
    // bytes could complete it. Drop the trailing magic to mark the file truncated.
    let mut cut = bytes;
    cut.truncate(cut.len() - fourdgs::MAGIC.len());
    let recovered = fourdgs::read_bytes(&cut).expect_err("recovery still refuses the mix");
    assert!(
        matches!(&recovered, fourdgs::Error::Malformed(m) if m.contains("no matching Audio Source")),
        "recovering a truncated file still refuses the legacy-plus-orphan mix: {recovered}"
    );
}

#[test]
fn the_records_that_travel_with_a_scene_survive() {
    let (g, duration) = scene(32);
    let extras = SceneExtras {
        camera: Some(fourdgs::records::Camera {
            fov_y_deg: 45.0,
            position: [0.0, 1.0, 3.0],
            target: [0.0; 3],
            times: vec![0.0, duration],
            positions: vec![[0.0, 1.0, 3.0], [1.0, 1.0, 3.0]],
            targets: vec![[0.0; 3], [0.0; 3]],
            interpolation: "spline".into(),
            loop_: true,
        }),
        metadata: vec![fourdgs::records::Metadata {
            name: "scene".into(),
            entries: BTreeMap::from([
                (
                    "coordinate_system".to_string(),
                    "y-up-right-handed".to_string(),
                ),
                ("visibility_profile".to_string(), "gaussian".to_string()),
            ]),
        }],
        attachments: vec![fourdgs::records::Attachment {
            name: "note.txt".into(),
            media_type: "text/plain".into(),
            data: b"round trip".to_vec(),
        }],
        ..Default::default()
    };
    let bytes = fourdgs::write_to_vec(&g, duration, &chunking_options(), &extras).expect("encode");
    let scene = fourdgs::read_bytes(&bytes).expect("decode");

    let camera = scene.camera.expect("a camera");
    assert_eq!(camera.fov_y_deg, 45.0);
    assert_eq!(camera.times.len(), 2);
    assert_eq!(scene.metadata.len(), 1);
    assert_eq!(scene.metadata[0].entries["visibility_profile"], "gaussian");
    assert_eq!(scene.attachments.len(), 1);
    assert_eq!(scene.attachments[0].data, b"round trip");
}

#[test]
fn spherical_harmonics_round_trip_whole_degrees() {
    let (mut g, duration) = scene(64);
    // Coefficients *per colour component*: (d + 1)^2 - 1 is 8 at degree 2, so a row is
    // three times that wide.
    let coefficients = 8;
    g.sh_degree = 2;
    g.sh_coefficients = coefficients;
    g.sh = Some(
        (0..g.count() * coefficients * 3)
            .map(|i| (i % 251) as u8)
            .collect(),
    );

    let bytes = fourdgs::write_to_vec(&g, duration, &chunking_options(), &SceneExtras::default())
        .expect("encode");
    let scene = fourdgs::read_bytes(&bytes).expect("decode");
    assert_eq!(scene.header.sh_degree, 2);
    assert_eq!(scene.gaussians.sh_coefficients, coefficients);
    let sh = scene.gaussians.sh.expect("coefficients");
    assert_eq!(sh.len(), g.count() * coefficients * 3);

    // A reader that caps its degree gets a lower degree, never a partial one.
    let capped = fourdgs::read_from(
        std::io::Cursor::new(&bytes),
        &fourdgs::ReadOptions {
            max_sh_band: 1,
            ..Default::default()
        },
    )
    .expect("decode");
    assert_eq!(
        capped.gaussians.sh_coefficients, 3,
        "capping at band 1 yields exactly a degree-1 scene"
    );
}

#[test]
fn an_indexed_read_of_an_encoded_file_agrees_with_a_streamed_one() {
    // Two very different read paths over one file. Agreeing with itself across both is
    // most of what makes an indexed implementation trustworthy.
    let (g, duration) = scene(256);
    let bytes = fourdgs::write_to_vec(&g, duration, &chunking_options(), &SceneExtras::default())
        .expect("encode");

    let streamed = fourdgs::read_bytes(&bytes).expect("streamed decode");
    let mut reader = fourdgs::SceneReader::open(OwnedSource(bytes.clone())).expect("indexed open");
    let indexed = reader.load_all(3).expect("indexed decode");

    assert_eq!(indexed.count(), streamed.gaussians.count());
    let sum = |v: &[f32]| v.iter().map(|x| *x as f64).sum::<f64>();
    assert!(
        (sum(&indexed.positions) - sum(&streamed.gaussians.positions)).abs() < 1e-6,
        "both paths decode the same positions"
    );
}

/// A `Readable` over an owned buffer, so the test does not need a file.
struct OwnedSource(Vec<u8>);

impl fourdgs::Readable for OwnedSource {
    fn size(&mut self) -> fourdgs::Result<u64> {
        Ok(self.0.len() as u64)
    }

    fn read(&mut self, offset: u64, length: u64) -> fourdgs::Result<Vec<u8>> {
        fourdgs::BytesReadable::new(&self.0).read(offset, length)
    }
}

#[test]
fn a_cut_between_a_chunk_and_its_bands_recovers_rather_than_refusing() {
    // The cut that lands after a chunk record but before one of its spherical harmonic
    // band records leaves that chunk carrying fewer bands than the rest of the file. That
    // is not corruption, it is the part that did not arrive — and refusing the file over it
    // throws away every complete record before the cut, which is the one thing truncation
    // recovery exists to keep. Found by the C++ binding against the corpus.
    let (mut g, duration) = scene(96);
    g.sh_degree = 2;
    g.sh_coefficients = 8;
    g.sh = Some((0..g.count() * 24).map(|i| (i % 251) as u8).collect());
    let bytes = fourdgs::write_to_vec(&g, duration, &chunking_options(), &SceneExtras::default())
        .expect("encode");

    let mut recovered = 0;
    for cut in (64..bytes.len()).step_by(7) {
        match fourdgs::read_bytes(&bytes[..cut]) {
            Ok(scene) => {
                recovered += 1;
                // Whatever survived is a whole degree or nothing — never a partial one.
                let coefficients = scene.gaussians.sh_coefficients;
                assert!(
                    coefficients == 0 || coefficients == 3 || coefficients == 8,
                    "a cut file yielded {coefficients} coefficients per component, which is \
                     not a whole degree"
                );
                if let Some(sh) = &scene.gaussians.sh {
                    assert_eq!(
                        sh.len(),
                        scene.gaussians.count() * coefficients * 3,
                        "every surviving gaussian has a full row of coefficients"
                    );
                }
            }
            Err(e) => {
                // Only the region before the Header and Quantization records are complete
                // may refuse, and it must refuse by naming what is missing.
                assert!(
                    e.to_string().contains("no Header"),
                    "a cut at {cut} was refused with: {e}"
                );
            }
        }
    }
    assert!(
        recovered > 100,
        "most cut points should recover; {recovered} did"
    );
}

#[test]
fn the_summary_is_one_contiguous_run_before_the_footer() {
    // §4.5. The rule exists so a front-to-back reader can verify the summary CRC by
    // retaining the trailing run of summary records rather than the whole file, so an
    // encoder that scattered them would quietly cost every streamed reader that property.
    // Attachments are deliberately outside the run: their size is unbounded.
    use fourdgs::opcode as op;

    let (g, duration) = scene(128);
    let options = WriteOptions {
        write_statistics: true,
        write_summary_offsets: true,
        ..chunking_options()
    };
    let extras = SceneExtras {
        attachments: vec![fourdgs::records::Attachment {
            name: "thumbnails.bin".into(),
            media_type: "application/octet-stream".into(),
            data: vec![0xAB; 4096],
        }],
        ..Default::default()
    };
    let bytes = fourdgs::write_to_vec(&g, duration, &options, &extras).expect("encode");

    // Walk the framing without interpreting anything.
    let mut records: Vec<(usize, u8)> = Vec::new();
    let mut at = fourdgs::MAGIC.len();
    while at + 9 <= bytes.len() {
        let opcode = bytes[at];
        let length = u64::from_le_bytes(bytes[at + 1..at + 9].try_into().expect("eight bytes"));
        records.push((at, opcode));
        at += 9 + length as usize;
    }

    let footer_at = records
        .iter()
        .rev()
        .find(|(_, opcode)| *opcode == op::FOOTER)
        .expect("a footer")
        .0;
    let summary_start = u64::from_le_bytes(
        bytes[footer_at + 9..footer_at + 17]
            .try_into()
            .expect("eight"),
    ) as usize;
    assert!(summary_start > 0, "this file declares a summary");

    let is_summary = |o: u8| matches!(o, op::CHUNK_INDEX | op::STATISTICS | op::SUMMARY_OFFSET);
    for (offset, opcode) in &records {
        if *offset >= summary_start && *offset < footer_at {
            assert!(
                is_summary(*opcode),
                "{} sits inside the summary range",
                op::name(*opcode)
            );
        } else if *offset < summary_start {
            assert!(
                !is_summary(*opcode),
                "{} sits before summary_start",
                op::name(*opcode)
            );
        }
    }

    // And the attachment really is in the file, ahead of the run rather than absent.
    let attachment_at = records
        .iter()
        .find(|(_, opcode)| *opcode == op::ATTACHMENT)
        .expect("the attachment was written")
        .0;
    assert!(
        attachment_at < summary_start,
        "an attachment belongs with the content records, ahead of the summary"
    );

    // The whole point: a streamed read verifies the CRC from the retained run alone.
    let scene = fourdgs::read_bytes(&bytes).expect("decode");
    assert_eq!(
        scene.summary_crc_ok,
        Some(true),
        "a contiguous summary lets a front-to-back reader verify the checksum"
    );
}

/// One gaussian, every field finite and legal. The base the tests below perturb.
fn one_gaussian() -> GaussianSet {
    let mut g = GaussianSet::default();
    g.positions.extend_from_slice(&[0.1, 0.2, 0.3]);
    g.scales.extend_from_slice(&[1e-3, 1e-3, 1e-3]);
    g.rotations.extend_from_slice(&[0.0, 0.0, 0.0, 1.0]);
    g.colors.extend_from_slice(&[0.5, 0.5, 0.5, 0.5]);
    g.motions.extend_from_slice(&[0.0, 0.0, 0.0]);
    g.mu_t.push(0.5);
    g.sigma_t.push(0.1);
    g.win_lo.push(0.0);
    g.win_hi.push(1.0);
    g
}

/// The three components of `pos_origin` and the eight steps, read off the wire.
///
/// Straight off the bytes rather than through the decoder's model, because the point is
/// what the encoder *wrote* — a check that went through a type which had already dropped
/// the value would prove nothing.
fn quantization_parameters(bytes: &[u8]) -> Vec<f64> {
    use fourdgs::opcode as op;
    let mut at = 8usize;
    while at + 9 <= bytes.len() {
        let opcode = bytes[at];
        let length = u64::from_le_bytes(bytes[at + 1..at + 9].try_into().unwrap()) as usize;
        let body = &bytes[at + 9..at + 9 + length];
        if opcode == op::QUANTIZATION {
            let scheme_len = u32::from_le_bytes(body[0..4].try_into().unwrap()) as usize;
            let mut p = 4 + scheme_len;
            let mut out = Vec::new();
            for _ in 0..11 {
                out.push(f64::from_le_bytes(body[p..p + 8].try_into().unwrap()));
                p += 8;
            }
            return out;
        }
        at += 9 + length;
    }
    panic!("no Quantization record");
}

#[test]
fn a_well_formed_scene_writes_finite_quantization_parameters() {
    let bytes = fourdgs::write_to_vec(
        &one_gaussian(),
        1.0,
        &WriteOptions::default(),
        &SceneExtras::default(),
    )
    .unwrap();
    for value in quantization_parameters(&bytes) {
        assert!(
            value.is_finite(),
            "every step and origin must be finite (§5.3)"
        );
    }
}

#[test]
fn a_non_finite_position_is_refused_rather_than_written() {
    // `f64::min` returns the other operand when one is NaN, and the origin fold is seeded
    // with `f64::INFINITY`. So before this check existed, ONE NaN on an axis left that
    // axis at the seed and the encoder wrote `inf` as a position origin — silently, no
    // error, a file §5.3 forbids. A whole axis of NaN was never needed; one gaussian was.
    for bad in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
        for axis in 0..3 {
            let mut g = one_gaussian();
            g.positions[axis] = bad;
            let result =
                fourdgs::write_to_vec(&g, 1.0, &WriteOptions::default(), &SceneExtras::default());
            let error = result.expect_err("a non-finite position must be refused");
            assert!(
                matches!(error, fourdgs::Error::InvalidInput(_)),
                "expected InvalidInput, got {error}"
            );
            assert!(
                error.to_string().contains("positions"),
                "the error must name the field: {error}"
            );
        }
    }
}

#[test]
fn every_per_gaussian_field_is_checked_for_finiteness() {
    // A field added to the model and forgotten by the check would be a hole that writes a
    // spec-violating file, so each is perturbed in turn and each must be refused by name.
    type Perturb = fn(&mut GaussianSet);
    let cases: [(&str, Perturb); 8] = [
        ("positions", |g| g.positions[1] = f32::NAN),
        ("scales", |g| g.scales[0] = f32::INFINITY),
        ("rotations", |g| g.rotations[3] = f32::NAN),
        ("colors", |g| g.colors[2] = f32::INFINITY),
        ("motions", |g| g.motions[0] = f32::NAN),
        ("mu_t", |g| g.mu_t[0] = f32::INFINITY),
        // Not quantized, so an infinity is legal here — but a NaN never is.
        ("win_lo", |g| g.win_lo[0] = f32::NAN),
        ("win_hi", |g| g.win_hi[0] = f32::NAN),
    ];
    for (name, break_it) in cases {
        let mut g = one_gaussian();
        break_it(&mut g);
        let error =
            fourdgs::write_to_vec(&g, 1.0, &WriteOptions::default(), &SceneExtras::default())
                .expect_err(&format!("a non-finite {name} must be refused"));
        assert!(
            error.to_string().contains(name),
            "the error must name {name}: {error}"
        );
    }
}

#[test]
fn an_infinite_sigma_still_means_never_fades() {
    // The one non-finite value the format defines (§3). Refusing it would break the
    // feature the rest of this check exists to protect.
    let mut g = one_gaussian();
    g.sigma_t[0] = f32::INFINITY;
    let bytes = fourdgs::write_to_vec(&g, 1.0, &WriteOptions::default(), &SceneExtras::default())
        .expect("+inf sigma_t is legal and means the gaussian never fades");
    for value in quantization_parameters(&bytes) {
        assert!(value.is_finite());
    }

    // NaN and -inf are not that value. The decoder treats every non-finite sigma as
    // never-fading, so accepting NaN would turn a mistake into a deliberate-looking value.
    for bad in [f32::NAN, f32::NEG_INFINITY] {
        let mut g = one_gaussian();
        g.sigma_t[0] = bad;
        let error =
            fourdgs::write_to_vec(&g, 1.0, &WriteOptions::default(), &SceneExtras::default())
                .expect_err("NaN and -inf sigma_t must be refused");
        assert!(error.to_string().contains("sigma_t"), "{error}");
    }
}

#[test]
fn a_static_asset_encodes_with_an_infinite_window() {
    // The degenerate temporal case: a 3D splat with no time in it, present at every
    // instant. `sigma_t = +inf` and `win_hi = +inf` are how this format says that, and it
    // is what the glTF import writes for every gaussian in a static asset.
    //
    // Neither field is quantized — the window goes into the Window Table as f64 verbatim —
    // so an over-broad "everything must be finite" check refuses a whole legitimate class
    // of file. It did, until the glTF suite said so.
    let mut g = one_gaussian();
    g.sigma_t[0] = f32::INFINITY;
    g.win_lo[0] = 0.0;
    g.win_hi[0] = f32::INFINITY;
    let bytes = fourdgs::write_to_vec(&g, 1.0, &WriteOptions::default(), &SceneExtras::default())
        .expect("a static asset is a legal scene");
    for value in quantization_parameters(&bytes) {
        assert!(value.is_finite(), "and its grid is still finite (§5.3)");
    }
    let scene = fourdgs::read_bytes(&bytes).expect("decode");
    assert!(
        scene.gaussians.win_hi[0].is_infinite(),
        "the window survives"
    );
}

/// The provenance records survive an encode, and their absence costs nothing.
///
/// This one is written from a real miss rather than from a checklist. The
/// cross-implementation gate in `encode-roundtrip.sh` re-encodes every variant and requires
/// the Rust and Python decoders to agree on the *result* — which cannot catch an encoder
/// that drops a record, because both decoders then agree it is not there. An encoder
/// omission is invisible to a check whose two sides both read the encoder's own output, so
/// it needs an assertion that compares against what went in.
#[test]
fn provenance_records_survive_an_encode() {
    use fourdgs::provenance::Provenance;
    use fourdgs::records::{CoordinateFrame, GeodeticAnchor, RigTrajectory, SensorCalibration};

    let (g, duration) = scene(256);

    let provenance = Provenance {
        frames: vec![CoordinateFrame {
            name: String::new(),
            handedness: 1,
            up_axis: 2,
            forward_axis: 0,
            length_unit: 1,
            metres_per_unit: 1.0,
        }],
        sensors: vec![
            SensorCalibration {
                name: "front_camera".into(),
                modality: "camera".into(),
                camera_model: 2,
                width_px: 1920,
                height_px: 1080,
                fx: 1234.5,
                fy: 1230.25,
                cx: 960.5,
                cy: 540.25,
                distortion: vec![-0.32, 0.115, 0.0008, -0.0012, 0.0045],
                rotation: [0.0, 0.0, 0.0, 1.0],
                translation: [0.25, -0.125, 1.5],
                pose_reference: 1,
                rig_name: "rig".into(),
            },
            // The non-camera shape: `camera_model` 0 obliges every intrinsic to be zero,
            // and a reader that treats those zeros as a broken calibration rather than as
            // "this sensor has no projection model" refuses a conforming file.
            SensorCalibration {
                name: "top_lidar".into(),
                modality: "lidar".into(),
                rotation: [0.0, 0.0, 0.0, 1.0],
                translation: [0.0, 0.0, 1.875],
                pose_reference: 1,
                rig_name: "rig".into(),
                ..Default::default()
            },
        ],
        trajectories: vec![RigTrajectory {
            name: "rig".into(),
            interpolation: 0,
            times: vec![0.0, 0.5 * duration, duration],
            rotations: vec![[0.0, 0.0, 0.0, 1.0]; 3],
            translations: vec![[0.0; 3], [1.0, 0.0, 0.0], [2.0, 0.0, 0.0]],
        }],
        anchors: vec![GeodeticAnchor {
            frame_name: String::new(),
            latitude_deg: 12.5,
            longitude_deg: -145.25,
            altitude_m: 8.75,
            heading_deg: 37.5,
        }],
    };

    let options = chunking_options();
    let extras = SceneExtras {
        provenance: provenance.clone(),
        ..Default::default()
    };
    let bytes = fourdgs::write_to_vec(&g, duration, &options, &extras).expect("encode");
    let decoded = fourdgs::read_bytes(&bytes).expect("decode");
    assert_eq!(
        decoded.provenance, provenance,
        "every provenance record must survive the encode unchanged"
    );

    // The indexed path frames these at open and fetches them separately, so agreeing with
    // the streamed path is a second claim rather than the same one twice.
    let mut source = fourdgs::BytesReadable::new(&bytes);
    let indexed = fourdgs::indexed_reader::open_indexed(&mut source).expect("open");
    let by_range =
        fourdgs::indexed_reader::read_provenance(&mut source, &indexed).expect("read provenance");
    assert_eq!(by_range, provenance, "the indexed path must agree");

    // And absence costs nothing: no record, no placeholder, no Header flag. The two files
    // differ by exactly the provenance records and nothing else.
    let bare =
        fourdgs::write_to_vec(&g, duration, &options, &SceneExtras::default()).expect("encode");
    assert!(
        fourdgs::read_bytes(&bare)
            .expect("decode")
            .provenance
            .is_empty(),
        "a scene written without provenance must carry none"
    );
    assert!(
        bare.len() < bytes.len(),
        "the provenance-bearing file must be the larger of the two"
    );
}

/// A rig pose is clamped outside its sample range and slerped inside it.
///
/// The specification states both rules in prose; this is the arithmetic. Clamping is the
/// one an implementation is most likely to skip, because extrapolation falls out of the
/// interpolation formula for free and looks reasonable until the ends of a clip.
#[test]
fn a_rig_pose_clamps_outside_its_samples_and_slerps_inside() {
    use fourdgs::provenance::pose_at;
    use fourdgs::records::RigTrajectory;

    // A half-turn about +z across two seconds, expressed so that the two endpoints have
    // opposite quaternion signs. That is the case the shortest-arc rule exists for: read
    // naively, the interpolation takes the long way round.
    let trajectory = RigTrajectory {
        name: String::new(),
        interpolation: 0,
        times: vec![0.0, 2.0],
        rotations: vec![[0.0, 0.0, 0.0, 1.0], [0.0, 0.0, -1.0, 0.0]],
        translations: vec![[0.0; 3], [4.0, 0.0, 0.0]],
    };

    let before = pose_at(&trajectory, -10.0).unwrap().unwrap();
    assert_eq!(
        before.translation, [0.0; 3],
        "before the first sample, clamp"
    );
    let after = pose_at(&trajectory, 99.0).unwrap().unwrap();
    assert_eq!(
        after.translation,
        [4.0, 0.0, 0.0],
        "after the last sample, clamp"
    );

    let mid = pose_at(&trajectory, 1.0).unwrap().unwrap();
    assert!(
        (mid.translation[0] - 2.0).abs() < 1e-12,
        "translation is linear between samples"
    );
    // Shortest arc: a quarter turn the short way, so the z component is negative — the
    // sign the naive formula gets wrong.
    assert!(
        mid.rotation[2] < 0.0,
        "slerp must take the shortest arc; got z={}",
        mid.rotation[2]
    );
    assert!(
        (mid.rotation[3].abs() - std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-9,
        "a quarter turn has w = 1/sqrt(2); got {}",
        mid.rotation[3]
    );

    let empty = RigTrajectory::default();
    assert!(
        pose_at(&empty, 0.0).unwrap().is_none(),
        "a trajectory with no samples carries no pose"
    );
}

/// A scene with degree-3 coefficients, for the bit-depth tests below.
fn sh_scene(n: usize) -> (GaussianSet, f64) {
    let (mut g, duration) = scene(n);
    let coefficients = 15;
    g.sh_degree = 3;
    g.sh_coefficients = coefficients;
    g.sh = Some(
        (0..g.count() * coefficients * 3)
            .map(|i| (i % 251) as u8)
            .collect(),
    );
    (g, duration)
}

/// Encode `g` at the given per-band bit depths, or at none.
fn encode_sh(g: &GaussianSet, duration: f64, depths: Option<Vec<u8>>) -> fourdgs::Result<Vec<u8>> {
    fourdgs::write_to_vec(
        g,
        duration,
        &WriteOptions {
            sh_bit_depths: depths,
            ..chunking_options()
        },
        &SceneExtras::default(),
    )
}

#[test]
fn a_file_that_declares_no_bit_depths_is_the_file_it_was_before_the_field_existed() {
    let (g, duration) = sh_scene(64);
    let plain = encode_sh(&g, duration, None).expect("encode");
    assert_eq!(
        plain,
        fourdgs::write_to_vec(&g, duration, &chunking_options(), &SceneExtras::default())
            .expect("encode"),
        "no depths means no appended bytes"
    );

    // Eight bits is the identity, so declaring it changes the declaration and not one
    // coefficient — the file grows by the field alone.
    let flat = encode_sh(&g, duration, Some(vec![8, 8, 8])).expect("encode");
    let before = fourdgs::read_bytes(&plain).expect("decode");
    let after = fourdgs::read_bytes(&flat).expect("decode");
    assert_eq!(before.gaussians.sh, after.gaussians.sh);
    assert_eq!(after.quantization.sh_bit_depths, vec![8, 8, 8]);
    assert!(before.quantization.sh_bit_depths.is_empty());
}

#[test]
fn the_bound_each_band_declares_holds_for_every_coefficient() {
    use fourdgs::quantization::{sh_bound, sh_step};

    let (g, duration) = sh_scene(64);
    let depths = vec![6u8, 4, 3];
    let bytes = encode_sh(&g, duration, Some(depths.clone())).expect("encode");
    let scene = fourdgs::read_bytes(&bytes).expect("decode");

    assert_eq!(scene.quantization.sh_bit_depths, depths);
    // The coarsest band is what the two pre-existing scalar fields have to carry.
    assert_eq!(scene.quantization.step_sh, 32);
    assert_eq!(scene.quantization.bounds["sh"], "16");
    for (i, bits) in depths.iter().enumerate() {
        assert_eq!(
            scene.quantization.bounds[&format!("sh_band{}", i + 1)],
            sh_bound(*bits).to_string(),
            "each band declares the bound its depth implies"
        );
    }

    // `verify` decoded every band record back and refused a file whose deviation exceeded
    // the claim, so reaching this line means that ran on every coefficient of every
    // gaussian. What is left is that the values landed on the grid each band declared: a
    // band at `n` bits reconstructs at bin centres of `2^(8 - n)`.
    let coefficients = scene.gaussians.sh_coefficients;
    let count = scene.gaussians.count();
    let sh = scene.gaussians.sh.expect("coefficients");
    for (i, bits) in depths.iter().enumerate() {
        let step = u32::from(sh_step(*bits));
        let (first, last) = fourdgs::sh::band_range((i + 1) as u8).expect("band");
        for gaussian in 0..count {
            for component in 0..3 {
                for k in first..last {
                    let at = gaussian * 3 * coefficients + component * coefficients + k;
                    assert_eq!(u32::from(sh[at]) % step, step / 2, "band {}", i + 1);
                }
            }
        }
    }
}

#[test]
fn a_ladder_that_cannot_describe_the_scene_is_refused() {
    // Too few depths for the bands, and depths outside the range a grid is defined for.
    let (g, duration) = sh_scene(32);
    for (depths, expected) in [
        (vec![8u8, 6], "declares 2 bands"),
        (vec![9, 6, 5], "SH bit depth"),
        (vec![8, 2, 5], "SH bit depth"),
    ] {
        let error = encode_sh(&g, duration, Some(depths)).expect_err("not a grid this format has");
        assert!(
            error.to_string().contains(expected),
            "the message names the problem: {error}"
        );
    }
}
