// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Tests for the parts the conformance corpus cannot reach.
//!
//! The corpus proves that a correct file decodes to the right numbers, which is most of
//! what matters and none of what this file covers. What is left is the behaviour on files
//! the corpus does not contain: a file that is not ours, a file from a version we do not
//! implement, a record type we have never seen, an index that points somewhere the file
//! does not go. Those paths are the ones a decoder meets in production and the ones a
//! synthetic corpus of well-formed files never exercises.

use std::collections::BTreeMap;

use fourdgs::error::Error;
use fourdgs::opcode as op;
use fourdgs::quantization::{life_class, mu_step, rint, support_k, Bounds, Profile, Steps};
use fourdgs::records::{Header, Quantization, RigTrajectory, WindowTable};
use fourdgs::serialization::{put_record, MAGIC};
use fourdgs::stream::{unzigzag, zigzag};

/// A file with a Header and a Quantization record and nothing else: the smallest thing a
/// reader must accept, and the base every "now break one field" test starts from.
fn minimal_file() -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(
        &Header {
            duration_sec: 1.0,
            gaussian_count: 0,
            aabb: vec![0.0; 6],
            cutoff: 0.05,
            temporal_model: "gaussian-birth".into(),
            ..Default::default()
        }
        .encode(&[]),
    );
    out.extend_from_slice(
        &Quantization {
            scheme: "uniform-v1".into(),
            pos_origin: vec![0.0; 3],
            step_pos: 1e-4,
            step_scale_log: 0.04,
            step_rot: 0.004,
            step_rgb: 2.0 / 255.0,
            step_alpha: 2.0 / 255.0,
            step_motion: 4e-4,
            step_time: 0.004,
            step_sigma_log: 0.04,
            step_sh: 1,
            bounds: BTreeMap::new(),
            sh_bit_depths: Vec::new(),
        }
        .encode(&[]),
    );
    out.extend_from_slice(
        &WindowTable {
            windows: vec![(0.0, 1.0)],
        }
        .encode(),
    );
    out.extend_from_slice(&fourdgs::records::Footer::default().encode());
    out.extend_from_slice(&MAGIC);
    out
}

#[test]
fn a_file_that_is_not_ours_is_refused_as_a_version_problem() {
    let err = fourdgs::read_bytes(&[0u8; 64]).unwrap_err();
    assert!(
        err.is_unsupported_version(),
        "expected an unsupported version, got {err}"
    );
    // The stronger statement: not merely refused, refused for a reason it can name — the
    // same identifier every other SDK prints for this file.
    assert_eq!(
        err.refusal_code(),
        Some(fourdgs::error::refusal::MAGIC_MISMATCH)
    );
}

#[test]
fn a_future_major_version_names_itself() {
    let mut data = minimal_file();
    data[5] = b'9';
    let err = fourdgs::read_bytes(&data).unwrap_err();
    // The fix for this is a newer reader, not a new file, so it must not be reported as
    // corruption.
    assert!(err.is_unsupported_version());
    assert_eq!(
        err.refusal_code(),
        Some(fourdgs::error::refusal::UNSUPPORTED_MAJOR_VERSION)
    );
    assert!(
        err.to_string().contains('9'),
        "the message names the version: {err}"
    );
}

#[test]
fn the_minimal_file_decodes() {
    let scene = fourdgs::read_bytes(&minimal_file()).expect("a header and grids are enough");
    assert_eq!(scene.gaussians.count(), 0);
    assert!(!scene.truncated);
    assert_eq!(
        scene.summary_crc_ok, None,
        "a file with no index declares no CRC"
    );
}

#[test]
fn unknown_and_private_records_are_stepped_over() {
    let mut data = minimal_file();
    // Splice two records a version-1 reader has never seen in front of the Footer: one
    // from the specification range and one from the application range.
    let footer_at = data.len() - MAGIC.len() - 29;
    let mut extra = Vec::new();
    put_record(&mut extra, 0x7D, b"a record from a later minor revision");
    put_record(&mut extra, 0x91, b"an application's own record");
    data.splice(footer_at..footer_at, extra);

    let scene = fourdgs::read_bytes(&data).expect("unknown records are skipped, not fatal");
    assert_eq!(scene.skipped_opcodes, vec![0x7D, 0x91]);
    assert!(op::is_private(0x91) && !op::is_private(0x7D));
}

#[test]
fn a_record_that_grew_fields_is_still_read() {
    // A newer writer appends to a frozen record. A reader that assumed the record ended
    // where its own knowledge ran out would desynchronize on everything after it.
    let mut out = Vec::new();
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(
        &Header {
            duration_sec: 2.5,
            gaussian_count: 0,
            aabb: vec![0.0; 6],
            cutoff: 0.05,
            temporal_model: "gaussian-birth".into(),
            ..Default::default()
        }
        .encode(b"\x01\x00\x00\x00a field from the future"),
    );
    let base = minimal_file();
    let header_end =
        8 + 9 + u64::from_le_bytes(base[9..17].try_into().expect("eight bytes")) as usize;
    out.extend_from_slice(&base[header_end..]);

    let scene = fourdgs::read_bytes(&out).expect("appended fields are stepped over");
    assert_eq!(scene.header.duration_sec, 2.5);
}

#[test]
fn a_truncated_file_keeps_what_it_had() {
    let data = minimal_file();
    let scene = fourdgs::read_bytes(&data[..data.len() - 1]).expect("a cut file is recoverable");
    assert!(
        scene.truncated,
        "a file missing its trailing magic is a cut"
    );
    assert_eq!(
        scene.header.duration_sec, 1.0,
        "the header survived the cut"
    );
}

#[test]
fn a_file_with_no_header_is_malformed() {
    let mut out = Vec::new();
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(&fourdgs::records::Footer::default().encode());
    out.extend_from_slice(&MAGIC);
    let err = fourdgs::read_bytes(&out).unwrap_err();
    assert!(matches!(err, Error::Malformed(_)), "got {err}");
}

#[test]
fn a_record_length_past_the_end_is_a_truncation_not_an_allocation() {
    // The declared length here is larger than any machine will allocate. A reader that
    // sized a buffer from it before checking the resource would die here rather than
    // report a bad file.
    let base = minimal_file();
    let mut out = base[..base.len() - MAGIC.len() - 29].to_vec();
    out.push(op::METADATA);
    out.extend_from_slice(&u64::MAX.to_le_bytes());
    out.extend_from_slice(b"short");
    let scene = fourdgs::read_bytes(&out).expect("an impossible length is a cut, not a crash");
    assert!(scene.truncated, "a length past the end is a truncation");
    assert_eq!(
        scene.header.duration_sec, 1.0,
        "what came before the bad record stands"
    );
}

#[test]
fn zigzag_round_trips_across_the_signed_range() {
    for v in [
        0i64,
        1,
        -1,
        2,
        -2,
        i32::MAX as i64,
        i32::MIN as i64,
        i64::MAX,
        i64::MIN,
    ] {
        assert_eq!(unzigzag(zigzag(v)), v, "zigzag round trip for {v}");
    }
}

#[test]
fn rounding_breaks_ties_to_even() {
    // Exact halves happen constantly on synthetic data, and away-from-zero rounding here
    // would put this encoder on a different grid from every other one in the repository.
    assert_eq!(rint(0.5), 0);
    assert_eq!(rint(1.5), 2);
    assert_eq!(rint(2.5), 2);
    assert_eq!(rint(-0.5), 0);
    assert_eq!(rint(-1.5), -2);
    assert_eq!(rint(-2.5), -2);
    assert_eq!(rint(2.4), 2);
    assert_eq!(rint(2.6), 3);
}

#[test]
fn the_support_constant_follows_the_files_own_cutoff() {
    // A decoder that substitutes the default decodes different velocities on any file
    // that declares something else, and the file gives it no way to notice.
    let default = support_k(0.05);
    let custom = support_k(0.2);
    assert!(custom < default, "a looser cutoff means a narrower support");

    // A sigma chosen so the two cutoffs land either side of a class boundary; on most
    // sigmas they agree, which is why this has to be picked rather than guessed.
    let steps = Steps::of(&Bounds::for_profile(Profile::Default, 1e-3));
    let bin = (0.24f64.ln() / steps.sigma_log).round() as i64;
    let with_default = life_class(bin, steps.sigma_log, false, 1.0, default);
    let with_custom = life_class(bin, steps.sigma_log, false, 1.0, custom);
    assert_ne!(
        with_default, with_custom,
        "the cutoff has to reach the velocity precision class"
    );
}

#[test]
fn birth_time_precision_follows_the_gaussians_own_sigma() {
    let steps = Steps::of(&Bounds::for_profile(Profile::Default, 1e-3));
    // A gaussian that never fades gets the reference pitch; a short-lived one gets a
    // finer one, because the temporal term reads (t - mu) / sigma and never mu alone.
    let never = mu_step(0, steps.sigma_log, true, steps.time);
    let tiny = mu_step(-120, steps.sigma_log, false, steps.time);
    assert_eq!(never, steps.time);
    assert!(
        tiny < steps.time,
        "a 1 ms sigma needs a finer birth-time grid"
    );
}

#[test]
fn an_absent_window_table_reads_as_one_empty_window() {
    // Degenerate, well defined, and not an error: every gaussian references index 0 and
    // nothing is visible at any time.
    let table = fourdgs::chunk::window_table_or_default(&[]);
    assert_eq!(table, &[(0.0, 0.0)]);
}

#[test]
fn an_out_of_range_window_index_is_refused_rather_than_clamped() {
    // Clamping substitutes one gaussian's lifetime for another's, in a file that is
    // already wrong in some way nobody has diagnosed.
    let err = fourdgs::chunk::check_window_index(4, 2).unwrap_err();
    assert!(err.to_string().contains('4') && err.to_string().contains('2'));
    assert!(fourdgs::chunk::check_window_index(-1, 2).is_err());
    assert_eq!(fourdgs::chunk::check_window_index(1, 2).unwrap(), 1);
}

#[test]
fn an_unimplemented_codec_is_refused_by_name() {
    // A different failure from a corrupt file: the file is fine, this build cannot read
    // it, and the message has to say which codec so the fix is obvious.
    let err = fourdgs::codec::decompress(b"anything", 200, 16).unwrap_err();
    assert!(err.is_unsupported_feature(), "got {err}");
    assert_eq!(
        err.refusal_code(),
        Some(fourdgs::error::refusal::UNKNOWN_STREAM_CODEC)
    );
    assert!(err.to_string().contains("200"));
}

#[test]
fn a_deflate_stream_that_lies_about_its_size_is_refused() {
    let raw = b"the quick brown fox";
    let packed = fourdgs::codec::compress(raw, fourdgs::codec::DEFLATE, 6).expect("deflate");
    assert_eq!(
        fourdgs::codec::decompress(&packed, fourdgs::codec::DEFLATE, raw.len()).unwrap(),
        raw
    );
    // Under-declared: the stream holds more than the header says, so array sizes derived
    // from that header would be wrong.
    assert!(fourdgs::codec::decompress(&packed, fourdgs::codec::DEFLATE, 4).is_err());
    // Over-declared: the stream ends early.
    assert!(fourdgs::codec::decompress(&packed, fourdgs::codec::DEFLATE, 400).is_err());
}

#[test]
fn spherical_harmonic_bands_must_form_whole_degrees() {
    // Bands are whole and a reader takes them whole: bands 1..D give exactly a degree-D
    // scene, and a partial degree is never assembled out of part of a band.
    let mut only_band_two: BTreeMap<u8, fourdgs::stream::DecodedStream> = BTreeMap::new();
    only_band_two.insert(
        2,
        fourdgs::stream::DecodedStream {
            values: vec![0; 15],
            count: 1,
            channels: 15,
            constant: false,
        },
    );
    let err = fourdgs::sh::merge_chunk_bands(&[1], &[only_band_two]).unwrap_err();
    assert!(err.to_string().contains("whole degrees"), "got {err}");
}

/// A default Header declares a temporal model the registry lists.
///
/// This was empty, and the emptiness only surfaced through a cross-language test: the
/// Python validator refused a fixture the Rust one accepted, because Python's dataclass
/// has always defaulted the field to `gaussian-birth` and Rust's derived `Default` left
/// it blank. Nothing in one language could see it. Pinning it here means the next person
/// to add a field to `Header` and reach for `#[derive(Default)]` finds out immediately.
#[test]
fn a_default_header_declares_the_temporal_model_this_version_defines() {
    assert_eq!(
        fourdgs::records::Header::default().temporal_model,
        "gaussian-birth",
        "a Header built from Default must not describe a file every conforming reader refuses"
    );
}

#[test]
fn a_finite_quaternion_near_the_top_of_the_range_is_not_refused() {
    // Section 5.15.4 refuses "zero or non-finite norms" — a claim about the quaternion,
    // not about the arithmetic used to measure it. Only the naive sum of squares
    // overflows on [1e308, 0, 0, 0], so squaring first refuses a file the format allows.
    let trajectory = RigTrajectory {
        name: "rig".into(),
        interpolation: 0,
        times: vec![0.0],
        rotations: vec![[1e308, 0.0, 0.0, 0.0]],
        translations: vec![[0.0; 3]],
    };
    assert!(trajectory.check().is_ok());

    // A quaternion with no direction is still refused; that is what the sentence means.
    let zero = RigTrajectory {
        rotations: vec![[0.0; 4]],
        ..trajectory.clone()
    };
    assert!(zero.check().is_err());
}

#[test]
fn a_zero_sample_trajectory_is_read_as_absent_rather_than_refused() {
    // Section 5.15.4: it "MUST be read as though the record were absent", so reading one
    // refuses nothing — not even interpolation 7, which describes how to read samples the
    // record does not carry. `check` stays strict for the writer.
    let body = [3u8, 0, 0, 0, b'r', b'i', b'g', 7, 0, 0, 0, 0];
    let trajectory = RigTrajectory::parse(&body).expect("a zero-sample trajectory reads as absent");
    assert_eq!(trajectory.sample_count(), 0);

    let written = RigTrajectory {
        name: "rig".into(),
        interpolation: 7,
        times: vec![0.0],
        rotations: vec![[0.0, 0.0, 0.0, 1.0]],
        translations: vec![[0.0; 3]],
    };
    assert!(written.check().is_err());
}
