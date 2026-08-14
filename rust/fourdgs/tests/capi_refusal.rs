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
use fourdgs::indexed_reader::{MAX_INDEXED_STATE_RECORD_BYTES, MAX_RETAINED_RECORDS};
use fourdgs::opcode as op;
use fourdgs::records::{
    AudioData, AudioSource, AudioSourceKeyframe, ChunkIndexEntry, Footer, Header, Quantization,
    WindowTable, FLAG_HAS_AUDIO,
};
use fourdgs::serialization::{put_record, MAGIC, RECORD_HEADER_SIZE};

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

fn open_memory_indexed(bytes: &[u8]) -> c_int {
    let mut scene: *mut fourdgs_scene = std::ptr::null_mut();
    // SAFETY: `bytes` outlives the call, indexed is a valid mode, and any scene it
    // produces is freed here.
    let status = unsafe {
        fourdgs_open_memory_ex(
            bytes.as_ptr(),
            bytes.len(),
            FOURDGS_OPEN_INDEXED,
            &mut scene,
        )
    };
    if !scene.is_null() {
        // SAFETY: the pointer came from a successful open and is dropped once.
        unsafe { fourdgs_scene_free(scene) };
    }
    status
}

fn open_memory_sequential(bytes: &[u8]) -> c_int {
    let mut scene: *mut fourdgs_scene = std::ptr::null_mut();
    // SAFETY: `bytes` outlives the call, sequential is a valid mode, and any scene it
    // produces is freed here.
    let status = unsafe {
        fourdgs_open_memory_ex(
            bytes.as_ptr(),
            bytes.len(),
            FOURDGS_OPEN_SEQUENTIAL,
            &mut scene,
        )
    };
    if !scene.is_null() {
        // SAFETY: the pointer came from a successful open and is dropped once.
        unsafe { fourdgs_scene_free(scene) };
    }
    status
}

fn indexed_state_status(bytes: &[u8]) -> c_int {
    let mut scene: *mut fourdgs_scene = std::ptr::null_mut();
    // SAFETY: the byte slice outlives both calls and every returned allocation is freed.
    let open = unsafe {
        fourdgs_open_memory_ex(
            bytes.as_ptr(),
            bytes.len(),
            FOURDGS_OPEN_INDEXED,
            &mut scene,
        )
    };
    assert_eq!(
        open,
        FOURDGS_STATUS_OK,
        "indexed fixture opens: {}",
        last_error()
    );
    let mut state: *mut fourdgs_state = std::ptr::null_mut();
    // SAFETY: `scene` came from the successful open and `state` is a live out pointer.
    let status = unsafe { fourdgs_scene_state_at(scene, 0.5, 3, &mut state) };
    if !state.is_null() {
        // SAFETY: the pointer came from this call and is freed once.
        unsafe { fourdgs_state_free(state) };
    }
    // SAFETY: the pointer came from the successful open and is freed once.
    unsafe { fourdgs_scene_free(scene) };
    status
}

/// A file whose Header and Quantization record are valid apart from the two names this
/// test wants to break. Both refusals reach the C surface as the same status code, which
/// is why the identifier has to tell them apart.
fn file_naming(temporal_model: &str, scheme: &str) -> Vec<u8> {
    file_naming_with_header_trailer(temporal_model, scheme, &[])
}

fn file_naming_with_header_trailer(temporal_model: &str, scheme: &str, trailer: &[u8]) -> Vec<u8> {
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
        .encode(trailer),
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

fn file_with_state_ranges(
    chunk: &[u8],
    declared_chunk_length: u64,
    bands: &[(u8, Vec<u8>, u64)],
) -> Vec<u8> {
    let mut out = file_naming("gaussian-birth", "uniform-v1");
    let footer_and_magic = Footer::default().encode().len() + MAGIC.len();
    out.truncate(out.len() - footer_and_magic);
    let chunk_offset = out.len() as u64;
    out.extend_from_slice(chunk);

    let mut indexed_bands = Vec::new();
    for (band, bytes, declared_length) in bands {
        let offset = out.len() as u64;
        out.extend_from_slice(bytes);
        indexed_bands.push((*band, offset, *declared_length));
    }
    let summary_start = out.len() as u64;
    out.extend_from_slice(
        &ChunkIndexEntry {
            t0: 0.0,
            t1: 1.0,
            chunk_offset,
            chunk_length: declared_chunk_length,
            gaussian_count: 0,
            bands: indexed_bands,
            ..Default::default()
        }
        .encode(),
    );
    out.extend_from_slice(
        &Footer {
            summary_start,
            ..Default::default()
        }
        .encode(),
    );
    out.extend_from_slice(&MAGIC);
    out
}

fn file_with_audio_source(source: AudioSource, data: Vec<u8>) -> Vec<u8> {
    let mut out = file_naming("gaussian-birth", "uniform-v1");
    let footer_and_magic = Footer::default().encode().len() + MAGIC.len();
    let insert_at = out.len() - footer_and_magic;

    let mut audio = source.encode();
    audio.extend_from_slice(
        &AudioData {
            source_id: source.source_id,
            data,
        }
        .encode(),
    );
    out.splice(insert_at..insert_at, audio);

    // The Header is the first record. Its flags byte follows all other required fields;
    // parsing and re-encoding is clearer and less brittle than hard-coding that offset.
    let header_at = MAGIC.len();
    let content_length = u64::from_le_bytes(
        out[header_at + 1..header_at + RECORD_HEADER_SIZE]
            .try_into()
            .expect("Header length"),
    ) as usize;
    let mut header = Header::parse(
        &out[header_at + RECORD_HEADER_SIZE..header_at + RECORD_HEADER_SIZE + content_length],
    )
    .expect("base Header");
    header.flags |= FLAG_HAS_AUDIO;
    let encoded = header.encode(&[]);
    assert_eq!(
        encoded.len(),
        RECORD_HEADER_SIZE + content_length,
        "changing flags preserves Header framing"
    );
    out[header_at..header_at + encoded.len()].copy_from_slice(&encoded);
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

#[test]
fn indexed_c_abi_validates_audio_source_bodies_without_reading_payloads() {
    let bytes = file_with_audio_source(
        AudioSource {
            source_id: 7,
            codec: "wav".into(),
            channel_layout: "stereo".into(),
            data_length: 0,
            duration_sec: -1.0,
            rotation: [1.0, 0.0, 0.0, 0.0],
            interpolation: "linear".into(),
            ..Default::default()
        },
        Vec::new(),
    );

    let streamed = fourdgs::read_bytes(&bytes).expect_err("streamed validation sees the body");
    assert!(
        streamed
            .to_string()
            .contains("duration_sec must be finite and positive"),
        "{streamed}"
    );

    assert_eq!(
        open_memory_indexed(&bytes),
        FOURDGS_STATUS_MALFORMED,
        "the range-reader C ABI must validate the same descriptor body"
    );
    assert!(
        last_error().contains("Audio Source record at byte"),
        "{}",
        last_error()
    );
    assert!(
        last_error().contains("Audio Source 7 duration_sec must be finite and positive"),
        "{}",
        last_error()
    );
}

#[test]
fn c_abi_skips_large_legal_header_suffixes_on_both_read_paths() {
    let trailer = vec![0x5a; fourdgs::indexed_reader::HEAD_PROBE as usize * 128];
    let bytes = file_naming_with_header_trailer("gaussian-birth", "uniform-v1", &trailer);
    assert_eq!(open_memory_indexed(&bytes), FOURDGS_STATUS_OK);
    assert_eq!(open_memory_sequential(&bytes), FOURDGS_STATUS_OK);
}

#[test]
fn indexed_c_abi_validates_late_audio_source_semantics_with_record_bytes() {
    let valid = || AudioSource {
        source_id: 11,
        codec: "wav".into(),
        channel_layout: "mono".into(),
        duration_sec: 1.0,
        rotation: [1.0, 0.0, 0.0, 0.0],
        interpolation: "linear".into(),
        ..Default::default()
    };
    let cases: Vec<(&str, AudioSource, &str)> = vec![
        (
            "reserved flags",
            AudioSource {
                flags: 0x80,
                ..valid()
            },
            "reserved flag bits",
        ),
        (
            "non-finite position",
            AudioSource {
                position: [f64::NAN, 0.0, 0.0],
                ..valid()
            },
            "position must contain three finite values",
        ),
        (
            "zero rotation",
            AudioSource {
                rotation: [0.0; 4],
                ..valid()
            },
            "finite non-zero quaternion",
        ),
        (
            "late interpolation",
            AudioSource {
                interpolation: "cubic".into(),
                ..valid()
            },
            "unknown interpolation",
        ),
        (
            "keyframe past scene duration",
            AudioSource {
                keyframes: vec![AudioSourceKeyframe {
                    time: 2.0,
                    rotation: [1.0, 0.0, 0.0, 0.0],
                    ..Default::default()
                }],
                ..valid()
            },
            "outside [0, 1]",
        ),
    ];

    for (name, source, expected) in cases {
        let bytes = file_with_audio_source(source, Vec::new());
        assert_eq!(
            open_memory_indexed(&bytes),
            FOURDGS_STATUS_MALFORMED,
            "{name}"
        );
        let message = last_error();
        assert!(
            message.contains("Audio Source record at byte"),
            "{name}: {message}"
        );
        assert!(message.contains(expected), "{name}: {message}");
    }
}

#[test]
fn indexed_c_abi_caps_chunk_and_sh_ranges_before_transport_reads() {
    let chunk = fourdgs::records::encode_chunk(0.0, 1.0, 0, 0, &[]);
    let oversized_chunk = file_with_state_ranges(&chunk, MAX_INDEXED_STATE_RECORD_BYTES + 1, &[]);
    assert_eq!(
        indexed_state_status(&oversized_chunk),
        FOURDGS_STATUS_UNSUPPORTED_MODE
    );
    assert!(
        last_error().contains("indexed Chunk range"),
        "{}",
        last_error()
    );

    let oversized_sh = file_with_state_ranges(
        &chunk,
        chunk.len() as u64,
        &[(1, Vec::new(), MAX_INDEXED_STATE_RECORD_BYTES + 1)],
    );
    assert_eq!(
        indexed_state_status(&oversized_sh),
        FOURDGS_STATUS_UNSUPPORTED_MODE
    );
    assert!(
        last_error().contains("indexed SH Band Stream range"),
        "{}",
        last_error()
    );
}

#[test]
fn indexed_c_abi_rejects_misframed_chunk_and_sh_ranges() {
    let chunk = fourdgs::records::encode_chunk(0.0, 1.0, 0, 0, &[]);
    let mut overlong_chunk = chunk.clone();
    overlong_chunk.push(0xaa);
    let bytes = file_with_state_ranges(&overlong_chunk, overlong_chunk.len() as u64, &[]);
    assert_eq!(indexed_state_status(&bytes), FOURDGS_STATUS_MALFORMED);
    assert!(
        last_error().contains("exactly one record"),
        "{}",
        last_error()
    );

    let short_chunk = chunk[..chunk.len() - 1].to_vec();
    let bytes = file_with_state_ranges(&short_chunk, short_chunk.len() as u64, &[]);
    assert_eq!(indexed_state_status(&bytes), FOURDGS_STATUS_MALFORMED);
    assert!(
        last_error().contains("exactly one record"),
        "{}",
        last_error()
    );

    let mut sh_content = vec![1];
    sh_content.extend_from_slice(
        &fourdgs::stream::encode_stream(
            op::SH_BAND_STREAM,
            &[],
            9,
            fourdgs::codec::DEFLATE,
            6,
            false,
        )
        .expect("empty SH stream"),
    );
    let mut overlong_sh = Vec::new();
    put_record(&mut overlong_sh, op::SH_BAND_STREAM, &sh_content);
    overlong_sh.push(0xbb);
    let bytes = file_with_state_ranges(
        &chunk,
        chunk.len() as u64,
        &[(1, overlong_sh.clone(), overlong_sh.len() as u64)],
    );
    assert_eq!(indexed_state_status(&bytes), FOURDGS_STATUS_MALFORMED);
    assert!(
        last_error().contains("exactly one record"),
        "{}",
        last_error()
    );

    let short_sh = overlong_sh[..overlong_sh.len() - 2].to_vec();
    let bytes = file_with_state_ranges(
        &chunk,
        chunk.len() as u64,
        &[(1, short_sh.clone(), short_sh.len() as u64)],
    );
    assert_eq!(indexed_state_status(&bytes), FOURDGS_STATUS_MALFORMED);
    assert!(
        last_error().contains("exactly one record"),
        "{}",
        last_error()
    );
}

#[test]
fn indexed_c_abi_caps_combined_front_matter_collections() {
    let mut bytes = file_naming("gaussian-birth", "uniform-v1");
    let footer_and_magic = Footer::default().encode().len() + MAGIC.len();
    let insert_at = bytes.len() - footer_and_magic;
    let metadata = fourdgs::records::Metadata::default().encode();
    let mut repeated = Vec::with_capacity((MAX_RETAINED_RECORDS - 2) * metadata.len());
    // Header, Quantization and Window Table are already present. The last Metadata record
    // is therefore exactly the first front-matter record past the shared ceiling.
    for _ in 0..(MAX_RETAINED_RECORDS - 2) {
        repeated.extend_from_slice(&metadata);
    }
    bytes.splice(insert_at..insert_at, repeated);

    assert_eq!(
        open_memory_indexed(&bytes),
        FOURDGS_STATUS_UNSUPPORTED_MODE,
        "a legal high-record-count file is incomplete for this bounded reader, not malformed"
    );
    let message = last_error();
    assert!(
        message.contains("indexed front matter reaches record 262145"),
        "{message}"
    );
    assert!(message.contains("at byte "), "{message}");

    assert_eq!(
        open_memory(&bytes),
        FOURDGS_STATUS_UNSUPPORTED_MODE,
        "automatic mode must not bypass the indexed working-set ceiling by falling back"
    );
    assert!(
        last_error().contains("indexed front matter reaches record 262145"),
        "{}",
        last_error()
    );

    assert_eq!(
        open_memory_sequential(&bytes),
        FOURDGS_STATUS_UNSUPPORTED_MODE,
        "the explicit sequential surface applies the same combined record ceiling"
    );
    assert!(
        last_error().contains("streamed record walk reaches record 262145"),
        "{}",
        last_error()
    );
}

#[test]
fn sequential_c_abi_checksums_a_large_summary_without_a_second_copy() {
    let mut bytes = file_naming("gaussian-birth", "uniform-v1");
    let footer_and_magic = Footer::default().encode().len() + MAGIC.len();
    bytes.truncate(bytes.len() - footer_and_magic);
    let summary_start = bytes.len() as u64;

    let mut summary = fourdgs::records::Statistics {
        duration_sec: 1.0,
        aabb: vec![0.0; 6],
        ..Default::default()
    }
    .encode();
    let content_length = fourdgs::indexed_reader::MAX_FRONT_MATTER_BYTES + 1;
    summary[1..RECORD_HEADER_SIZE].copy_from_slice(&content_length.to_le_bytes());
    summary.resize(RECORD_HEADER_SIZE + content_length as usize, 0x5a);
    bytes.extend_from_slice(&summary);
    bytes.extend_from_slice(
        &Footer {
            summary_start,
            ..Default::default()
        }
        .encode(),
    );
    bytes.extend_from_slice(&MAGIC);

    assert_eq!(
        open_memory_sequential(&bytes),
        FOURDGS_STATUS_OK,
        "the incremental checksum does not retain a second summary-sized allocation"
    );
}
