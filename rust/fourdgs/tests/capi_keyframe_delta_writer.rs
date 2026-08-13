// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The `keyframe-delta` encode surface on the C ABI, driven the way a binding drives it.
//!
//! `write_sequence` itself is covered by `tests/keyframe_delta.rs`. What this file covers is
//! the crossing: that a sequence assembled one sample at a time through opaque pointers
//! produces the file the Rust caller would have got, that the id column is carried rather
//! than invented from row order, that the options reach the encoder, and that the refusals
//! the model depends on arrive as statuses instead of as a file nobody notices is wrong.

use std::ffi::{c_char, c_int};

use fourdgs::capi::*;
use fourdgs::keyframe_delta_file as kdf;

/// One population at one instant, as nine flat columns.
struct Columns {
    ids: Vec<u32>,
    positions: Vec<f32>,
    scales: Vec<f32>,
    rotations: Vec<f32>,
    colors: Vec<f32>,
    motions: Vec<f32>,
    mu_t: Vec<f32>,
    sigma_t: Vec<f32>,
    win_lo: Vec<f32>,
    win_hi: Vec<f32>,
}

impl Columns {
    /// `rows` is one `[x, y, z]` per gaussian; sigma is finite because this reference encoder
    /// requires it, and the window spans the clip.
    fn new(ids: &[u32], rows: &[[f32; 3]], duration: f32) -> Columns {
        let n = rows.len();
        Columns {
            ids: ids.to_vec(),
            positions: rows.iter().flat_map(|r| r.iter().copied()).collect(),
            scales: vec![0.05; n * 3],
            rotations: (0..n).flat_map(|_| [0.0, 0.0, 0.0, 1.0]).collect(),
            colors: (0..n).flat_map(|_| [0.6, 0.4, 0.2, 0.9]).collect(),
            motions: vec![0.0; n * 3],
            mu_t: vec![0.0; n],
            sigma_t: vec![100.0; n],
            win_lo: vec![0.0; n],
            win_hi: vec![duration; n],
        }
    }
}

/// Push one sample through the ABI.
///
/// # Safety
/// `writer` must be a live handle from `fourdgs_kd_writer_new`.
unsafe fn add(writer: *mut fourdgs_kd_writer, t0: f64, c: &Columns) -> c_int {
    unsafe {
        fourdgs_kd_writer_add_sample(
            writer,
            t0,
            c.ids.len() as u32,
            c.ids.as_ptr(),
            c.positions.as_ptr(),
            c.scales.as_ptr(),
            c.rotations.as_ptr(),
            c.colors.as_ptr(),
            c.motions.as_ptr(),
            c.mu_t.as_ptr(),
            c.sigma_t.as_ptr(),
            c.win_lo.as_ptr(),
            c.win_hi.as_ptr(),
        )
    }
}

/// Copy the encoded bytes out and free the core's buffer, as a binding does.
///
/// # Safety
/// `writer` must be a live handle from `fourdgs_kd_writer_new`.
unsafe fn encode(writer: *mut fourdgs_kd_writer) -> Result<Vec<u8>, c_int> {
    let mut buffer: *mut fourdgs_buffer = std::ptr::null_mut();
    // SAFETY: `buffer` is a live local for the duration of the call.
    let status = unsafe { fourdgs_kd_writer_encode(writer, &mut buffer) };
    if status != FOURDGS_STATUS_OK {
        assert!(
            buffer.is_null(),
            "a failed encode must leave the out parameter untouched"
        );
        return Err(status);
    }
    // SAFETY: the call returned OK, so `buffer` owns a live allocation.
    let bytes = unsafe {
        let data = fourdgs_buffer_data(buffer);
        let len = fourdgs_buffer_len(buffer);
        let copy = std::slice::from_raw_parts(data, len).to_vec();
        fourdgs_buffer_free(buffer);
        copy
    };
    Ok(bytes)
}

/// A two-sample drift of four gaussians over an eight-second clip.
fn drift() -> (Columns, Columns) {
    (
        Columns::new(
            &[0, 1, 2, 3],
            &[[0.0; 3], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [1.0, 1.0, 0.0]],
            8.0,
        ),
        Columns::new(
            &[0, 1, 2, 3],
            &[
                [0.1, 0.0, 0.0],
                [1.0, 0.05, 0.0],
                [0.0, 1.0, 0.03],
                [1.0, 1.0, 0.0],
            ],
            8.0,
        ),
    )
}

fn lend(text: &str) -> (*const c_char, usize) {
    (text.as_ptr() as *const c_char, text.len())
}

#[test]
fn a_sequence_assembled_through_the_abi_is_the_file_rust_would_have_written() {
    let (first, second) = drift();
    // SAFETY: every pointer below is a live local, and the handle is freed at the end.
    unsafe {
        let writer = fourdgs_kd_writer_new();
        assert!(!writer.is_null());
        assert_eq!(
            fourdgs_kd_writer_set_duration(writer, 8.0),
            FOURDGS_STATUS_OK
        );
        assert_eq!(fourdgs_kd_writer_sample_count(writer), 0);
        assert_eq!(add(writer, 0.0, &first), FOURDGS_STATUS_OK);
        assert_eq!(add(writer, 4.0, &second), FOURDGS_STATUS_OK);
        assert_eq!(fourdgs_kd_writer_sample_count(writer), 2);
        let bytes = encode(writer).expect("encode");
        fourdgs_kd_writer_free(writer);

        assert_eq!(kdf::peek_temporal_model(&bytes).unwrap(), "keyframe-delta");
        let decoded = kdf::decode_streamed(&bytes).expect("decode");
        // Two state chunks tiling [0, 8): the second sample is a delta against the first,
        // because the default cadence is eight.
        assert_eq!(decoded.chunks.len(), 2);
        // The indexed path is the one that checks the tiling and walks the chain, so a wrong
        // offset or a wrong reference shows up only here.
        kdf::decode_indexed(&bytes).expect("indexed decode");
    }
}

#[test]
fn the_id_column_is_carried_and_not_invented_from_row_order() {
    // The same population, stated in a different row order the second time. Correspondence
    // is by id, so nothing was born and nothing died — a writer that numbered rows instead
    // would see four deaths and four births and compose a different population.
    let rows = [[0.0; 3], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [1.0, 1.0, 0.0]];
    let straight = Columns::new(&[0, 1, 2, 3], &rows, 8.0);
    let rotated = Columns::new(&[3, 0, 1, 2], &[rows[3], rows[0], rows[1], rows[2]], 8.0);
    // SAFETY: as above.
    let bytes = unsafe {
        let writer = fourdgs_kd_writer_new();
        assert_eq!(
            fourdgs_kd_writer_set_duration(writer, 8.0),
            FOURDGS_STATUS_OK
        );
        assert_eq!(add(writer, 0.0, &straight), FOURDGS_STATUS_OK);
        assert_eq!(add(writer, 4.0, &rotated), FOURDGS_STATUS_OK);
        let bytes = encode(writer).expect("encode");
        fourdgs_kd_writer_free(writer);
        bytes
    };
    let decoded = kdf::decode_streamed(&bytes).expect("decode");
    let json = kdf::keyframe_delta_states_json(&decoded);
    assert!(
        json.contains("\"liveCount\":\"4\""),
        "the population changed size across a pure reordering: {json:.400}"
    );
    assert!(
        !json.contains("\"liveCount\":\"8\""),
        "ids were taken from row order"
    );
}

#[test]
fn the_options_reach_the_encoder() {
    let (first, second) = drift();
    // SAFETY: as above.
    let (default_profile, coarse, named) = unsafe {
        let build = |profile: Option<&str>, library: Option<&str>| {
            let writer = fourdgs_kd_writer_new();
            assert_eq!(
                fourdgs_kd_writer_set_duration(writer, 8.0),
                FOURDGS_STATUS_OK
            );
            if let Some(name) = profile {
                let (ptr, len) = lend(name);
                assert_eq!(
                    fourdgs_kd_writer_set_profile(writer, ptr, len),
                    FOURDGS_STATUS_OK
                );
            }
            if let Some(name) = library {
                let (ptr, len) = lend(name);
                assert_eq!(
                    fourdgs_kd_writer_set_library(writer, ptr, len),
                    FOURDGS_STATUS_OK
                );
            }
            assert_eq!(add(writer, 0.0, &first), FOURDGS_STATUS_OK);
            assert_eq!(add(writer, 4.0, &second), FOURDGS_STATUS_OK);
            let bytes = encode(writer).expect("encode");
            fourdgs_kd_writer_free(writer);
            bytes
        };
        (
            build(None, None),
            build(Some("coarse"), None),
            build(None, Some("a binding")),
        )
    };
    // A different bound profile is a different grid, so it cannot be the same bytes. This is
    // what catches an option that was accepted and then dropped on the floor.
    assert_ne!(default_profile, coarse);
    assert!(
        named.windows(9).any(|w| w == b"a binding"),
        "the library string never reached the Header"
    );
}

#[test]
fn a_delta_mode_that_is_not_a_mode_is_refused_before_it_is_written() {
    // SAFETY: as above.
    unsafe {
        let writer = fourdgs_kd_writer_new();
        assert_eq!(
            fourdgs_kd_writer_set_cadence(writer, 4, 0),
            FOURDGS_STATUS_OK
        );
        assert_eq!(
            fourdgs_kd_writer_set_cadence(writer, 4, 1),
            FOURDGS_STATUS_OK
        );
        assert_eq!(
            fourdgs_kd_writer_set_cadence(writer, 4, 2),
            FOURDGS_STATUS_INVALID_ARGUMENT,
            "2 is not a delta mode and a file carrying it is one no reader accepts"
        );
        fourdgs_kd_writer_free(writer);
    }
}

#[test]
fn a_profile_this_encoder_does_not_quantize_against_is_refused() {
    // SAFETY: as above.
    unsafe {
        let writer = fourdgs_kd_writer_new();
        let (ptr, len) = lend("lossless");
        assert_eq!(
            fourdgs_kd_writer_set_profile(writer, ptr, len),
            FOURDGS_STATUS_INVALID_ARGUMENT
        );
        fourdgs_kd_writer_free(writer);
    }
}

#[test]
fn an_empty_sequence_is_invalid_input_rather_than_an_empty_file() {
    // SAFETY: as above.
    unsafe {
        let writer = fourdgs_kd_writer_new();
        assert_eq!(
            fourdgs_kd_writer_set_duration(writer, 1.0),
            FOURDGS_STATUS_OK
        );
        assert_eq!(encode(writer), Err(FOURDGS_STATUS_INVALID_ARGUMENT));
        fourdgs_kd_writer_free(writer);
    }
}

#[test]
fn a_null_column_on_a_non_empty_sample_is_an_argument_error() {
    let (first, _) = drift();
    // SAFETY: as above; the null is the point of the test.
    unsafe {
        let writer = fourdgs_kd_writer_new();
        let status = fourdgs_kd_writer_add_sample(
            writer,
            0.0,
            first.ids.len() as u32,
            first.ids.as_ptr(),
            std::ptr::null(),
            first.scales.as_ptr(),
            first.rotations.as_ptr(),
            first.colors.as_ptr(),
            first.motions.as_ptr(),
            first.mu_t.as_ptr(),
            first.sigma_t.as_ptr(),
            first.win_lo.as_ptr(),
            first.win_hi.as_ptr(),
        );
        assert_eq!(status, FOURDGS_STATUS_INVALID_ARGUMENT);
        assert_eq!(
            fourdgs_kd_writer_sample_count(writer),
            0,
            "a refused sample must not be kept"
        );
        fourdgs_kd_writer_free(writer);
    }
}

#[test]
fn null_is_safe_to_pass_everywhere() {
    // Rule 3 of the header, on the new surface. A binding that fails to allocate, or that
    // frees twice, must get a status rather than undefined behaviour.
    // SAFETY: null is the argument under test; every call documents that it accepts it.
    unsafe {
        assert_eq!(
            fourdgs_kd_writer_set_duration(std::ptr::null_mut(), 1.0),
            FOURDGS_STATUS_INVALID_ARGUMENT
        );
        assert_eq!(
            fourdgs_kd_writer_set_cutoff(std::ptr::null_mut(), 0.05),
            FOURDGS_STATUS_INVALID_ARGUMENT
        );
        assert_eq!(
            fourdgs_kd_writer_set_cadence(std::ptr::null_mut(), 4, 1),
            FOURDGS_STATUS_INVALID_ARGUMENT
        );
        assert_eq!(
            fourdgs_kd_writer_add_keyframe_at(std::ptr::null_mut(), 1),
            FOURDGS_STATUS_INVALID_ARGUMENT
        );
        assert_eq!(
            fourdgs_kd_writer_set_compression(std::ptr::null_mut(), 0, 6),
            FOURDGS_STATUS_INVALID_ARGUMENT
        );
        assert_eq!(fourdgs_kd_writer_sample_count(std::ptr::null()), 0);
        fourdgs_kd_writer_free(std::ptr::null_mut());

        let writer = fourdgs_kd_writer_new();
        assert_eq!(
            fourdgs_kd_writer_encode(writer, std::ptr::null_mut()),
            FOURDGS_STATUS_INVALID_ARGUMENT
        );
        fourdgs_kd_writer_free(writer);
    }
}

#[test]
fn a_gop_invariant_change_inside_a_group_is_refused() {
    // sigma_t derives the per-gaussian grids for motion and mu_t (spec §11.5), so a bin
    // difference taken across a change in it subtracts bins on two different grids. That
    // decodes into a wrong velocity rather than into an error, which is why the encoder has
    // to refuse it and the decoder cannot.
    let mut first = Columns::new(&[7], &[[0.0; 3]], 8.0);
    first.sigma_t = vec![100.0];
    let mut second = Columns::new(&[7], &[[0.1, 0.0, 0.0]], 8.0);
    second.sigma_t = vec![3.0];
    // SAFETY: as above.
    unsafe {
        let writer = fourdgs_kd_writer_new();
        assert_eq!(
            fourdgs_kd_writer_set_duration(writer, 8.0),
            FOURDGS_STATUS_OK
        );
        assert_eq!(add(writer, 0.0, &first), FOURDGS_STATUS_OK);
        assert_eq!(add(writer, 4.0, &second), FOURDGS_STATUS_OK);
        assert_eq!(encode(writer), Err(FOURDGS_STATUS_INVALID_ARGUMENT));
        fourdgs_kd_writer_free(writer);
    }
}
