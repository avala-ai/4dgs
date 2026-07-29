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
use crate::model::StateAt;
use crate::readable::{FileReadable, Readable};
use crate::reader::SceneReader;

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
        Error::BoundViolation(_) => FOURDGS_STATUS_MALFORMED,
        Error::Io(_) => FOURDGS_STATUS_IO,
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
            let scene = Box::new(fourdgs_scene {
                inner,
                strings: Vec::new(),
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

/// What a seek to `t` will transfer with SH capped at `max_sh_band`, so a caller can budget
/// before asking.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_bytes_for_time(
    scene: *const fourdgs_scene,
    t: f64,
    max_sh_band: u8,
) -> u64 {
    let scene = scene_or!(scene, 0);
    scene
        .inner
        .chunk_index()
        .iter()
        .filter(|e| e.covers(t))
        .map(|e| {
            e.bands
                .iter()
                .filter(|(band, _, _)| *band <= max_sh_band)
                .fold(e.chunk_length, |total, (_, _, length)| {
                    total.saturating_add(*length)
                })
        })
        .fold(0u64, u64::saturating_add)
}

// --------------------------------------------------------------------------
// Audio
// --------------------------------------------------------------------------

/// Whether the scene has a soundtrack, answered from the Header alone — no probing and no
/// speculative range request. Absence is a normal value, never an error.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_has_audio(scene: *const fourdgs_scene) -> c_int {
    c_int::from(scene_or!(scene, 0).inner.has_audio())
}

/// The audio codec's registry name, or null when the scene has no track. Borrowed; valid
/// until the scene is freed.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_audio_codec(scene: *mut fourdgs_scene) -> *const c_char {
    // SAFETY: null is handled; otherwise the caller guarantees a live scene.
    let Some(scene) = (unsafe { scene.as_mut() }) else {
        return std::ptr::null();
    };
    let Some(codec) = scene.inner.audio_codec() else {
        return std::ptr::null();
    };
    let Ok(owned) = CString::new(codec) else {
        return std::ptr::null();
    };
    scene.strings.push(owned);
    scene.strings.last().expect("just pushed").as_ptr()
}

/// The track's length in bytes, without fetching it. 0 when there is no track.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_scene_audio_size(scene: *const fourdgs_scene) -> u64 {
    scene_or!(scene, 0).inner.audio_len().unwrap_or(0)
}

/// Copy `length` bytes of the track from `offset` into `out`, which must have room for
/// them. Offsets are relative to the track, not to the file, and the read touches only
/// those bytes.
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
                unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len()) };
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

/// `color.a * marginal`, 1 float per visible gaussian.
#[no_mangle]
pub unsafe extern "C" fn fourdgs_state_opacity(state: *const fourdgs_state) -> *const f32 {
    // SAFETY: null is handled; otherwise the caller guarantees a live state.
    match unsafe { state.as_ref() } {
        Some(s) if !s.inner.opacity.is_empty() => s.inner.opacity.as_ptr(),
        _ => std::ptr::null(),
    }
}
