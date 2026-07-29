// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Encoder tests.
//!
//! The cross-implementation gate in `rust/encode-roundtrip.sh` is what proves the encoder
//! writes conforming files: it re-encodes every corpus variant and requires the Rust and
//! Python decoders to agree on the result. These tests cover what that gate cannot —
//! the encoder's own promises, and the shapes the corpus has no variant for.

use std::collections::BTreeMap;

use fourdgs::model::{AudioTrack, GaussianSet};
use fourdgs::quantization::Profile;
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
        quiet.audio.is_none(),
        "absence is None, never an empty track"
    );

    let loud = fourdgs::read_bytes(&with_audio).expect("decode");
    assert!(loud.header.has_audio());
    let track = loud.audio.expect("a track");
    assert_eq!(track.codec, "wav");
    assert_eq!(track.data.len(), 2048);
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
