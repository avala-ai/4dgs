// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Aggregate decoded-state budgets at the C ABI boundary.
//!
//! The Rust collectors have their own focused accounting tests. These witnesses prove that the
//! append-only native surface passes the selected limit into those collectors, preserves the old
//! defaults, and exposes resource exhaustion as its own non-refusal result.

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use fourdgs::capi::*;
use fourdgs::keyframe_delta_file::{write_sequence, KeyframeDeltaOptions, Sample};
use fourdgs::model::GaussianSet;

fn one_gaussian() -> GaussianSet {
    GaussianSet {
        positions: vec![0.1, 0.2, 0.3],
        scales: vec![0.01, 0.01, 0.01],
        rotations: vec![0.0, 0.0, 0.0, 1.0],
        colors: vec![0.5, 0.5, 0.5, 0.75],
        motions: vec![0.0, 0.0, 0.0],
        mu_t: vec![0.5],
        sigma_t: vec![0.1],
        win_lo: vec![0.0],
        win_hi: vec![1.0],
        ..Default::default()
    }
}

fn gaussian_birth_file() -> Vec<u8> {
    fourdgs::write_to_vec(
        &one_gaussian(),
        1.0,
        &fourdgs::WriteOptions {
            max_depth: 0,
            min_chunk_gaussians: 1,
            ..Default::default()
        },
        &Default::default(),
    )
    .expect("encode one gaussian")
}

fn gaussian_birth_file_with_sh() -> Vec<u8> {
    let mut gaussians = one_gaussian();
    gaussians.sh_degree = 1;
    gaussians.sh_coefficients = 3;
    gaussians.sh = Some(vec![127; 9]);
    fourdgs::write_to_vec(
        &gaussians,
        1.0,
        &fourdgs::WriteOptions {
            max_depth: 0,
            min_chunk_gaussians: 1,
            sh_bands: 1,
            ..Default::default()
        },
        &Default::default(),
    )
    .expect("encode one gaussian with SH")
}

fn keyframe_delta_file() -> Vec<u8> {
    let mut gaussians = one_gaussian();
    gaussians.mu_t[0] = 0.0;
    write_sequence(
        &[Sample {
            t0: 0.0,
            ids: vec![7],
            gaussians,
        }],
        1.0,
        &KeyframeDeltaOptions::default(),
    )
    .expect("encode one keyframe")
}

fn last_error() -> String {
    // SAFETY: the ABI always returns a live NUL-terminated thread-local string.
    unsafe { CStr::from_ptr(fourdgs_last_error()) }
        .to_string_lossy()
        .into_owned()
}

fn assert_resource_limit(status: c_int, phase: &str, limit: u64) {
    assert_eq!(status, FOURDGS_STATUS_RESOURCE_LIMIT, "{}", last_error());
    assert_eq!(
        // SAFETY: both output pointers are live for the call.
        unsafe {
            let mut refusal: *const c_char = std::ptr::null();
            let mut length = usize::MAX;
            let result = fourdgs_last_refusal_code(&mut refusal, &mut length);
            assert!(refusal.is_null());
            assert_eq!(length, 0);
            result
        },
        FOURDGS_STATUS_OK
    );
    let message = last_error();
    assert!(message.contains("decoded-state"), "{message}");
    assert!(
        message.contains(&format!("configured limit is {limit} bytes")),
        "{message}"
    );
    assert!(message.contains(phase), "{message}");
}

unsafe fn open_memory(bytes: &[u8], mode: c_int, limit: u64) -> (*mut fourdgs_scene, c_int) {
    let mut scene = std::ptr::null_mut();
    // SAFETY: the byte slice and output pointer are live for the call.
    let status = unsafe {
        fourdgs_open_memory_with_options(bytes.as_ptr(), bytes.len(), mode, limit, &mut scene)
    };
    (scene, status)
}

#[test]
fn resource_limit_is_a_distinct_non_refusal_status() {
    assert_eq!(FOURDGS_STATUS_RESOURCE_LIMIT, 10);
    // SAFETY: status messages are static C strings.
    assert_eq!(
        unsafe { CStr::from_ptr(fourdgs_status_message(FOURDGS_STATUS_RESOURCE_LIMIT)) }.to_bytes(),
        b"resource limit"
    );

    let bytes = gaussian_birth_file();
    // SAFETY: helper owns no returned scene on this expected failing call.
    let (scene, status) = unsafe { open_memory(&bytes, FOURDGS_OPEN_SEQUENTIAL, 1) };
    assert!(scene.is_null());
    assert_resource_limit(status, "streamed gaussian-birth", 1);
}

#[test]
fn every_options_bearing_open_reaches_the_sequential_collector() {
    let bytes = gaussian_birth_file();

    let path = std::env::temp_dir().join(format!(
        "fourdgs-capi-aggregate-{}-{}.4dgs",
        std::process::id(),
        std::thread::current().name().unwrap_or("unnamed")
    ));
    std::fs::write(&path, &bytes).unwrap();
    let c_path = CString::new(path.to_string_lossy().as_bytes()).unwrap();
    let mut scene = std::ptr::null_mut();
    // SAFETY: the path and output pointer are live for the call.
    let status = unsafe {
        fourdgs_open_path_with_options(c_path.as_ptr(), FOURDGS_OPEN_SEQUENTIAL, 1, &mut scene)
    };
    std::fs::remove_file(&path).unwrap();
    assert!(scene.is_null());
    assert_resource_limit(status, "streamed gaussian-birth", 1);

    let releases = Arc::new(AtomicUsize::new(0));
    let reads = Arc::new(AtomicUsize::new(0));
    let reader = reader(bytes, Arc::clone(&releases), Arc::clone(&reads));
    // SAFETY: ownership of the reader context transfers to the call.
    let status =
        unsafe { fourdgs_open_reader_with_options(reader, FOURDGS_OPEN_SEQUENTIAL, 1, &mut scene) };
    assert!(scene.is_null());
    assert_resource_limit(status, "streamed gaussian-birth", 1);
    assert!(reads.load(Ordering::SeqCst) > 0);
    assert_eq!(releases.load(Ordering::SeqCst), 1);
}

#[test]
fn options_bearing_load_checks_a_cached_result_and_preserves_it() {
    let bytes = gaussian_birth_file_with_sh();
    // SAFETY: the helper returns an owned scene on success.
    let (scene, status) = unsafe {
        open_memory(
            &bytes,
            FOURDGS_OPEN_INDEXED,
            fourdgs::stream_reader::DEFAULT_MAX_DECODED_STATE_BYTES as u64,
        )
    };
    assert_eq!(status, FOURDGS_STATUS_OK, "{}", last_error());
    assert!(!scene.is_null());

    // First populate the indexed working set under the legacy default. The one-byte call then
    // exercises the cached-result branch: it must still reject, without discarding that state.
    // SAFETY: `scene` remains live through these calls and is freed once below.
    unsafe {
        assert_eq!(fourdgs_scene_load_all(scene, 0), FOURDGS_STATUS_OK);
        assert_eq!(fourdgs_scene_loaded_count(scene), 1);
        assert_eq!(fourdgs_scene_sh_coefficients(scene), 0);
        let before = fourdgs_scene_positions(scene);
        assert_resource_limit(
            fourdgs_scene_load_all_with_options(scene, 0, 1),
            "cached gaussian-birth load",
            1,
        );
        assert_eq!(fourdgs_scene_loaded_count(scene), 1);
        assert_eq!(fourdgs_scene_positions(scene), before);

        // Find the exact capacity of the cached base state, then request a higher SH band at that
        // limit. The old state fits but the replacement and its assembly workspace do not, which
        // exercises the transactional replacement path rather than the cached fast path.
        let mut low = 1u64;
        let mut high = 1u64 << 20;
        while low < high {
            let middle = low + (high - low) / 2;
            if fourdgs_scene_load_all_with_options(scene, 0, middle) == FOURDGS_STATUS_OK {
                high = middle;
            } else {
                low = middle + 1;
            }
        }
        assert_resource_limit(
            fourdgs_scene_load_all_with_options(scene, 1, low),
            "collection",
            low,
        );
        assert_eq!(fourdgs_scene_loaded_count(scene), 1);
        assert_eq!(fourdgs_scene_positions(scene), before);
        assert_eq!(
            fourdgs_scene_sh_coefficients(scene),
            0,
            "failed replacement preserves the band-capped state"
        );
        fourdgs_scene_free(scene);
    }
}

#[test]
fn hidden_object_json_collectors_inherit_the_open_budget() {
    let bytes = gaussian_birth_file();
    for states in [false, true] {
        // Indexed open itself retains no decoded gaussian state, so a one-byte scene can open.
        // The object-summary accessors perform their documented implicit whole-population load,
        // which must use the limit stored by the options-bearing open.
        // SAFETY: the helper returns an owned scene on success.
        let (scene, status) = unsafe { open_memory(&bytes, FOURDGS_OPEN_INDEXED, 1) };
        assert_eq!(status, FOURDGS_STATUS_OK, "{}", last_error());
        let mut output = std::ptr::null();
        let mut length = 0usize;
        // SAFETY: the scene and output parameters are live for the call.
        let status = unsafe {
            if states {
                fourdgs_scene_object_states_json(scene, &mut output, &mut length)
            } else {
                fourdgs_scene_objects_json(scene, &mut output, &mut length)
            }
        };
        assert!(output.is_null());
        assert_eq!(length, 0);
        assert_resource_limit(status, "indexed gaussian-birth", 1);
        // SAFETY: the scene came from the successful open and is freed once.
        unsafe { fourdgs_scene_free(scene) };
    }
}

#[test]
fn keyframe_delta_budget_reaches_both_collectors_but_not_serialization_output() {
    let bytes = keyframe_delta_file();
    for indexed in [0, 1] {
        let mut output = std::ptr::null();
        let mut length = 0usize;
        // SAFETY: the input and output parameters are live for the call.
        let status = unsafe {
            fourdgs_keyframe_delta_states_json_with_options(
                bytes.as_ptr(),
                bytes.len(),
                indexed,
                1,
                &mut output,
                &mut length,
            )
        };
        assert!(output.is_null());
        assert_eq!(length, 0);
        assert_resource_limit(status, if indexed == 0 { "streamed" } else { "indexed" }, 1);
    }

    // The old entry point remains a shared-default wrapper. Its owned canonical string is output
    // formatting, not decoded gaussian state or decode workspace under §3.3, so no second,
    // undocumented JSON-size ceiling is applied here.
    let mut output = std::ptr::null();
    let mut length = 0usize;
    // SAFETY: all pointers remain live; successful output is freed with its paired length.
    unsafe {
        assert_eq!(
            fourdgs_keyframe_delta_states_json(
                bytes.as_ptr(),
                bytes.len(),
                0,
                &mut output,
                &mut length,
            ),
            FOURDGS_STATUS_OK,
            "{}",
            last_error()
        );
        assert!(!output.is_null());
        assert!(length > 0);
        fourdgs_string_free(output, length);
    }
}

#[test]
fn zero_budget_is_rejected_before_io_and_releases_reader_once() {
    let mut scene = std::ptr::null_mut();
    // An empty buffer would otherwise fail at the magic. Naming the option instead proves zero is
    // validated before input parsing or copying.
    // SAFETY: the output pointer is live and empty input dereferences no data pointer.
    let status = unsafe {
        fourdgs_open_memory_with_options(
            std::ptr::null(),
            0,
            FOURDGS_OPEN_SEQUENTIAL,
            0,
            &mut scene,
        )
    };
    assert_eq!(status, FOURDGS_STATUS_INVALID_ARGUMENT);
    assert!(last_error().contains("max_decoded_state_bytes"));
    assert!(scene.is_null());

    let missing = CString::new("/fourdgs-budget-test-must-not-open").unwrap();
    // SAFETY: the path and output pointer are live. A zero limit must win before filesystem I/O.
    let status = unsafe {
        fourdgs_open_path_with_options(missing.as_ptr(), FOURDGS_OPEN_SEQUENTIAL, 0, &mut scene)
    };
    assert_eq!(status, FOURDGS_STATUS_INVALID_ARGUMENT);
    assert!(last_error().contains("max_decoded_state_bytes"));
    assert!(scene.is_null());

    let releases = Arc::new(AtomicUsize::new(0));
    let reads = Arc::new(AtomicUsize::new(0));
    let reader = reader(
        gaussian_birth_file(),
        Arc::clone(&releases),
        Arc::clone(&reads),
    );
    // SAFETY: reader ownership transfers even though the option is invalid.
    let status =
        unsafe { fourdgs_open_reader_with_options(reader, FOURDGS_OPEN_SEQUENTIAL, 0, &mut scene) };
    assert_eq!(status, FOURDGS_STATUS_INVALID_ARGUMENT);
    assert!(last_error().contains("max_decoded_state_bytes"));
    assert!(scene.is_null());
    assert_eq!(
        reads.load(Ordering::SeqCst),
        0,
        "zero is rejected before I/O"
    );
    assert_eq!(releases.load(Ordering::SeqCst), 1);

    let bytes = gaussian_birth_file();
    // SAFETY: the helper returns an owned indexed scene.
    let (scene, status) = unsafe {
        open_memory(
            &bytes,
            FOURDGS_OPEN_INDEXED,
            fourdgs::stream_reader::DEFAULT_MAX_DECODED_STATE_BYTES as u64,
        )
    };
    assert_eq!(status, FOURDGS_STATUS_OK);
    // SAFETY: the live scene is unchanged by invalid options and then freed once.
    unsafe {
        assert_eq!(
            fourdgs_scene_load_all_with_options(scene, 3, 0),
            FOURDGS_STATUS_INVALID_ARGUMENT
        );
        assert!(last_error().contains("max_decoded_state_bytes"));
        assert_eq!(fourdgs_scene_loaded_count(scene), 0);
        fourdgs_scene_free(scene);
    }

    let bytes = keyframe_delta_file();
    let mut output = std::ptr::null();
    let mut length = 0usize;
    // SAFETY: output pointers are live; invalid options allocate no result.
    let status = unsafe {
        fourdgs_keyframe_delta_states_json_with_options(
            bytes.as_ptr(),
            bytes.len(),
            0,
            0,
            &mut output,
            &mut length,
        )
    };
    assert_eq!(status, FOURDGS_STATUS_INVALID_ARGUMENT);
    assert!(output.is_null());
    assert_eq!(length, 0);
}

struct ReaderSource {
    bytes: Vec<u8>,
    releases: Arc<AtomicUsize>,
    reads: Arc<AtomicUsize>,
}

unsafe extern "C" fn reader_size(ctx: *mut c_void, out: *mut u64) -> c_int {
    // SAFETY: the ABI passes back the live context pointer stored in the reader.
    let source = unsafe { &*(ctx as *const ReaderSource) };
    // SAFETY: the callback contract provides a live output pointer.
    unsafe { *out = source.bytes.len() as u64 };
    FOURDGS_STATUS_OK
}

unsafe extern "C" fn reader_read(
    ctx: *mut c_void,
    offset: u64,
    length: u64,
    out: *mut u8,
) -> c_int {
    // SAFETY: the ABI passes back the live context pointer stored in the reader.
    let source = unsafe { &*(ctx as *const ReaderSource) };
    let Ok(start) = usize::try_from(offset) else {
        return FOURDGS_STATUS_IO;
    };
    let Ok(length) = usize::try_from(length) else {
        return FOURDGS_STATUS_IO;
    };
    let Some(end) = start.checked_add(length) else {
        return FOURDGS_STATUS_IO;
    };
    let Some(bytes) = source.bytes.get(start..end) else {
        return FOURDGS_STATUS_IO;
    };
    source.reads.fetch_add(1, Ordering::SeqCst);
    // SAFETY: the callback contract supplies exactly `length` writable bytes.
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, length) };
    FOURDGS_STATUS_OK
}

unsafe extern "C" fn reader_release(ctx: *mut c_void) {
    // SAFETY: ownership transferred from Box::into_raw exactly once.
    let source = unsafe { Box::from_raw(ctx as *mut ReaderSource) };
    source.releases.fetch_add(1, Ordering::SeqCst);
}

fn reader(bytes: Vec<u8>, releases: Arc<AtomicUsize>, reads: Arc<AtomicUsize>) -> fourdgs_reader {
    let source = Box::new(ReaderSource {
        bytes,
        releases,
        reads,
    });
    fourdgs_reader {
        ctx: Box::into_raw(source).cast(),
        size: Some(reader_size),
        read: Some(reader_read),
        release: Some(reader_release),
    }
}
