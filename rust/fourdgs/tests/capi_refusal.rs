// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The refusal identifier on the C ABI, read the way a binding reads it.
//!
//! `Error::refusal_code` is already covered by the decode tests. What this file covers is
//! the crossing: that the identifier survives the boundary as the pointer and length the
//! header promises, that it names the refusal a caller could not otherwise tell from the
//! status code, and that it is absent — not stale — for the errors the specification's
//! refusal table does not name.

use std::collections::BTreeMap;
use std::ffi::{c_char, c_int, CStr};

use fourdgs::capi::*;
use fourdgs::error::refusal;
use fourdgs::records::{Footer, Header, Quantization, WindowTable};
use fourdgs::serialization::MAGIC;

/// Read the identifier the way C does: a pointer and a length, never a C string.
///
/// Deliberately not `CStr::from_ptr`. These strings are length-delimited, and reading one
/// as a C string is the exact bug this shape exists to prevent — it reads past the end when
/// the bytes are not NUL-terminated.
fn last_refusal_code() -> Option<String> {
    let mut data: *const c_char = std::ptr::null();
    let mut length: usize = usize::MAX;
    // SAFETY: both out parameters are live locals for the duration of the call.
    let status = unsafe { fourdgs_last_refusal_code(&mut data, &mut length) };
    assert_eq!(
        status, FOURDGS_STATUS_OK,
        "reading the identifier is not itself a fallible operation"
    );
    if data.is_null() {
        assert_eq!(length, 0, "a null identifier carries a zero length");
        return None;
    }
    assert!(length > 0, "a non-null identifier is not empty");
    // SAFETY: the call above filled both out parameters, and the bytes are `'static`.
    let bytes = unsafe { std::slice::from_raw_parts(data as *const u8, length) };
    Some(String::from_utf8(bytes.to_vec()).expect("a refusal identifier is ASCII"))
}

/// The message beside it, for the tests that check the two describe one failure.
fn last_error() -> String {
    // SAFETY: `fourdgs_last_error` returns a NUL-terminated string, never null.
    unsafe { CStr::from_ptr(fourdgs_last_error()) }
        .to_string_lossy()
        .into_owned()
}

/// Open bytes through the C surface and hand back the status.
fn open_memory(bytes: &[u8]) -> c_int {
    let mut scene: *mut fourdgs_scene = std::ptr::null_mut();
    // SAFETY: `bytes` outlives the call, and any scene it produces is freed here.
    let status = unsafe { fourdgs_open_memory(bytes.as_ptr(), bytes.len(), &mut scene) };
    if !scene.is_null() {
        // SAFETY: the pointer came from a successful open and is dropped once.
        unsafe { fourdgs_scene_free(scene) };
    }
    status
}

/// A file whose Header and Quantization record are valid apart from the two names this
/// test wants to break. Both refusals reach the C surface as the same status code, which
/// is why the identifier has to tell them apart.
fn file_naming(temporal_model: &str, scheme: &str) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(
        &Header {
            duration_sec: 1.0,
            gaussian_count: 0,
            aabb: vec![0.0; 6],
            cutoff: 0.05,
            temporal_model: temporal_model.into(),
            ..Default::default()
        }
        .encode(&[]),
    );
    out.extend_from_slice(
        &Quantization {
            scheme: scheme.into(),
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
    out.extend_from_slice(&Footer::default().encode());
    out.extend_from_slice(&MAGIC);
    out
}

#[test]
fn a_refusing_open_names_the_refusal() {
    let status = open_memory(&[0u8; 64]);
    assert_eq!(status, FOURDGS_STATUS_UNSUPPORTED_VERSION);
    assert_eq!(
        last_refusal_code().as_deref(),
        Some(refusal::MAGIC_MISMATCH),
        "a buffer that is not a 4dgs file is refused by name"
    );
    // The sentence did not change when it gained a name: the identifier is additional
    // information about the same failure, not a replacement for the diagnosis.
    assert!(
        last_error().contains("not a 4dgs file"),
        "the message stands beside the identifier: {}",
        last_error()
    );
}

#[test]
fn the_identifier_separates_refusals_one_status_cannot() {
    // Three refusals, one status code. This is the whole reason the accessor exists: a
    // binding that switches on FOURDGS_STATUS_UNSUPPORTED_CODEC learns only that the file
    // is conforming and unreadable here, never which of the three it met.
    let mut version = MAGIC.to_vec();
    version[5] = b'9';
    version.extend_from_slice(&[0u8; 32]);
    assert_eq!(open_memory(&version), FOURDGS_STATUS_UNSUPPORTED_VERSION);
    assert_eq!(
        last_refusal_code().as_deref(),
        Some(refusal::UNSUPPORTED_MAJOR_VERSION),
        "a version this reader does not implement is not a bad magic"
    );

    let model = file_naming("wobble-v7", "uniform-v1");
    assert_eq!(open_memory(&model), FOURDGS_STATUS_UNSUPPORTED_CODEC);
    assert_eq!(
        last_refusal_code().as_deref(),
        Some(refusal::UNKNOWN_TEMPORAL_MODEL)
    );

    let scheme = file_naming("gaussian-birth", "logarithmic-v3");
    assert_eq!(open_memory(&scheme), FOURDGS_STATUS_UNSUPPORTED_CODEC);
    assert_eq!(
        last_refusal_code().as_deref(),
        Some(refusal::UNKNOWN_QUANTIZATION_SCHEME),
        "two refusals that share a status are still told apart"
    );
}

#[test]
fn an_error_the_table_does_not_name_exposes_no_identifier() {
    // Truncation is a real error and a common one; it is not a named refusal, and saying
    // "none" is the correct answer rather than a gap.
    assert_eq!(open_memory(&[0u8; 3]), FOURDGS_STATUS_TRUNCATED);
    assert_eq!(last_refusal_code(), None);

    // Nor is a caller's own mistake, which never reaches the refusal table at all.
    let mut scene: *mut fourdgs_scene = std::ptr::null_mut();
    // SAFETY: a null buffer with a non-zero length is the documented invalid argument.
    let status = unsafe { fourdgs_open_memory(std::ptr::null(), 8, &mut scene) };
    assert_eq!(status, FOURDGS_STATUS_INVALID_ARGUMENT);
    assert_eq!(last_refusal_code(), None);
}

#[test]
fn a_later_error_does_not_inherit_an_earlier_identifier() {
    assert_eq!(open_memory(&[0u8; 64]), FOURDGS_STATUS_UNSUPPORTED_VERSION);
    assert_eq!(
        last_refusal_code().as_deref(),
        Some(refusal::MAGIC_MISMATCH)
    );

    // A stale identifier would be worse than none: it would name a refusal for a file that
    // was refused for something else entirely.
    assert_eq!(open_memory(&[0u8; 3]), FOURDGS_STATUS_TRUNCATED);
    assert_eq!(
        last_refusal_code(),
        None,
        "the truncation is not a magic mismatch"
    );
}

#[test]
fn a_null_out_parameter_does_not_destroy_the_diagnosis() {
    assert_eq!(open_memory(&[0u8; 64]), FOURDGS_STATUS_UNSUPPORTED_VERSION);
    let message = last_error();

    let mut length: usize = 7;
    let mut data: *const c_char = std::ptr::null();
    // SAFETY: passing null is the documented invalid argument on this call.
    unsafe {
        assert_eq!(
            fourdgs_last_refusal_code(std::ptr::null_mut(), &mut length),
            FOURDGS_STATUS_INVALID_ARGUMENT
        );
        assert_eq!(
            fourdgs_last_refusal_code(&mut data, std::ptr::null_mut()),
            FOURDGS_STATUS_INVALID_ARGUMENT
        );
    }
    assert_eq!(length, 7, "a refused call leaves the out parameters alone");
    assert!(data.is_null(), "a refused call writes no pointer");

    // The accessor for the last error is the one call that must not become the last error.
    assert_eq!(last_error(), message);
    assert_eq!(
        last_refusal_code().as_deref(),
        Some(refusal::MAGIC_MISMATCH)
    );
}
