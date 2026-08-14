// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The bounded keyframe-delta validation seam, driven through the C ABI.

use std::ffi::{c_int, c_void, CStr};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use fourdgs::capi::*;
use fourdgs::keyframe_delta_file::{write_sequence, KeyframeDeltaOptions, Sample};
use fourdgs::model::GaussianSet;

struct Source {
    bytes: Vec<u8>,
    releases: Arc<AtomicUsize>,
    largest: usize,
}

unsafe extern "C" fn source_size(ctx: *mut c_void, out: *mut u64) -> c_int {
    // SAFETY: the validator passes back the live Source pointer stored in the reader.
    let source = unsafe { &mut *(ctx as *mut Source) };
    // SAFETY: the callback contract gives a live output pointer.
    unsafe { *out = source.bytes.len() as u64 };
    FOURDGS_STATUS_OK
}

unsafe extern "C" fn source_read(
    ctx: *mut c_void,
    offset: u64,
    length: u64,
    out: *mut u8,
) -> c_int {
    // SAFETY: the validator passes back the live Source pointer stored in the reader.
    let source = unsafe { &mut *(ctx as *mut Source) };
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
    source.largest = source.largest.max(length);
    // SAFETY: the callback contract supplies room for exactly `length` bytes.
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, length) };
    FOURDGS_STATUS_OK
}

unsafe extern "C" fn source_release(ctx: *mut c_void) {
    // SAFETY: the context was allocated with Box::into_raw and ownership transfers once.
    let source = unsafe { Box::from_raw(ctx as *mut Source) };
    source.releases.fetch_add(1, Ordering::SeqCst);
}

unsafe extern "C" fn clobbering_source_release(ctx: *mut c_void) {
    // SAFETY: this callback owns the same Source allocation as source_release.
    unsafe { source_release(ctx) };
    // SAFETY: the deliberately invalid argument tests release-time re-entry.
    unsafe { fourdgs_open_memory(std::ptr::null(), 1, std::ptr::null_mut()) };
}

unsafe extern "C" fn collect_identity(ctx: *mut c_void, record_offset: u64, id: u32) -> c_int {
    // SAFETY: the test keeps the vector live for the duration of the call.
    unsafe { &mut *(ctx as *mut Vec<(u64, u32)>) }.push((record_offset, id));
    FOURDGS_STATUS_OK
}

unsafe extern "C" fn reject_identity(_ctx: *mut c_void, _record_offset: u64, _id: u32) -> c_int {
    FOURDGS_STATUS_IO
}

fn reader(bytes: Vec<u8>, releases: Arc<AtomicUsize>) -> fourdgs_reader {
    let source = Box::new(Source {
        bytes,
        releases,
        largest: 0,
    });
    fourdgs_reader {
        ctx: Box::into_raw(source).cast(),
        size: Some(source_size),
        read: Some(source_read),
        release: Some(source_release),
    }
}

fn clobbering_reader(bytes: Vec<u8>, releases: Arc<AtomicUsize>) -> fourdgs_reader {
    let mut reader = reader(bytes, releases);
    reader.release = Some(clobbering_source_release);
    reader
}

fn sequence() -> Vec<u8> {
    let gaussian = GaussianSet {
        positions: vec![0.0, 0.0, 0.0],
        scales: vec![0.1, 0.1, 0.1],
        rotations: vec![0.0, 0.0, 0.0, 1.0],
        colors: vec![0.5, 0.5, 0.5, 1.0],
        motions: vec![0.0, 0.0, 0.0],
        mu_t: vec![0.0],
        sigma_t: vec![0.2],
        win_lo: vec![0.0],
        win_hi: vec![2.0],
        ..Default::default()
    };
    write_sequence(
        &[
            Sample {
                t0: 0.0,
                ids: vec![17],
                gaussians: gaussian.clone(),
            },
            Sample {
                t0: 1.0,
                ids: vec![19],
                gaussians: gaussian,
            },
        ],
        2.0,
        &KeyframeDeltaOptions::default(),
    )
    .unwrap()
}

#[test]
fn both_concrete_paths_stream_identities_and_release_the_source() {
    let bytes = sequence();
    for mode in [FOURDGS_OPEN_SEQUENTIAL, FOURDGS_OPEN_INDEXED] {
        let releases = Arc::new(AtomicUsize::new(0));
        let mut ids: Vec<(u64, u32)> = Vec::new();
        let mut declared = u64::MAX;
        // SAFETY: callbacks and their contexts remain live for the synchronous call.
        let status = unsafe {
            fourdgs_validate_keyframe_delta_reader(
                reader(bytes.clone(), releases.clone()),
                mode,
                (&mut ids as *mut Vec<(u64, u32)>).cast(),
                Some(collect_identity),
                &mut declared,
            )
        };
        assert_eq!(status, FOURDGS_STATUS_OK);
        assert_eq!(declared, 2);
        assert_eq!(ids.len(), 2);
        assert_eq!(ids[0].1, 17u32);
        assert_eq!(bytes[ids[0].0 as usize], fourdgs::opcode::CHUNK);
        assert_eq!(ids[1].1, 19u32);
        assert_eq!(bytes[ids[1].0 as usize], fourdgs::opcode::DELTA_CHUNK);
        assert_eq!(releases.load(Ordering::SeqCst), 1);
    }
}

#[test]
fn callback_failure_preserves_the_count_and_exposes_the_state_byte() {
    let releases = Arc::new(AtomicUsize::new(0));
    let mut declared = u64::MAX;
    // SAFETY: callbacks and their contexts remain live for the synchronous call.
    let status = unsafe {
        fourdgs_validate_keyframe_delta_reader(
            reader(sequence(), releases.clone()),
            FOURDGS_OPEN_INDEXED,
            std::ptr::null_mut(),
            Some(reject_identity),
            &mut declared,
        )
    };
    assert_eq!(status, FOURDGS_STATUS_IO);
    assert_eq!(declared, u64::MAX, "failure leaves the output untouched");
    assert_eq!(releases.load(Ordering::SeqCst), 1);
    let mut offset = u64::MAX;
    let mut has_offset = 0;
    // SAFETY: both outputs are live locals.
    assert_eq!(
        unsafe { fourdgs_last_error_offset(&mut offset, &mut has_offset) },
        FOURDGS_STATUS_OK
    );
    assert_eq!(has_offset, 1);
    assert!(offset > 0);
}

#[test]
fn release_reentry_cannot_overwrite_validation_diagnostics() {
    let releases = Arc::new(AtomicUsize::new(0));
    let mut declared = u64::MAX;
    // SAFETY: callbacks and their contexts remain live for the synchronous call.
    let status = unsafe {
        fourdgs_validate_keyframe_delta_reader(
            clobbering_reader(sequence(), releases.clone()),
            FOURDGS_OPEN_INDEXED,
            std::ptr::null_mut(),
            Some(reject_identity),
            &mut declared,
        )
    };
    assert_eq!(status, FOURDGS_STATUS_IO);
    // SAFETY: fourdgs_last_error always returns a live NUL-terminated thread-local string.
    let message = unsafe { CStr::from_ptr(fourdgs_last_error()) }.to_string_lossy();
    assert!(
        message.contains("identity callback returned status"),
        "{message}"
    );
    assert_eq!(releases.load(Ordering::SeqCst), 1);
}

#[test]
fn invalid_arguments_still_release_the_transferred_source() {
    let releases = Arc::new(AtomicUsize::new(0));
    let mut declared = 0;
    // SAFETY: null identity is the tested invalid argument.
    let status = unsafe {
        fourdgs_validate_keyframe_delta_reader(
            clobbering_reader(sequence(), releases.clone()),
            FOURDGS_OPEN_INDEXED,
            std::ptr::null_mut(),
            None,
            &mut declared,
        )
    };
    assert_eq!(status, FOURDGS_STATUS_INVALID_ARGUMENT);
    // SAFETY: fourdgs_last_error returns a live NUL-terminated thread-local string.
    let message = unsafe { CStr::from_ptr(fourdgs_last_error()) }.to_string_lossy();
    assert!(message.contains("identity callback is null"), "{message}");
    assert_eq!(releases.load(Ordering::SeqCst), 1);
}
