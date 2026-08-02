// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! The C ABI.
//!
//! This is how the C++ and Swift packages are delivered: one stable header
//! (`include/fourdgs.h`), one shared or static library, and a thin shim per language —
//! rather than parallel hand-written implementations that drift.
//!
//! Three rules hold across the whole surface and are what make it safe to bind against.
//!
//! 1. **Nothing unwinds across the boundary.** Every entry point runs its body inside
//!    `catch_unwind`, so a bug in this crate becomes `FOURDGS_STATUS_INTERNAL` rather than
//!    undefined behaviour in the caller's runtime. A panic reaching a binding is a
//!    critical defect and this is the net under it.
//! 2. **Every fallible call returns a `fourdgs_status`.** Pointers come back through out
//!    parameters, and a non-`OK` status always leaves those untouched.
//! 3. **Borrowed pointers live as long as the object they came from**, and are invalidated
//!    by the next call that changes it. The header says which those are, per function.
//!
//! Decoding ends at gaussian state: this surface hands back positions, scales, rotations,
//! colours, motion and the temporal fields, plus the reconstruction at an instant. What
//! draws them is somebody else's library.

#![allow(clippy::missing_safety_doc)]
// The C surface uses C naming so that the header and the symbols read the same.
#![allow(non_camel_case_types)]

use std::cell::RefCell;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::error::Error;
use crate::model::{AudioSource, GaussianSet, StateAt};
use crate::readable::{FileReadable, Readable};
use crate::reader::SceneReader;
use crate::writer::{write_to_vec, SceneExtras, WriteOptions};

// --------------------------------------------------------------------------
// Status codes
// --------------------------------------------------------------------------

pub const FOURDGS_STATUS_OK: c_int = 0;
pub const FOURDGS_STATUS_INVALID_ARGUMENT: c_int = 1;
pub const FOURDGS_STATUS_UNSUPPORTED_VERSION: c_int = 2;
pub const FOURDGS_STATUS_TRUNCATED: c_int = 3;
pub const FOURDGS_STATUS_MALFORMED: c_int = 4;
pub const FOURDGS_STATUS_UNSUPPORTED_CODEC: c_int = 5;
pub const FOURDGS_STATUS_IO: c_int = 6;
pub const FOURDGS_STATUS_OUT_OF_RANGE: c_int = 7;
pub const FOURDGS_STATUS_INTERNAL: c_int = 8;
/// A legal request on the wrong read path. Not a bad file and not a bad argument.
pub const FOURDGS_STATUS_UNSUPPORTED_MODE: c_int = 9;

thread_local! {
    /// The last error message, owned per thread so two threads decoding two files never
    /// overwrite each other's diagnosis.
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

fn set_last_error(message: String) {
    let cleaned = message.replace('\0', " ");
    LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = CString::new(cleaned).ok();
    });
}

fn status_of(error: &Error) -> c_int {
    match error {
        Error::UnsupportedVersion(_) => FOURDGS_STATUS_UNSUPPORTED_VERSION,
        Error::Truncated(_) => FOURDGS_STATUS_TRUNCATED,
        Error::Malformed(_) => FOURDGS_STATUS_MALFORMED,
        Error::UnsupportedCodec(_) => FOURDGS_STATUS_UNSUPPORTED_CODEC,
        // Mapped onto the existing "legal but unimplemented" status rather than given a
        // new one. The status codes are the C ABI's public contract, and every consumer
        // that already handles UNSUPPORTED_CODEC handles this correctly: the file is
        // conforming and this build cannot read it. Which value it is stays in the
        // message, which the registry requires to name it.
        Error::UnsupportedModel(_) => FOURDGS_STATUS_UNSUPPORTED_CODEC,
        Error::BoundViolation(_) => FOURDGS_STATUS_MALFORMED,
        Error::UnsupportedOperation(_) => FOURDGS_STATUS_UNSUPPORTED_MODE,
        // The C ABI exposes no encoder, so this cannot arise through it today; mapped
        // rather than left to a catch-all so that it stays correct when one is added.
        Error::InvalidInput(_) => FOURDGS_STATUS_INVALID_ARGUMENT,
        Error::Io(_) => FOURDGS_STATUS_IO,
        // Deferred to the kind, so naming a refusal did not renumber any status a
        // consumer already switches on.
        Error::Refused { kind, .. } => match kind {
            crate::error::RefusalKind::UnsupportedVersion => FOURDGS_STATUS_UNSUPPORTED_VERSION,
            crate::error::RefusalKind::UnsupportedModel => FOURDGS_STATUS_UNSUPPORTED_CODEC,
            crate::error::RefusalKind::UnsupportedCodec => FOURDGS_STATUS_UNSUPPORTED_CODEC,
            crate::error::RefusalKind::Malformed => FOURDGS_STATUS_MALFORMED,
        },
    }
}

fn report(error: Error) -> c_int {
    let status = status_of(&error);
    set_last_error(error.to_string());
    status
}

/// Run `body` with a panic net. A panic is a defect in this crate, never a legal outcome,
/// so it is reported as `INTERNAL` and never allowed to unwind into the caller.
fn guarded<F: FnOnce() -> c_int>(body: F) -> c_int {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(status) => status,
        Err(_) => {
            set_last_error("a decoder bug panicked; this is a defect, please report it".into());
            FOURDGS_STATUS_INTERNAL
        }
    }
}

/// The last error message on this thread, or an empty string. Valid until the next call on
/// this thread that fails.
#[no_mangle]
pub extern "C" fn fourdgs_last_error() -> *const c_char {
    LAST_ERROR.with(|slot| match &*slot.borrow() {
        Some(message) => message.as_ptr(),
        None => c"".as_ptr(),
    })
}

/// A human name for a status code. Always a valid static string.
#[no_mangle]
pub extern "C" fn fourdgs_status_message(status: c_int) -> *const c_char {
    let text = match status {
        FOURDGS_STATUS_OK => c"ok",
        FOURDGS_STATUS_INVALID_ARGUMENT => c"invalid argument",
        FOURDGS_STATUS_UNSUPPORTED_VERSION => c"unsupported version",
        FOURDGS_STATUS_TRUNCATED => c"truncated file",
        FOURDGS_STATUS_MALFORMED => c"malformed file",
        FOURDGS_STATUS_UNSUPPORTED_CODEC => c"unsupported codec",
        FOURDGS_STATUS_IO => c"io error",
        FOURDGS_STATUS_OUT_OF_RANGE => c"out of range",
        FOURDGS_STATUS_INTERNAL => c"internal error",
        FOURDGS_STATUS_UNSUPPORTED_MODE => c"unsupported on this read path",
        _ => c"unknown status",
    };
    text.as_ptr()
}

/// The format major version this build implements.
#[no_mangle]
pub extern "C" fn fourdgs_format_version() -> u32 {
    crate::serialization::VERSION as u32
}

// --------------------------------------------------------------------------
// Transports
// --------------------------------------------------------------------------

/// A byte-range source supplied by the caller: the one abstraction the core needs.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct fourdgs_reader {
    pub ctx: *mut c_void,
    /// Write the resource's total size to `out_size`; return a status.
    pub size: Option<unsafe extern "C" fn(ctx: *mut c_void, out_size: *mut u64) -> c_int>,
    /// Write exactly `length` bytes at `offset` into `out`; return a status. A short read
    /// reported as success is the one behaviour that breaks every caller.
    pub read: Option<
        unsafe extern "C" fn(ctx: *mut c_void, offset: u64, length: u64, out: *mut u8) -> c_int,
    >,
    /// Called once when the scene is freed. May be null.
    pub release: Option<unsafe extern "C" fn(ctx: *mut c_void)>,
}

struct CallbackSource {
    reader: fourdgs_reader,
}

impl Readable for CallbackSource {
    fn size(&mut self) -> crate::Result<u64> {
        let f = self
            .reader
            .size
            .ok_or_else(|| Error::Malformed("the reader has no size callback".into()))?;
        let mut out = 0u64;
        // SAFETY: `f` and `ctx` come from the caller's own `fourdgs_reader`, and `out`
        // points at a live local. The contract is documented on `fourdgs_reader`.
        let status = unsafe { f(self.reader.ctx, &mut out) };
        if status != FOURDGS_STATUS_OK {
            return Err(Error::Io(std::io::Error::other(format!(
                "the reader's size callback returned status {status}"
            ))));
        }
        Ok(out)
    }

    fn read(&mut self, offset: u64, length: u64) -> crate::Result<Vec<u8>> {
        let f = self
            .reader
            .read
            .ok_or_else(|| Error::Malformed("the reader has no read callback".into()))?;
        let len = usize::try_from(length).map_err(|_| {
            Error::Truncated(format!("length {length} is past this platform's reach"))
        })?;
        let mut out = vec![0u8; len];
        // SAFETY: `out` is a freshly allocated buffer of exactly `len` bytes, which is
        // what the callback is told it may write.
        let status = unsafe { f(self.reader.ctx, offset, length, out.as_mut_ptr()) };
        if status != FOURDGS_STATUS_OK {
            return Err(Error::Io(std::io::Error::other(format!(
                "the reader's read callback returned status {status} for [{offset}, {})",
                offset + length
            ))));
        }
        Ok(out)
    }
}

impl Drop for CallbackSource {
    fn drop(&mut self) {
        if let Some(release) = self.reader.release {
            // SAFETY: called exactly once, when the scene that owns this source is freed.
            unsafe { release(self.reader.ctx) };
        }
    }
}

/// A copy of a whole resource the caller handed over. Owned here so the caller's buffer
/// need not outlive the scene.
struct OwnedBytes {
    data: Vec<u8>,
}

impl Readable for OwnedBytes {
    fn size(&mut self) -> crate::Result<u64> {
        Ok(self.data.len() as u64)
    }

    fn read(&mut self, offset: u64, length: u64) -> crate::Result<Vec<u8>> {
        crate::readable::BytesReadable::new(&self.data).read(offset, length)
    }
}

// --------------------------------------------------------------------------
// Scene
// --------------------------------------------------------------------------

/// An opened scene. Opaque to C.
pub struct fourdgs_scene {
    inner: SceneReader<Box<dyn Readable>>,
    /// Strings handed out as borrowed pointers, kept alive alongside the scene.
    strings: Vec<CString>,
    /// Source descriptors are small and fetched lazily. Keeping them here gives all
    /// pointer-and-length string fields a scene lifetime across the C boundary.
    audio_descriptors: Vec<Option<AudioSource>>,
}

/// Reconstructed state at one instant. Opaque to C.
pub struct fourdgs_state {
    inner: StateAt,
}

fn open_from(source: Box<dyn Readable>, out: *mut *mut fourdgs_scene) -> c_int {
    if out.is_null() {
        set_last_error("the out parameter is null".into());
        return FOURDGS_STATUS_INVALID_ARGUMENT;
    }
    match SceneReader::open(source) {
        Ok(inner) => {
            let audio_descriptors = vec![None; inner.audio_source_count()];
            let scene = Box::new(fourdgs_scene {
                inner,
                strings: Vec::new(),
                audio_descriptors,
            });
            // SAFETY: `out` was checked non-null; the caller owns the result and frees it
            // with `fourdgs_scene_free`.
            unsafe { *out = Box::into_raw(scene) };
            FOURDGS_STATUS_OK
        }
        Err(e) => report(e),
    }
}

/// Open a scene from bytes the caller owns. The bytes are copied, so the caller's buffer
/// may be released immediately.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_open_memory(
    data: *const u8,
    length: usize,
    out: *mut *mut fourdgs_scene,
) -> c_int {
    guarded(|| {
        if data.is_null() && length != 0 {
            set_last_error("a non-empty buffer was passed as null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: the caller states `data` points at `length` readable bytes.
        let copied = if length == 0 {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(data, length) }.to_vec()
        };
        open_from(Box::new(OwnedBytes { data: copied }), out)
    })
}

/// Open a scene from a filesystem path, NUL-terminated and UTF-8.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_open_path(
    path: *const c_char,
    out: *mut *mut fourdgs_scene,
) -> c_int {
    guarded(|| {
        if path.is_null() {
            set_last_error("the path is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: the caller states `path` is a NUL-terminated string.
        let path = match unsafe { CStr::from_ptr(path) }.to_str() {
            Ok(p) => p,
            Err(_) => {
                set_last_error("the path is not valid UTF-8".into());
                return FOURDGS_STATUS_INVALID_ARGUMENT;
            }
        };
        match FileReadable::open(path) {
            Ok(source) => open_from(Box::new(source), out),
            Err(e) => report(e),
        }
    })
}

/// Open a scene over a caller-supplied byte-range source. The scene takes ownership of the
/// reader's `ctx` and calls `release` once, when it is freed.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_open_reader(
    reader: fourdgs_reader,
    out: *mut *mut fourdgs_scene,
) -> c_int {
    guarded(|| {
        if reader.size.is_none() || reader.read.is_none() {
            set_last_error("a reader needs both a size and a read callback".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        open_from(Box::new(CallbackSource { reader }), out)
    })
}

/// Release a scene and everything borrowed from it. Null is accepted and ignored.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_free(scene: *mut fourdgs_scene) {
    if scene.is_null() {
        return;
    }
    // SAFETY: `scene` came from `Box::into_raw` in one of the open functions and is freed
    // exactly once. A double free is the caller's contract to avoid.
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        drop(Box::from_raw(scene));
    }));
}

/// Borrow a scene, or report a null argument.
macro_rules! scene_ref {
    ($scene:expr) => {
        match unsafe { $scene.as_ref() } {
            Some(s) => s,
            None => {
                set_last_error("the scene pointer is null".into());
                return FOURDGS_STATUS_INVALID_ARGUMENT;
            }
        }
    };
}

/// The same, for the accessors that return a value rather than a status.
macro_rules! scene_or {
    ($scene:expr, $fallback:expr) => {
        match unsafe { $scene.as_ref() } {
            Some(s) => s,
            None => return $fallback,
        }
    };
}

// --------------------------------------------------------------------------
// Header
// --------------------------------------------------------------------------

/// Scene length in seconds; playback covers `[0, duration)`.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_duration_sec(scene: *const fourdgs_scene) -> f64 {
    scene_or!(scene, 0.0).inner.header().duration_sec
}

/// The Header's marginal visibility threshold. Not decoration: it sets the support
/// constant the per-gaussian velocity grid is derived from.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_cutoff(scene: *const fourdgs_scene) -> f64 {
    scene_or!(scene, crate::quantization::DEFAULT_CUTOFF)
        .inner
        .header()
        .cutoff
}

/// Total gaussians the Header declares, across all chunks.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_gaussian_count(scene: *const fourdgs_scene) -> u64 {
    scene_or!(scene, 0).inner.header().gaussian_count
}

/// Spherical harmonic degree, 0 to 3. 0 means the scene carries none.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_sh_degree(scene: *const fourdgs_scene) -> u8 {
    scene_or!(scene, 0).inner.header().sh_degree
}

/// 1 when the file was opened on the indexed path, 0 when it is read front to back.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_is_indexed(scene: *const fourdgs_scene) -> c_int {
    c_int::from(scene_or!(scene, 0).inner.mode() == crate::reader::Mode::Indexed)
}

/// Chunk index entries. 0 for a file with no index.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_chunk_count(scene: *const fourdgs_scene) -> u32 {
    scene_or!(scene, 0).inner.chunk_index().len() as u32
}

/// The interval of chunk `i`, both out parameters optional.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_chunk_interval(
    scene: *const fourdgs_scene,
    i: u32,
    out_t0: *mut f64,
    out_t1: *mut f64,
) -> c_int {
    guarded(|| {
        let scene = scene_ref!(scene);
        let index = scene.inner.chunk_index();
        let Some(entry) = index.get(i as usize) else {
            set_last_error(format!(
                "chunk {i} is outside the {}-entry index",
                index.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        };
        // SAFETY: both pointers are checked for null and written at most once.
        unsafe {
            if let Some(slot) = out_t0.as_mut() {
                *slot = entry.t0;
            }
            if let Some(slot) = out_t1.as_mut() {
                *slot = entry.t1;
            }
        }
        FOURDGS_STATUS_OK
    })
}

/// A conservative upper bound on a cold seek to `t` with SH capped at `max_sh_band`.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_bytes_for_time(
    scene: *const fourdgs_scene,
    t: f64,
    max_sh_band: u8,
) -> u64 {
    let scene = scene_or!(scene, 0);
    scene.inner.bytes_for_time(t, max_sh_band)
}

// --------------------------------------------------------------------------
// Audio
// --------------------------------------------------------------------------

#[repr(C)]
#[derive(Clone, Copy)]
pub struct fourdgs_audio_source {
    pub source_id: u32,
    pub name: *const c_char,
    pub name_length: usize,
    pub codec: *const c_char,
    pub codec_length: usize,
    pub channel_layout: *const c_char,
    pub channel_layout_length: usize,
    pub start_sec: f64,
    pub duration_sec: f64,
    pub gain: f64,
    pub spatial: c_int,
    pub loop_playback: c_int,
    pub position: [f64; 3],
    pub rotation: [f64; 4],
    pub keyframe_count: u32,
    pub interpolation: *const c_char,
    pub interpolation_length: usize,
    pub data_size: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct fourdgs_audio_source_keyframe {
    pub time: f64,
    pub position: [f64; 3],
    pub rotation: [f64; 4],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct fourdgs_audio_source_state {
    pub active: c_int,
    pub local_time: f64,
    pub position: [f64; 3],
    pub rotation: [f64; 4],
    pub gain: f64,
}

fn cache_audio_descriptor(scene: &mut fourdgs_scene, index: usize) -> crate::Result<()> {
    if scene.audio_descriptors.get(index).is_none() {
        return Err(Error::Malformed(format!(
            "audio source index {index} is outside the {}-source scene",
            scene.audio_descriptors.len()
        )));
    }
    if scene.audio_descriptors[index].is_none() {
        let descriptor = scene.inner.audio_source(index)?.ok_or_else(|| {
            Error::Malformed(format!(
                "audio source index {index} disappeared after the scene was opened"
            ))
        })?;
        scene.audio_descriptors[index] = Some(descriptor);
    }
    Ok(())
}

/// Whether the scene has audio sources, answered from the Header alone — no probing and
/// no speculative range request. Absence is a normal value, never an error.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_has_audio(scene: *const fourdgs_scene) -> c_int {
    c_int::from(scene_or!(scene, 0).inner.has_audio())
}

/// Number of independently timed audio sources.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_audio_source_count(scene: *const fourdgs_scene) -> u32 {
    scene_or!(scene, 0).inner.audio_source_count() as u32
}

/// Fetch one small source descriptor. Encoded audio bytes are not transferred.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_audio_source(
    scene: *mut fourdgs_scene,
    index: u32,
    out: *mut fourdgs_audio_source,
) -> c_int {
    guarded(|| {
        let Some(scene) = (unsafe { scene.as_mut() }) else {
            set_last_error("the scene pointer is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        let Some(out) = (unsafe { out.as_mut() }) else {
            set_last_error("the audio source out parameter is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        let index = index as usize;
        if index >= scene.audio_descriptors.len() {
            set_last_error(format!(
                "audio source index {index} is outside the {}-source scene",
                scene.audio_descriptors.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        }
        if let Err(error) = cache_audio_descriptor(scene, index) {
            return report(error);
        }
        let source = scene.audio_descriptors[index]
            .as_ref()
            .expect("cached above");
        *out = fourdgs_audio_source {
            source_id: source.source_id,
            name: source.name.as_ptr().cast(),
            name_length: source.name.len(),
            codec: source.codec.as_ptr().cast(),
            codec_length: source.codec.len(),
            channel_layout: source.channel_layout.as_ptr().cast(),
            channel_layout_length: source.channel_layout.len(),
            start_sec: source.start_sec,
            duration_sec: source.duration_sec,
            gain: source.gain,
            spatial: c_int::from(source.spatial),
            loop_playback: c_int::from(source.loop_),
            position: source.position,
            rotation: source.rotation,
            keyframe_count: source.keyframes.len() as u32,
            interpolation: source.interpolation.as_ptr().cast(),
            interpolation_length: source.interpolation.len(),
            data_size: scene.inner.audio_source_len(index).unwrap_or(0),
        };
        FOURDGS_STATUS_OK
    })
}

/// One moving-source pose keyframe.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_audio_source_keyframe(
    scene: *mut fourdgs_scene,
    source_index: u32,
    keyframe_index: u32,
    out: *mut fourdgs_audio_source_keyframe,
) -> c_int {
    guarded(|| {
        let Some(scene) = (unsafe { scene.as_mut() }) else {
            set_last_error("the scene pointer is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        let Some(out) = (unsafe { out.as_mut() }) else {
            set_last_error("the audio keyframe out parameter is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        let source_index = source_index as usize;
        if source_index >= scene.audio_descriptors.len() {
            set_last_error(format!(
                "audio source index {source_index} is outside the {}-source scene",
                scene.audio_descriptors.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        }
        if let Err(error) = cache_audio_descriptor(scene, source_index) {
            return report(error);
        }
        let source = scene.audio_descriptors[source_index]
            .as_ref()
            .expect("cached above");
        let Some(keyframe) = source.keyframes.get(keyframe_index as usize) else {
            set_last_error(format!(
                "audio source {} keyframe {keyframe_index} is outside its {} keyframes",
                source.source_id,
                source.keyframes.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        };
        *out = fourdgs_audio_source_keyframe {
            time: keyframe.time,
            position: keyframe.position,
            rotation: keyframe.rotation,
        };
        FOURDGS_STATUS_OK
    })
}

/// Reconstruct one source's timing and scene-space pose at scene time `t`.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_audio_source_state_at(
    scene: *mut fourdgs_scene,
    source_index: u32,
    t: f64,
    out: *mut fourdgs_audio_source_state,
) -> c_int {
    guarded(|| {
        let Some(scene) = (unsafe { scene.as_mut() }) else {
            set_last_error("the scene pointer is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        let Some(out) = (unsafe { out.as_mut() }) else {
            set_last_error("the audio source state out parameter is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        let source_index = source_index as usize;
        if source_index >= scene.audio_descriptors.len() {
            set_last_error(format!(
                "audio source index {source_index} is outside the {}-source scene",
                scene.audio_descriptors.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        }
        if let Err(error) = cache_audio_descriptor(scene, source_index) {
            return report(error);
        }
        let state = scene.audio_descriptors[source_index]
            .as_ref()
            .expect("cached above")
            .state_at(t);
        *out = fourdgs_audio_source_state {
            active: c_int::from(state.active),
            local_time: state.local_time,
            position: state.position,
            rotation: state.rotation,
            gain: state.gain,
        };
        FOURDGS_STATUS_OK
    })
}

/// Copy one source payload range. The caller selects by stable descriptor ordinal.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_audio_source_read(
    scene: *mut fourdgs_scene,
    index: u32,
    offset: u64,
    length: u64,
    out: *mut u8,
) -> c_int {
    guarded(|| {
        let Some(scene) = (unsafe { scene.as_mut() }) else {
            set_last_error("the scene pointer is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        if out.is_null() && length != 0 {
            set_last_error("the output buffer is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        let index = index as usize;
        if index >= scene.audio_descriptors.len() {
            set_last_error(format!(
                "audio source index {index} is outside the {}-source scene",
                scene.audio_descriptors.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        }
        if let Err(error) = cache_audio_descriptor(scene, index) {
            return report(error);
        }
        let source_id = scene.audio_descriptors[index]
            .as_ref()
            .expect("cached above")
            .source_id;
        match scene
            .inner
            .read_audio_source_range(source_id, offset, length)
        {
            Ok(bytes) => {
                if !bytes.is_empty() {
                    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len()) };
                }
                FOURDGS_STATUS_OK
            }
            Err(error) => report(error),
        }
    })
}

/// The first source's codec, retained for ABI compatibility. Borrowed until scene free.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_audio_codec(scene: *mut fourdgs_scene) -> *const c_char {
    // SAFETY: null is handled; otherwise the caller guarantees a live scene.
    let Some(scene) = (unsafe { scene.as_mut() }) else {
        return std::ptr::null();
    };
    if scene.audio_descriptors.is_empty() || cache_audio_descriptor(scene, 0).is_err() {
        return std::ptr::null();
    }
    let codec = &scene.audio_descriptors[0]
        .as_ref()
        .expect("cached above")
        .codec;
    let Ok(owned) = CString::new(codec.as_str()) else {
        return std::ptr::null();
    };
    scene.strings.push(owned);
    scene.strings.last().expect("just pushed").as_ptr()
}

/// The first source's payload length, retained for ABI compatibility.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_audio_size(scene: *const fourdgs_scene) -> u64 {
    scene_or!(scene, 0).inner.audio_len().unwrap_or(0)
}

/// Read the first source payload, retained for ABI compatibility.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_audio_read(
    scene: *mut fourdgs_scene,
    offset: u64,
    length: u64,
    out: *mut u8,
) -> c_int {
    guarded(|| {
        let Some(scene) = (unsafe { scene.as_mut() }) else {
            set_last_error("the scene pointer is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        if out.is_null() && length != 0 {
            set_last_error("the output buffer is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        match scene.inner.read_audio_range(offset, length) {
            Ok(bytes) => {
                // SAFETY: the caller states `out` has room for `length` bytes, and
                // `read_audio_range` returned exactly that many.
                if !bytes.is_empty() {
                    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len()) };
                }
                FOURDGS_STATUS_OK
            }
            Err(e) => report(e),
        }
    })
}

// --------------------------------------------------------------------------
// Gaussians
// --------------------------------------------------------------------------

/// Decode every chunk into the scene's working set.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_load_all(
    scene: *mut fourdgs_scene,
    max_sh_band: u8,
) -> c_int {
    guarded(|| {
        let Some(scene) = (unsafe { scene.as_mut() }) else {
            set_last_error("the scene pointer is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        match scene.inner.load_all(max_sh_band) {
            Ok(_) => FOURDGS_STATUS_OK,
            Err(e) => report(e),
        }
    })
}

/// Decode only the chunks the seek rule names for `t` into the scene's working set.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_load_at(
    scene: *mut fourdgs_scene,
    t: f64,
    max_sh_band: u8,
) -> c_int {
    guarded(|| {
        let Some(scene) = (unsafe { scene.as_mut() }) else {
            set_last_error("the scene pointer is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        match scene.inner.load_at(t, max_sh_band) {
            Ok(_) => FOURDGS_STATUS_OK,
            Err(e) => report(e),
        }
    })
}

/// How many gaussians are currently resident. Every array accessor below is sized from
/// this.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_loaded_count(scene: *const fourdgs_scene) -> u32 {
    scene_or!(scene, 0).inner.loaded().count() as u32
}

macro_rules! array_accessor {
    ($name:ident, $field:ident, $doc:literal) => {
        #[doc = $doc]
        #[no_mangle]
        pub unsafe extern "C" fn $name(scene: *const fourdgs_scene) -> *const f32 {
            let scene = scene_or!(scene, std::ptr::null());
            let slice = &scene.inner.loaded().$field;
            if slice.is_empty() {
                std::ptr::null()
            } else {
                slice.as_ptr()
            }
        }
    };
}

array_accessor!(
    fourdgs_scene_positions,
    positions,
    "Rest positions, 3 floats per resident gaussian. Borrowed until the next load."
);
array_accessor!(
    fourdgs_scene_scales,
    scales,
    "Linear scales, 3 floats per resident gaussian. Borrowed until the next load."
);
array_accessor!(
    fourdgs_scene_rotations,
    rotations,
    "Unit quaternions, xyzw, 4 floats per resident gaussian. Borrowed until the next load."
);
array_accessor!(
    fourdgs_scene_colors,
    colors,
    "Linear RGB and opacity in [0, 1], 4 floats per resident gaussian. Borrowed until the next load."
);
array_accessor!(
    fourdgs_scene_motions,
    motions,
    "Linear velocity in units per second, 3 floats per resident gaussian. Borrowed until the next load."
);
array_accessor!(
    fourdgs_scene_mu_t,
    mu_t,
    "Temporal centre in seconds, 1 float per resident gaussian. Borrowed until the next load."
);
array_accessor!(
    fourdgs_scene_sigma_t,
    sigma_t,
    "Temporal standard deviation in seconds, 1 float per resident gaussian. Positive infinity means the gaussian never fades — a value, not a sentinel. Borrowed until the next load."
);
array_accessor!(
    fourdgs_scene_win_lo,
    win_lo,
    "Validity window start in seconds, 1 float per resident gaussian. Borrowed until the next load."
);
array_accessor!(
    fourdgs_scene_win_hi,
    win_hi,
    "Validity window end in seconds, 1 float per resident gaussian. Borrowed until the next load."
);

/// Object membership, 1 unsigned integer per resident gaussian, or null when the scene
/// carries no `object_id` stream (spec §6.6).
///
/// Null and all-zero are different claims and both are legal: a file with no membership at
/// all, and a file where every gaussian is background. A binding that substituted zeros for
/// null would report the second when it read the first. Borrowed until the next load.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_object_ids(scene: *const fourdgs_scene) -> *const u32 {
    let scene = scene_or!(scene, std::ptr::null());
    match scene.inner.loaded().object_id.as_ref() {
        Some(ids) if !ids.is_empty() => ids.as_ptr(),
        _ => std::ptr::null(),
    }
}

/// Spherical harmonic coefficients, `3 * fourdgs_scene_sh_coefficients()` bytes per
/// resident gaussian, component-major: every coefficient of red, then green, then blue.
///
/// Stored as written and consumed as read — `step_sh` describes what the encoder did and is
/// not applied at decode. Null when the scene carries none.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_sh(scene: *const fourdgs_scene) -> *const u8 {
    let scene = scene_or!(scene, std::ptr::null());
    match &scene.inner.loaded().sh {
        Some(sh) if !sh.is_empty() => sh.as_ptr(),
        _ => std::ptr::null(),
    }
}

/// Coefficients per colour component in the resident set, so an `sh` row is three times
/// this wide. 0 when the scene carries none.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_sh_coefficients(scene: *const fourdgs_scene) -> u32 {
    scene_or!(scene, 0).inner.loaded().sh_coefficients as u32
}

// --------------------------------------------------------------------------
// State at an instant
// --------------------------------------------------------------------------

/// Reconstruct the state at scene time `t`, loading the chunks that instant needs.
///
/// This is where decoding ends. The result borrows nothing from the scene and must be
/// freed with `fourdgs_state_free`; its indices refer to the scene's resident arrays,
/// which this call has just populated.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_state_at(
    scene: *mut fourdgs_scene,
    t: f64,
    max_sh_band: u8,
    out: *mut *mut fourdgs_state,
) -> c_int {
    guarded(|| {
        let Some(scene) = (unsafe { scene.as_mut() }) else {
            set_last_error("the scene pointer is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        if out.is_null() {
            set_last_error("the out parameter is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        match scene.inner.state_at(t, max_sh_band) {
            Ok(state) => {
                let boxed = Box::new(fourdgs_state { inner: state });
                // SAFETY: `out` was checked non-null; the caller frees the result.
                unsafe { *out = Box::into_raw(boxed) };
                FOURDGS_STATUS_OK
            }
            Err(e) => report(e),
        }
    })
}

/// Release a state. Null is accepted and ignored.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_state_free(state: *mut fourdgs_state) {
    if state.is_null() {
        return;
    }
    // SAFETY: `state` came from `Box::into_raw` in `fourdgs_scene_state_at`.
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        drop(Box::from_raw(state));
    }));
}

/// How many gaussians exist at that instant.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_state_count(state: *const fourdgs_state) -> u32 {
    // SAFETY: null is handled; otherwise the caller guarantees a live state.
    match unsafe { state.as_ref() } {
        Some(s) => s.inner.count() as u32,
        None => 0,
    }
}

/// Indices into the scene's resident arrays, one per visible gaussian.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_state_indices(state: *const fourdgs_state) -> *const u32 {
    // SAFETY: null is handled; otherwise the caller guarantees a live state.
    match unsafe { state.as_ref() } {
        Some(s) if !s.inner.indices.is_empty() => s.inner.indices.as_ptr(),
        _ => std::ptr::null(),
    }
}

/// `position + motion * (t - mu_t)`, 3 floats per visible gaussian.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_state_centers(state: *const fourdgs_state) -> *const f32 {
    // SAFETY: null is handled; otherwise the caller guarantees a live state.
    match unsafe { state.as_ref() } {
        Some(s) if !s.inner.centers.is_empty() => s.inner.centers.as_ptr(),
        _ => std::ptr::null(),
    }
}

/// Reconstructed orientation, 4 xyzw floats per visible gaussian.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_state_orientations(state: *const fourdgs_state) -> *const f32 {
    // SAFETY: null is handled; otherwise the caller guarantees a live state.
    match unsafe { state.as_ref() } {
        Some(s) if !s.inner.orientations.is_empty() => s.inner.orientations.as_ptr(),
        _ => std::ptr::null(),
    }
}

/// `color.a * marginal`, 1 float per visible gaussian.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_state_opacity(state: *const fourdgs_state) -> *const f32 {
    // SAFETY: null is handled; otherwise the caller guarantees a live state.
    match unsafe { state.as_ref() } {
        Some(s) if !s.inner.opacity.is_empty() => s.inner.opacity.as_ptr(),
        _ => std::ptr::null(),
    }
}

// --------------------------------------------------------------------------
// Read-path selection
// --------------------------------------------------------------------------

/// Auto-select: the index when the file has one, front to back otherwise.
pub const FOURDGS_OPEN_AUTO: c_int = 0;
/// Front to back, whatever the file carries.
pub const FOURDGS_OPEN_SEQUENTIAL: c_int = 1;
/// The indexed path. A file with no index still opens with an empty index.
pub const FOURDGS_OPEN_INDEXED: c_int = 2;

fn open_mode(mode: c_int) -> Option<crate::reader::OpenMode> {
    match mode {
        FOURDGS_OPEN_AUTO => Some(crate::reader::OpenMode::Auto),
        FOURDGS_OPEN_SEQUENTIAL => Some(crate::reader::OpenMode::Sequential),
        FOURDGS_OPEN_INDEXED => Some(crate::reader::OpenMode::Indexed),
        _ => None,
    }
}

fn open_from_with(source: Box<dyn Readable>, mode: c_int, out: *mut *mut fourdgs_scene) -> c_int {
    if out.is_null() {
        set_last_error("the out parameter is null".into());
        return FOURDGS_STATUS_INVALID_ARGUMENT;
    }
    let Some(mode) = open_mode(mode) else {
        set_last_error(format!("{mode} is not a fourdgs_open_mode"));
        return FOURDGS_STATUS_INVALID_ARGUMENT;
    };
    match SceneReader::open_with(source, mode) {
        Ok(inner) => {
            let audio_descriptors = vec![None; inner.audio_source_count()];
            let scene = Box::new(fourdgs_scene {
                inner,
                strings: Vec::new(),
                audio_descriptors,
            });
            // SAFETY: `out` was checked non-null; the caller frees the result.
            unsafe { *out = Box::into_raw(scene) };
            FOURDGS_STATUS_OK
        }
        Err(e) => report(e),
    }
}

/// Open from bytes on a chosen read path. The bytes are copied.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_open_memory_ex(
    data: *const u8,
    length: usize,
    mode: c_int,
    out: *mut *mut fourdgs_scene,
) -> c_int {
    guarded(|| {
        if data.is_null() && length != 0 {
            set_last_error("a non-empty buffer was passed as null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: the caller states `data` points at `length` readable bytes.
        let copied = if length == 0 {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(data, length) }.to_vec()
        };
        open_from_with(Box::new(OwnedBytes { data: copied }), mode, out)
    })
}

/// Open from a path on a chosen read path.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_open_path_ex(
    path: *const c_char,
    mode: c_int,
    out: *mut *mut fourdgs_scene,
) -> c_int {
    guarded(|| {
        if path.is_null() {
            set_last_error("the path is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: the caller states `path` is a NUL-terminated string.
        let path = match unsafe { CStr::from_ptr(path) }.to_str() {
            Ok(p) => p,
            Err(_) => {
                set_last_error("the path is not valid UTF-8".into());
                return FOURDGS_STATUS_INVALID_ARGUMENT;
            }
        };
        match FileReadable::open(path) {
            Ok(source) => open_from_with(Box::new(source), mode, out),
            Err(e) => report(e),
        }
    })
}

/// Open over a caller-supplied source on a chosen read path. Ownership of `reader.ctx`
/// transfers exactly as it does for `fourdgs_open_reader`.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_open_reader_ex(
    reader: fourdgs_reader,
    mode: c_int,
    out: *mut *mut fourdgs_scene,
) -> c_int {
    guarded(|| {
        if reader.size.is_none() || reader.read.is_none() {
            set_last_error("a reader needs both a size and a read callback".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        open_from_with(Box::new(CallbackSource { reader }), mode, out)
    })
}

// --------------------------------------------------------------------------
// The rest of the file, so a binding can state what it read
// --------------------------------------------------------------------------

/// Hand a borrowed string across as pointer and length.
///
/// Never NUL-terminated: the format's `string` is length-prefixed and may legally contain
/// a NUL, and a C-string accessor would silently truncate there. Everything read out of
/// file bytes crosses this way.
fn put_str(text: &str, out: *mut *const c_char, out_len: *mut usize) -> c_int {
    if out.is_null() || out_len.is_null() {
        set_last_error("a string out parameter is null".into());
        return FOURDGS_STATUS_INVALID_ARGUMENT;
    }
    // SAFETY: both pointers were checked non-null; the bytes belong to the scene and
    // outlive the call as documented on each accessor.
    unsafe {
        *out = text.as_ptr() as *const c_char;
        *out_len = text.len();
    }
    FOURDGS_STATUS_OK
}

/// `temporal_model`: `"gaussian-birth"` for version 1. Borrowed until the scene is freed.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_temporal_model(
    scene: *const fourdgs_scene,
    out: *mut *const c_char,
    out_len: *mut usize,
) -> c_int {
    guarded(|| {
        let scene = scene_ref!(scene);
        put_str(&scene.inner.header().temporal_model, out, out_len)
    })
}

/// The Header's `profile`: a promise about what the file contains, or empty for none.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_profile(
    scene: *const fourdgs_scene,
    out: *mut *const c_char,
    out_len: *mut usize,
) -> c_int {
    guarded(|| {
        let scene = scene_ref!(scene);
        put_str(&scene.inner.header().profile, out, out_len)
    })
}

/// The Header's `library`: free-form producer identification.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_library(
    scene: *const fourdgs_scene,
    out: *mut *const c_char,
    out_len: *mut usize,
) -> c_int {
    guarded(|| {
        let scene = scene_ref!(scene);
        put_str(&scene.inner.header().library, out, out_len)
    })
}

/// How many key/value pairs the Header's attributes map carries.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_attribute_count(scene: *const fourdgs_scene) -> u32 {
    scene_or!(scene, 0).inner.header().attributes.len() as u32
}

/// Attribute `i`, in sorted key order. Borrowed until the scene is freed.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_attribute_at(
    scene: *const fourdgs_scene,
    i: u32,
    out_key: *mut *const c_char,
    out_key_len: *mut usize,
    out_value: *mut *const c_char,
    out_value_len: *mut usize,
) -> c_int {
    guarded(|| {
        let scene = scene_ref!(scene);
        let map = &scene.inner.header().attributes;
        let Some((key, value)) = map.iter().nth(i as usize) else {
            set_last_error(format!(
                "attribute {i} is outside the {}-entry map",
                map.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        };
        let status = put_str(key, out_key, out_key_len);
        if status != FOURDGS_STATUS_OK {
            return status;
        }
        put_str(value, out_value, out_value_len)
    })
}

// --- Records behind byte ranges -------------------------------------------

/// Fetch the Camera, Metadata and Attachment records.
///
/// Opening a file frames these and stops, so a camera nobody asked for costs nothing. This
/// is where a caller says it wants them; every accessor below calls it implicitly, and
/// calling it explicitly is how a caller finds out whether they are readable at all.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_load_records(scene: *mut fourdgs_scene) -> c_int {
    guarded(|| {
        let Some(scene) = (unsafe { scene.as_mut() }) else {
            set_last_error("the scene pointer is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        match scene.inner.ensure_records() {
            Ok(()) => FOURDGS_STATUS_OK,
            Err(e) => report(e),
        }
    })
}

/// Borrow a scene mutably and make sure its records are resident.
macro_rules! scene_records {
    ($scene:expr) => {{
        let Some(scene) = (unsafe { $scene.as_mut() }) else {
            set_last_error("the scene pointer is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        if let Err(e) = scene.inner.ensure_records() {
            return report(e);
        }
        scene
    }};
}

/// How many Metadata records the file carries. Known from the ranges at open: no fetch.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_metadata_count(scene: *const fourdgs_scene) -> u32 {
    scene_or!(scene, 0).inner.metadata_count() as u32
}

/// The name of Metadata record `i`. Fetches the records on first use.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_metadata_name(
    scene: *mut fourdgs_scene,
    i: u32,
    out: *mut *const c_char,
    out_len: *mut usize,
) -> c_int {
    guarded(|| {
        let scene = scene_records!(scene);
        let (_, metadata, _) = scene.inner.records().expect("records are resident");
        let Some(record) = metadata.get(i as usize) else {
            set_last_error(format!(
                "metadata record {i} is outside the {} the file carries",
                metadata.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        };
        put_str(&record.name, out, out_len)
    })
}

/// How many entries Metadata record `i` carries, or 0 when `i` is out of range.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_metadata_entry_count(
    scene: *mut fourdgs_scene,
    i: u32,
) -> u32 {
    // SAFETY: null is handled; otherwise the caller guarantees a live scene.
    let Some(scene) = (unsafe { scene.as_mut() }) else {
        return 0;
    };
    if scene.inner.ensure_records().is_err() {
        return 0;
    }
    scene
        .inner
        .records()
        .and_then(|(_, metadata, _)| metadata.get(i as usize))
        .map_or(0, |record| record.entries.len() as u32)
}

/// Entry `j` of Metadata record `i`, in sorted key order.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_metadata_entry_at(
    scene: *mut fourdgs_scene,
    i: u32,
    j: u32,
    out_key: *mut *const c_char,
    out_key_len: *mut usize,
    out_value: *mut *const c_char,
    out_value_len: *mut usize,
) -> c_int {
    guarded(|| {
        let scene = scene_records!(scene);
        let (_, metadata, _) = scene.inner.records().expect("records are resident");
        let Some(record) = metadata.get(i as usize) else {
            set_last_error(format!(
                "metadata record {i} is outside the {} the file carries",
                metadata.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        };
        let Some((key, value)) = record.entries.iter().nth(j as usize) else {
            set_last_error(format!(
                "entry {j} is outside the {}-entry record",
                record.entries.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        };
        let status = put_str(key, out_key, out_key_len);
        if status != FOURDGS_STATUS_OK {
            return status;
        }
        put_str(value, out_value, out_value_len)
    })
}

/// How many Attachment records the file carries. Known from the ranges at open: no fetch.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_attachment_count(scene: *const fourdgs_scene) -> u32 {
    scene_or!(scene, 0).inner.attachment_count() as u32
}

/// The name of attachment `i`.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_attachment_name(
    scene: *mut fourdgs_scene,
    i: u32,
    out: *mut *const c_char,
    out_len: *mut usize,
) -> c_int {
    guarded(|| {
        let scene = scene_records!(scene);
        let (_, _, attachments) = scene.inner.records().expect("records are resident");
        let Some(record) = attachments.get(i as usize) else {
            set_last_error(format!(
                "attachment {i} is outside the {} the file carries",
                attachments.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        };
        put_str(&record.name, out, out_len)
    })
}

/// The media type of attachment `i`.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_attachment_media_type(
    scene: *mut fourdgs_scene,
    i: u32,
    out: *mut *const c_char,
    out_len: *mut usize,
) -> c_int {
    guarded(|| {
        let scene = scene_records!(scene);
        let (_, _, attachments) = scene.inner.records().expect("records are resident");
        let Some(record) = attachments.get(i as usize) else {
            set_last_error(format!(
                "attachment {i} is outside the {} the file carries",
                attachments.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        };
        put_str(&record.media_type, out, out_len)
    })
}

/// The payload length of attachment `i`, or 0 when `i` is out of range.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_attachment_size(scene: *mut fourdgs_scene, i: u32) -> u64 {
    // SAFETY: null is handled; otherwise the caller guarantees a live scene.
    let Some(scene) = (unsafe { scene.as_mut() }) else {
        return 0;
    };
    if scene.inner.ensure_records().is_err() {
        return 0;
    }
    scene
        .inner
        .records()
        .and_then(|(_, _, attachments)| attachments.get(i as usize))
        .map_or(0, |record| record.data.len() as u64)
}

/// Copy `length` bytes of attachment `i` from `offset` into `out`.
///
/// The bytes, not just their length: a summary that checksums an attachment is what stops a
/// decoder passing while discarding the payload.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_attachment_read(
    scene: *mut fourdgs_scene,
    i: u32,
    offset: u64,
    length: u64,
    out: *mut u8,
) -> c_int {
    guarded(|| {
        let scene = scene_records!(scene);
        if out.is_null() && length != 0 {
            set_last_error("the output buffer is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        let (_, _, attachments) = scene.inner.records().expect("records are resident");
        let Some(record) = attachments.get(i as usize) else {
            set_last_error(format!(
                "attachment {i} is outside the {} the file carries",
                attachments.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        };
        let start = usize::try_from(offset).unwrap_or(usize::MAX);
        let want = usize::try_from(length).unwrap_or(usize::MAX);
        let end = start.saturating_add(want);
        if end > record.data.len() {
            set_last_error(format!(
                "attachment range [{start}, {end}) is outside the {}-byte payload",
                record.data.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        }
        // SAFETY: the caller states `out` has room for `length` bytes, and the range was
        // just checked against the payload.
        if want != 0 {
            unsafe { std::ptr::copy_nonoverlapping(record.data[start..end].as_ptr(), out, want) };
        }
        FOURDGS_STATUS_OK
    })
}

// --- Camera ---------------------------------------------------------------

/// A default viewpoint and optional suggested path. Purely advisory: a reader may ignore it.
#[repr(C)]
pub struct fourdgs_camera {
    pub fov_y_deg: f64,
    pub position: [f64; 3],
    pub target: [f64; 3],
    pub keyframe_count: u32,
    /// 0 or 1.
    pub loop_enabled: c_int,
    /// Registry name: `"linear"` or `"spline"`. Borrowed, not NUL-terminated.
    pub interpolation: *const c_char,
    pub interpolation_length: usize,
}

/// Whether the file carries a Camera record. Known from the ranges at open: no fetch.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_has_camera(scene: *const fourdgs_scene) -> c_int {
    c_int::from(scene_or!(scene, 0).inner.has_camera())
}

/// The camera's own fields. `FOURDGS_STATUS_OUT_OF_RANGE` when the file carries none.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_camera(
    scene: *mut fourdgs_scene,
    out: *mut fourdgs_camera,
) -> c_int {
    guarded(|| {
        let scene = scene_records!(scene);
        if out.is_null() {
            set_last_error("the out parameter is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        let (camera, _, _) = scene.inner.records().expect("records are resident");
        let Some(camera) = camera else {
            set_last_error("this scene carries no camera trajectory".into());
            return FOURDGS_STATUS_OUT_OF_RANGE;
        };
        // SAFETY: `out` was checked non-null and is written exactly once.
        unsafe {
            *out = fourdgs_camera {
                fov_y_deg: camera.fov_y_deg,
                position: camera.position,
                target: camera.target,
                keyframe_count: camera.times.len() as u32,
                loop_enabled: c_int::from(camera.loop_),
                interpolation: camera.interpolation.as_ptr() as *const c_char,
                interpolation_length: camera.interpolation.len(),
            };
        }
        FOURDGS_STATUS_OK
    })
}

/// Keyframe `i` of the suggested path. Any out parameter may be null.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_camera_keyframe(
    scene: *mut fourdgs_scene,
    i: u32,
    out_time: *mut f64,
    out_position: *mut f64,
    out_target: *mut f64,
) -> c_int {
    guarded(|| {
        let scene = scene_records!(scene);
        let (camera, _, _) = scene.inner.records().expect("records are resident");
        let Some(camera) = camera else {
            set_last_error("this scene carries no camera trajectory".into());
            return FOURDGS_STATUS_OUT_OF_RANGE;
        };
        let Some(time) = camera.times.get(i as usize) else {
            set_last_error(format!(
                "keyframe {i} is outside the {} this trajectory carries",
                camera.times.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        };
        // SAFETY: each pointer is checked for null; `out_position` and `out_target` are
        // documented as having room for three doubles each.
        unsafe {
            if let Some(slot) = out_time.as_mut() {
                *slot = *time;
            }
            if !out_position.is_null() {
                std::ptr::copy_nonoverlapping(
                    camera.positions[i as usize].as_ptr(),
                    out_position,
                    3,
                );
            }
            if !out_target.is_null() {
                std::ptr::copy_nonoverlapping(camera.targets[i as usize].as_ptr(), out_target, 3);
            }
        }
        FOURDGS_STATUS_OK
    })
}

// --- Statistics, summary offsets, and the two states a reader can be in ----

/// Whether the file carries a Statistics record.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_has_statistics(scene: *const fourdgs_scene) -> c_int {
    c_int::from(scene_or!(scene, 0).inner.statistics().is_some())
}

/// The Statistics record's fields. Advisory: a reader that needs certainty computes from
/// the chunks. Any out parameter may be null.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_statistics(
    scene: *const fourdgs_scene,
    out_gaussian_count: *mut u64,
    out_chunk_count: *mut u32,
    out_duration_sec: *mut f64,
    out_aabb: *mut f64,
) -> c_int {
    guarded(|| {
        let scene = scene_ref!(scene);
        let Some(statistics) = scene.inner.statistics() else {
            set_last_error("this scene carries no statistics".into());
            return FOURDGS_STATUS_OUT_OF_RANGE;
        };
        // SAFETY: each pointer is checked for null; `out_aabb` is documented as having room
        // for six doubles.
        unsafe {
            if let Some(slot) = out_gaussian_count.as_mut() {
                *slot = statistics.gaussian_count;
            }
            if let Some(slot) = out_chunk_count.as_mut() {
                *slot = statistics.chunk_count;
            }
            if let Some(slot) = out_duration_sec.as_mut() {
                *slot = statistics.duration_sec;
            }
            if !out_aabb.is_null() && statistics.aabb.len() >= 6 {
                std::ptr::copy_nonoverlapping(statistics.aabb.as_ptr(), out_aabb, 6);
            }
        }
        FOURDGS_STATUS_OK
    })
}

/// How many Summary Offset records the file carries.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_summary_offset_count(scene: *const fourdgs_scene) -> u32 {
    match unsafe { scene.as_ref() } {
        Some(scene) => summary_offsets(scene).len() as u32,
        None => 0,
    }
}

fn summary_offsets(scene: &fourdgs_scene) -> &[crate::records::SummaryOffset] {
    scene.inner.summary_offsets()
}

/// Summary Offset `i`: which class of index record it frames, and where. Any out parameter
/// may be null.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_summary_offset_at(
    scene: *const fourdgs_scene,
    i: u32,
    out_group_opcode: *mut u8,
    out_group_start: *mut u64,
    out_group_length: *mut u64,
) -> c_int {
    guarded(|| {
        let scene = scene_ref!(scene);
        let entries = summary_offsets(scene);
        let Some(entry) = entries.get(i as usize) else {
            set_last_error(format!(
                "summary offset {i} is outside the {} the file carries",
                entries.len()
            ));
            return FOURDGS_STATUS_OUT_OF_RANGE;
        };
        // SAFETY: each pointer is checked for null and written at most once.
        unsafe {
            if let Some(slot) = out_group_opcode.as_mut() {
                *slot = entry.group_opcode;
            }
            if let Some(slot) = out_group_start.as_mut() {
                *slot = entry.group_start;
            }
            if let Some(slot) = out_group_length.as_mut() {
                *slot = entry.group_length;
            }
        }
        FOURDGS_STATUS_OK
    })
}

/// The Footer declared no CRC, or this reader could not prove which bytes it covered.
pub const FOURDGS_CRC_NOT_CHECKED: c_int = -1;
/// A CRC was declared and did not match. The index is untrustworthy; the chunks are not
/// implicated, and falling back to a front-to-back read is the correct recovery.
pub const FOURDGS_CRC_FAILED: c_int = 0;
/// A CRC was declared and matched.
pub const FOURDGS_CRC_VERIFIED: c_int = 1;

/// Which of the three the summary CRC is.
///
/// Three states, not two: "not checked" and "did not match" are different claims about a
/// file, and collapsing them would report corruption a reader never observed.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_summary_crc_state(scene: *const fourdgs_scene) -> c_int {
    match scene_or!(scene, FOURDGS_CRC_NOT_CHECKED)
        .inner
        .summary_crc_ok()
    {
        None => FOURDGS_CRC_NOT_CHECKED,
        Some(false) => FOURDGS_CRC_FAILED,
        Some(true) => FOURDGS_CRC_VERIFIED,
    }
}

/// Whether the file ended inside a record, with everything complete before the cut still
/// decoded. Always 0 on the indexed path, which requires a complete file.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_truncated(scene: *const fourdgs_scene) -> c_int {
    c_int::from(scene_or!(scene, 0).inner.truncated())
}

// --- One chunk at a time --------------------------------------------------

/// Decode exactly chunk `i` into the working set.
///
/// `fourdgs_scene_load_at` cannot isolate a chunk when intervals overlap, and isolating one
/// is what a byte-budget check needs. `FOURDGS_STATUS_UNSUPPORTED_MODE` on a sequential
/// reader, which has no index to fetch from and has already decoded everything.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_load_chunk(
    scene: *mut fourdgs_scene,
    i: u32,
    max_sh_band: u8,
) -> c_int {
    guarded(|| {
        let Some(scene) = (unsafe { scene.as_mut() }) else {
            set_last_error("the scene pointer is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        match scene.inner.load_chunk(i, max_sh_band) {
            Ok(_) => FOURDGS_STATUS_OK,
            Err(e) => report(e),
        }
    })
}

/// What reading chunk `i` at `max_sh_band` will transfer, from the index alone. 0 when `i`
/// is outside the index.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_bytes_for_chunk(
    scene: *const fourdgs_scene,
    i: u32,
    max_sh_band: u8,
) -> u64 {
    scene_or!(scene, 0)
        .inner
        .bytes_for_chunk(i, max_sh_band)
        .unwrap_or(0)
}

// --------------------------------------------------------------------------
// Encoding
// --------------------------------------------------------------------------
//
// The decode surface above ends at gaussian state; this is the other direction. The C++
// and Swift packages are bindings over the core rather than parallel encoders, so an
// authoring surface for the native tier is a handful of `fourdgs_writer_*` functions here
// and a thin shim per language — the same shape the decode surface already has.
//
// The four rules the header states hold unchanged: nothing unwinds (every entry point runs
// inside `catch_unwind`), every fallible call returns a `fourdgs_status`, null is safe, and
// borrowed pointers state their lifetime. Encoding adds one owned type — `fourdgs_buffer` —
// because the encoder produces a whole file at once rather than streaming, and the caller
// has to own those bytes until it has written them somewhere.
//
// These functions are additions to a frozen ABI: they appear after everything above and
// change no signature there.

/// A scene being assembled for encoding. Opaque to C.
///
/// Structure-of-arrays like the core it wraps: the gaussian columns are set in one call,
/// spherical harmonics in another, and the write options through the small setters below.
pub struct fourdgs_writer {
    gaussians: GaussianSet,
    duration_sec: f64,
    options: WriteOptions,
}

/// An owned buffer of encoded bytes. Opaque to C, freed with `fourdgs_buffer_free`.
pub struct fourdgs_buffer {
    data: Vec<u8>,
}

/// Borrow a writer mutably, or report a null argument.
macro_rules! writer_mut {
    ($writer:expr) => {
        match unsafe { $writer.as_mut() } {
            Some(w) => w,
            None => {
                set_last_error("the writer pointer is null".into());
                return FOURDGS_STATUS_INVALID_ARGUMENT;
            }
        }
    };
}

/// Copy `len` floats out of a caller-owned column, or `None` when the pointer is null and
/// `len` is not zero. An empty column is a valid empty vector, never a null-pointer error.
unsafe fn copy_f32(ptr: *const f32, len: usize) -> Option<Vec<f32>> {
    if len == 0 {
        return Some(Vec::new());
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller states `ptr` points at `len` readable floats.
    Some(unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec())
}

/// Read a borrowed `(pointer, length)` string as UTF-8. Null with length zero is the empty
/// string; null with a non-zero length is an error, as is invalid UTF-8.
unsafe fn read_utf8(data: *const c_char, length: usize) -> Result<String, c_int> {
    if length == 0 {
        return Ok(String::new());
    }
    if data.is_null() {
        set_last_error("a non-empty string was passed as null".into());
        return Err(FOURDGS_STATUS_INVALID_ARGUMENT);
    }
    // SAFETY: the caller states `data` points at `length` readable bytes.
    let bytes = unsafe { std::slice::from_raw_parts(data as *const u8, length) };
    match std::str::from_utf8(bytes) {
        Ok(text) => Ok(text.to_string()),
        Err(_) => {
            set_last_error("a string argument is not valid UTF-8".into());
            Err(FOURDGS_STATUS_INVALID_ARGUMENT)
        }
    }
}

/// Create an empty writer with the encoder's default options. Null on allocation failure,
/// which a caller checks exactly as it checks a failed open.
#[no_mangle]
pub extern "C" fn fourdgs_writer_new() -> *mut fourdgs_writer {
    match catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(fourdgs_writer {
            gaussians: GaussianSet::default(),
            duration_sec: 0.0,
            options: WriteOptions::default(),
        }))
    })) {
        Ok(ptr) => ptr,
        Err(_) => std::ptr::null_mut(),
    }
}

/// Release a writer. Null is accepted and ignored.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_writer_free(writer: *mut fourdgs_writer) {
    if writer.is_null() {
        return;
    }
    // SAFETY: `writer` came from `Box::into_raw` in `fourdgs_writer_new`.
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        drop(Box::from_raw(writer));
    }));
}

/// Scene length in seconds; playback will cover `[0, duration)`.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_writer_set_duration(
    writer: *mut fourdgs_writer,
    duration_sec: f64,
) -> c_int {
    guarded(|| {
        let w = writer_mut!(writer);
        w.duration_sec = duration_sec;
        FOURDGS_STATUS_OK
    })
}

/// The Header's marginal visibility threshold. It sets the support constant the per-gaussian
/// velocity grid is derived from, so encoder and decoder must agree on it — which they do by
/// its living in the file.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_writer_set_cutoff(
    writer: *mut fourdgs_writer,
    cutoff: f64,
) -> c_int {
    guarded(|| {
        let w = writer_mut!(writer);
        w.options.cutoff = cutoff;
        FOURDGS_STATUS_OK
    })
}

/// The temporal partition's depth and the smallest chunk worth its own record. `max_depth`
/// of 0 writes one chunk per window; a larger `min_chunk_gaussians` collapses fine nodes
/// back into their parent.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_writer_set_chunking(
    writer: *mut fourdgs_writer,
    max_depth: u32,
    min_chunk_gaussians: usize,
) -> c_int {
    guarded(|| {
        let w = writer_mut!(writer);
        w.options.max_depth = max_depth;
        w.options.min_chunk_gaussians = min_chunk_gaussians;
        FOURDGS_STATUS_OK
    })
}

/// Which parts of the summary the file carries. Each argument is a boolean: non-zero writes
/// that part, zero omits it. The index is what makes seeking work; the others are advisory.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_writer_set_summary(
    writer: *mut fourdgs_writer,
    write_index: c_int,
    write_statistics: c_int,
    write_summary_offsets: c_int,
    write_crc: c_int,
) -> c_int {
    guarded(|| {
        let w = writer_mut!(writer);
        w.options.write_index = write_index != 0;
        w.options.write_statistics = write_statistics != 0;
        w.options.write_summary_offsets = write_summary_offsets != 0;
        w.options.write_crc = write_crc != 0;
        FOURDGS_STATUS_OK
    })
}

/// The highest spherical harmonic band to write, 0 to 3. A scene may carry more coefficients
/// than are written; the excess is dropped rather than an error.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_writer_set_sh_bands(
    writer: *mut fourdgs_writer,
    sh_bands: u8,
) -> c_int {
    guarded(|| {
        let w = writer_mut!(writer);
        w.options.sh_bands = sh_bands;
        FOURDGS_STATUS_OK
    })
}

/// Per-band spherical harmonic bit depths, band 1 first. A null pointer or a zero count
/// clears the ladder, leaving the coefficients as the profile alone decides — which is what
/// a file written before this option existed did, byte for byte.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_writer_set_sh_bit_depths(
    writer: *mut fourdgs_writer,
    depths: *const u8,
    count: usize,
) -> c_int {
    guarded(|| {
        let w = writer_mut!(writer);
        if depths.is_null() || count == 0 {
            w.options.sh_bit_depths = None;
        } else {
            // SAFETY: the caller states `depths` points at `count` readable bytes.
            let slice = unsafe { std::slice::from_raw_parts(depths, count) };
            w.options.sh_bit_depths = Some(slice.to_vec());
        }
        FOURDGS_STATUS_OK
    })
}

/// The Header's `profile`: a promise about the file's shape. A `(pointer, length)` string,
/// UTF-8, not NUL-terminated — the format's `string` may legally contain a NUL.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_writer_set_profile(
    writer: *mut fourdgs_writer,
    data: *const c_char,
    length: usize,
) -> c_int {
    guarded(|| {
        let w = writer_mut!(writer);
        match unsafe { read_utf8(data, length) } {
            Ok(text) => {
                w.options.scene_profile = text;
                FOURDGS_STATUS_OK
            }
            Err(status) => status,
        }
    })
}

/// The Header's `library`: free-form producer identification. The same string convention as
/// `fourdgs_writer_set_profile`.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_writer_set_library(
    writer: *mut fourdgs_writer,
    data: *const c_char,
    length: usize,
) -> c_int {
    guarded(|| {
        let w = writer_mut!(writer);
        match unsafe { read_utf8(data, length) } {
            Ok(text) => {
                w.options.library = text;
                FOURDGS_STATUS_OK
            }
            Err(status) => status,
        }
    })
}

/// Add one key/value pair to the Header's attributes map. Both are `(pointer, length)`
/// UTF-8 strings. A repeated key overwrites, so the map a caller builds is the map the file
/// carries.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_writer_add_attribute(
    writer: *mut fourdgs_writer,
    key: *const c_char,
    key_length: usize,
    value: *const c_char,
    value_length: usize,
) -> c_int {
    guarded(|| {
        let w = writer_mut!(writer);
        let key = match unsafe { read_utf8(key, key_length) } {
            Ok(text) => text,
            Err(status) => return status,
        };
        let value = match unsafe { read_utf8(value, value_length) } {
            Ok(text) => text,
            Err(status) => return status,
        };
        w.options.metadata.insert(key, value);
        FOURDGS_STATUS_OK
    })
}

/// Set the gaussian columns, structure-of-arrays, all `count` gaussians at once.
///
/// The columns are copied, so the caller's arrays may be released as soon as this returns.
/// Widths are per gaussian: `positions`, `scales` and `motions` are three floats each,
/// `rotations` and `colors` four, and `mu_t`, `sigma_t`, `win_lo` and `win_hi` one. A null
/// column is an error unless `count` is zero. Setting the columns clears any spherical
/// harmonics previously attached, because their row count is tied to this one — set the
/// gaussians first, then the harmonics.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn fourdgs_writer_set_gaussians(
    writer: *mut fourdgs_writer,
    count: u32,
    positions: *const f32,
    scales: *const f32,
    rotations: *const f32,
    colors: *const f32,
    motions: *const f32,
    mu_t: *const f32,
    sigma_t: *const f32,
    win_lo: *const f32,
    win_hi: *const f32,
) -> c_int {
    guarded(|| {
        let w = writer_mut!(writer);
        let n = count as usize;
        macro_rules! column {
            ($ptr:expr, $width:expr, $name:literal) => {
                match unsafe { copy_f32($ptr, n * $width) } {
                    Some(values) => values,
                    None => {
                        set_last_error(
                            concat!($name, " is null for a non-empty gaussian set").into(),
                        );
                        return FOURDGS_STATUS_INVALID_ARGUMENT;
                    }
                }
            };
        }
        let positions = column!(positions, 3, "positions");
        let scales = column!(scales, 3, "scales");
        let rotations = column!(rotations, 4, "rotations");
        let colors = column!(colors, 4, "colors");
        let motions = column!(motions, 3, "motions");
        let mu_t = column!(mu_t, 1, "mu_t");
        let sigma_t = column!(sigma_t, 1, "sigma_t");
        let win_lo = column!(win_lo, 1, "win_lo");
        let win_hi = column!(win_hi, 1, "win_hi");

        w.gaussians = GaussianSet {
            positions,
            scales,
            rotations,
            colors,
            motions,
            mu_t,
            sigma_t,
            win_lo,
            win_hi,
            sh: None,
            sh_coefficients: 0,
            sh_degree: 0,
            source_index: None,
            // The C ABI encode surface does not carry object_id; a file written through it
            // groups nothing. The reader still surfaces it when a file has one.
            object_id: None,
        };
        FOURDGS_STATUS_OK
    })
}

/// Attach spherical harmonic coefficients to the gaussians already set.
///
/// `coefficients` is the count per colour component, so a row is three times that wide and
/// the payload is `count * 3 * coefficients` bytes, component-major: every coefficient of
/// red, then of green, then of blue. A null payload, a zero degree or a zero coefficient
/// count clears the harmonics. The payload is copied.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_writer_set_sh(
    writer: *mut fourdgs_writer,
    degree: u8,
    coefficients: u32,
    sh: *const u8,
    length: usize,
) -> c_int {
    guarded(|| {
        let w = writer_mut!(writer);
        if degree == 0 || coefficients == 0 || sh.is_null() || length == 0 {
            w.gaussians.sh = None;
            w.gaussians.sh_degree = 0;
            w.gaussians.sh_coefficients = 0;
            return FOURDGS_STATUS_OK;
        }
        let n = w.gaussians.count();
        let expected = n.saturating_mul(3).saturating_mul(coefficients as usize);
        if length != expected {
            set_last_error(format!(
                "sh payload is {length} bytes; {n} gaussians at {coefficients} coefficients need {expected}"
            ));
            return FOURDGS_STATUS_MALFORMED;
        }
        // SAFETY: the caller states `sh` points at `length` readable bytes.
        let bytes = unsafe { std::slice::from_raw_parts(sh, length) }.to_vec();
        w.gaussians.sh = Some(bytes);
        w.gaussians.sh_degree = degree;
        w.gaussians.sh_coefficients = coefficients as usize;
        FOURDGS_STATUS_OK
    })
}

/// Encode the scene into an owned buffer.
///
/// The encoder verifies its own bounds before returning — it decodes every chunk back and
/// refuses a file whose measured deviation exceeds what it is about to declare — so a
/// success here is a file whose Quantization record was checked on every gaussian. On
/// failure the out parameter is left untouched and `fourdgs_last_error` names the reason.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_writer_encode(
    writer: *mut fourdgs_writer,
    out: *mut *mut fourdgs_buffer,
) -> c_int {
    guarded(|| {
        let w = writer_mut!(writer);
        if out.is_null() {
            set_last_error("the out parameter is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        let extras = SceneExtras::default();
        match write_to_vec(&w.gaussians, w.duration_sec, &w.options, &extras) {
            Ok(bytes) => {
                let buffer = Box::new(fourdgs_buffer { data: bytes });
                // SAFETY: `out` was checked non-null; the caller frees the result with
                // `fourdgs_buffer_free`.
                unsafe { *out = Box::into_raw(buffer) };
                FOURDGS_STATUS_OK
            }
            Err(e) => report(e),
        }
    })
}

/// The encoded bytes, borrowed until the buffer is freed. Null for an empty buffer.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_buffer_data(buffer: *const fourdgs_buffer) -> *const u8 {
    // SAFETY: null is handled; otherwise the caller guarantees a live buffer.
    match unsafe { buffer.as_ref() } {
        Some(b) if !b.data.is_empty() => b.data.as_ptr(),
        _ => std::ptr::null(),
    }
}

/// How many bytes the buffer holds. 0 for a null buffer.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_buffer_len(buffer: *const fourdgs_buffer) -> usize {
    // SAFETY: null is handled; otherwise the caller guarantees a live buffer.
    match unsafe { buffer.as_ref() } {
        Some(b) => b.data.len(),
        None => 0,
    }
}

/// Release an encoded buffer. Null is accepted and ignored.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_buffer_free(buffer: *mut fourdgs_buffer) {
    if buffer.is_null() {
        return;
    }
    // SAFETY: `buffer` came from `Box::into_raw` in `fourdgs_writer_encode`.
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        drop(Box::from_raw(buffer));
    }));
}

// --------------------------------------------------------------------------
// keyframe-delta: decode a whole file to its canonical states JSON
// --------------------------------------------------------------------------
//
// Additive surface for the keyframe-delta temporal model. The scene reader deliberately
// refuses a model it does not implement, so C++ and Swift cannot reach these files through
// `fourdgs_open_*`. Rather than widen the scene API, these two functions take the whole file
// as bytes and return owned strings the caller frees with `fourdgs_string_free`: the summary
// is computed entirely in Rust, so every binding emits the same bytes with no per-language
// arithmetic to drift.

/// Hand an owned JSON/string result across the boundary as (pointer, length).
///
/// The bytes are heap-allocated here and owned by the caller until `fourdgs_string_free`.
/// Not NUL-terminated: like every string read out of a file's bytes, it carries its length.
fn put_owned_string(text: String, out: *mut *const c_char, out_len: *mut usize) -> c_int {
    if out.is_null() || out_len.is_null() {
        set_last_error("a string out parameter is null".into());
        return FOURDGS_STATUS_INVALID_ARGUMENT;
    }
    let boxed: Box<[u8]> = text.into_bytes().into_boxed_slice();
    let len = boxed.len();
    let ptr = Box::into_raw(boxed) as *mut c_char;
    // SAFETY: both pointers were checked non-null; the bytes are owned by the caller until
    // `fourdgs_string_free`, which reconstructs the same box from this pointer and length.
    unsafe {
        *out = ptr as *const c_char;
        *out_len = len;
    }
    FOURDGS_STATUS_OK
}

fn borrow_bytes<'a>(data: *const u8, length: usize) -> Option<&'a [u8]> {
    if length == 0 {
        return Some(&[]);
    }
    if data.is_null() {
        return None;
    }
    // SAFETY: the caller states `data` points at `length` readable bytes.
    Some(unsafe { std::slice::from_raw_parts(data, length) })
}

/// The Header's declared temporal model, read from bytes without opening a scene.
///
/// A binding dispatches on this before choosing a read path: `keyframe-delta` goes to
/// `fourdgs_keyframe_delta_states_json`, anything else through the ordinary open. On success
/// `out` owns a string freed with `fourdgs_string_free`. As with every two-out-parameter
/// call here, sequence it — read `out`/`out_len` only after the call returns OK.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_peek_temporal_model(
    data: *const u8,
    length: usize,
    out: *mut *const c_char,
    out_len: *mut usize,
) -> c_int {
    guarded(|| {
        if out.is_null() || out_len.is_null() {
            set_last_error("a string out parameter is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        let Some(bytes) = borrow_bytes(data, length) else {
            set_last_error("a non-empty buffer was passed as null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        match crate::keyframe_delta_file::peek_temporal_model(bytes) {
            Ok(model) => put_owned_string(model, out, out_len),
            Err(e) => report(e),
        }
    })
}

/// Decode a `keyframe-delta` file and return its canonical states JSON.
///
/// `indexed == 0` walks the file front to back, composing each chunk onto the last;
/// `indexed != 0` reads the index and walks only each instant's chain. Both MUST agree, and
/// the harness proves it by running this on both paths. On success `out` owns a string freed
/// with `fourdgs_string_free`. A file whose Header is not `keyframe-delta` is reported
/// `FOURDGS_STATUS_MALFORMED` on the streamed path — it is the wrong reader for that file.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_keyframe_delta_states_json(
    data: *const u8,
    length: usize,
    indexed: c_int,
    out: *mut *const c_char,
    out_len: *mut usize,
) -> c_int {
    guarded(|| {
        if out.is_null() || out_len.is_null() {
            set_last_error("a string out parameter is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        let Some(bytes) = borrow_bytes(data, length) else {
            set_last_error("a non-empty buffer was passed as null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        let decoded = if indexed != 0 {
            crate::keyframe_delta_file::decode_indexed(bytes).map(|(seq, _)| seq)
        } else {
            crate::keyframe_delta_file::decode_streamed(bytes)
        };
        match decoded {
            Ok(seq) => put_owned_string(
                crate::keyframe_delta_file::keyframe_delta_states_json(&seq),
                out,
                out_len,
            ),
            Err(e) => report(e),
        }
    })
}

/// Canonical provenance JSON for an opened scene (spec §5.15).
///
/// Works on both open paths: on the indexed path the records are fetched if not already
/// resident; on the sequential path they were read at open. An empty string means the file
/// carries no provenance — the binding should omit the key, not emit null. On success `out`
/// owns a string freed with `fourdgs_string_free`. Sequence the two out parameters the way
/// every other call here does: read them only after this returns OK.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_provenance_json(
    scene: *mut fourdgs_scene,
    out: *mut *const c_char,
    out_len: *mut usize,
) -> c_int {
    guarded(|| {
        if out.is_null() || out_len.is_null() {
            set_last_error("a string out parameter is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        let Some(scene) = (unsafe { scene.as_mut() }) else {
            set_last_error("the scene is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        match scene.inner.provenance() {
            Ok(prov) => match crate::provenance::canonical_json(&prov) {
                Ok(json) => put_owned_string(json, out, out_len),
                Err(e) => report(e),
            },
            Err(e) => report(e),
        }
    })
}

/// Canonical object-layer JSON for an opened scene (spec §5.15.6-§5.15.7).
///
/// The Object Table, the SE(3) tracks with their sampled poses, and the composed state at
/// three scene-clock probes — the summary that proves base-then-track composition rather
/// than merely that the records were read. Computed in the core so that C++ and Swift
/// cannot drift from each other, or from Rust, on the slerp or the composition order.
///
/// An empty string means the file carries neither object records nor per-gaussian
/// membership: the binding should omit the keys, not emit null. Works on both open paths;
/// on the indexed path the records are fetched if not already resident. On success `out`
/// owns a string freed with `fourdgs_string_free`. Sequence the two out parameters as
/// every other call here does — read them only after this returns OK.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_objects_json(
    scene: *mut fourdgs_scene,
    out: *mut *const c_char,
    out_len: *mut usize,
) -> c_int {
    unsafe { object_canonical_member(scene, out, out_len, false) }
}

/// Shared body: both accessors compose the layer the same way and differ only in which
/// rendered member they hand back.
unsafe fn object_canonical_member(
    scene: *mut fourdgs_scene,
    out: *mut *const c_char,
    out_len: *mut usize,
    want_states: bool,
) -> c_int {
    guarded(|| {
        if out.is_null() || out_len.is_null() {
            set_last_error("a string out parameter is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        }
        let Some(scene) = (unsafe { scene.as_mut() }) else {
            set_last_error("the scene is null".into());
            return FOURDGS_STATUS_INVALID_ARGUMENT;
        };
        let header = scene.inner.header().clone();
        let layer = match scene.inner.objects() {
            Ok(layer) => layer,
            Err(e) => return report(e),
        };
        // The whole population at the file's full SH degree, whatever the caller left
        // resident. Two reasons, and the second is the one that is easy to argue away:
        //
        // 1. The summary reports every gaussian's composed state, so a partial load would
        //    silently report a partial scene.
        // 2. `stable_order` places the SH coefficients *before* `object_id`. Two gaussians
        //    tied on every base attribute but differing in both their harmonics and their
        //    membership sort by the harmonics when those are resident and by the id when
        //    they are not — and membership is a value these members emit, so the flip is
        //    visible. Summarizing at the caller's cap would make canonical output depend
        //    on call history, which is the one thing a canonical form may not do.
        //
        // It is tempting to stop at "rows that tie up to the harmonics are identical in
        // everything emitted". That is false exactly when the ids differ, because the ids
        // are keyed after the harmonics rather than before them.
        //
        // The caller's cap is restored afterwards: a consumer that capped bands to save
        // memory should not find the full set resident because it asked for a summary.
        // That costs a second decode, and only for a caller who capped.
        let band = scene.inner.loaded_band();
        let full = header.sh_degree;
        if let Err(e) = scene.inner.load_all(full) {
            return report(e);
        }
        // Summarized against the borrow rather than a copy. The obvious way to satisfy the
        // borrow checker here is to clone the resident set so the restore below can take
        // `&mut` — which would hold two whole decoded populations at once, on the one call
        // that has just decoded the largest one it ever will. The scope ends the borrow
        // instead, and `CanonicalParts` is owned strings, so nothing outlives it.
        let parts = {
            let gaussians = scene.inner.loaded();
            crate::object_layer::canonical_parts(&header, gaussians, &layer)
        };
        if band < full {
            if let Err(e) = scene.inner.load_all(band) {
                return report(e);
            }
        }
        match parts {
            Ok(parts) => put_owned_string(
                if want_states {
                    parts.states
                } else {
                    parts.objects
                },
                out,
                out_len,
            ),
            Err(e) => report(e),
        }
    })
}

/// The `states` member an object-layer file adds to a scene summary: post-composition
/// gaussian state at each probe time.
///
/// Separate from `fourdgs_scene_objects_json` because the two sit side by side at the root
/// of the summary, so a binding places each under its own key rather than cutting one
/// document apart. Same contract as that call in every other respect: an empty string
/// means the file carries neither object records nor membership, both open paths work, and
/// the string is freed with `fourdgs_string_free`.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_object_states_json(
    scene: *mut fourdgs_scene,
    out: *mut *const c_char,
    out_len: *mut usize,
) -> c_int {
    unsafe { object_canonical_member(scene, out, out_len, true) }
}

/// Release a string owned by the caller — the result of `fourdgs_peek_temporal_model`,
/// `fourdgs_keyframe_delta_states_json` or `fourdgs_scene_provenance_json`. Null is
/// accepted and ignored. The length must be the one the producing call returned; the pair
/// identifies the same allocation.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_string_free(data: *const c_char, length: usize) {
    if data.is_null() {
        return;
    }
    // SAFETY: `data`/`length` name a box created by `put_owned_string`. Reconstructing the
    // boxed slice from the same pointer and length drops exactly that allocation.
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        let slice = std::slice::from_raw_parts_mut(data as *mut u8, length);
        drop(Box::from_raw(slice as *mut [u8]));
    }));
}
