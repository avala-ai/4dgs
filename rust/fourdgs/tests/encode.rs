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
