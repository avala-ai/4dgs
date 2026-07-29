// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

//! Structural fuzzing: seeded mutations of real files, and one invariant.
//!
//! **Any input at all produces either a decoded scene or a typed error.** Never a panic,
//! never a hang, never an allocation out of proportion to the input. A decoder parses
//! untrusted bytes; that invariant is the whole security posture, and it is worth more
//! than any particular malformed file somebody thought to write down.
//!
//! Three things are actually measured rather than hoped for:
//!
//! * **No panic.** Every decode runs inside `catch_unwind`, and a panic fails the test
//!   with the seed and mutation that caused it, so it is reproducible from the output
//!   alone. Across the C ABI a panic would be undefined behaviour in the caller's runtime,
//!   which is why that boundary is fuzzed here too and treated as critical.
//! * **No unbounded allocation.** A counting allocator records the peak of each decode. A
//!   crafted length field is the classic way to turn a 200-byte file into a request for 16
//!   exabytes, and the cap here is what proves lengths are checked against the resource
//!   before anything is sized from them.
//! * **No hang.** Each decode is timed, and one that takes absurdly long for a small input
//!   fails. A quadratic blowup on a crafted file is a denial of service even though every
//!   individual step terminates.
//!
//! Seeds are built by this crate's own encoder rather than read from the corpus, so this
//! runs under a bare `cargo test` with nothing generated first — and a fuzz test that
//! silently skips itself is worse than no fuzz test.

use std::alloc::{GlobalAlloc, Layout, System};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use fourdgs::model::{AudioTrack, GaussianSet};
use fourdgs::writer::{SceneExtras, WriteOptions};

/// Peak live bytes since the last reset. Only meaningful while `TRACKING` is set, which
/// the single test below does around one decode at a time.
static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);
static TRACKING: AtomicBool = AtomicBool::new(false);

struct Counting;

// SAFETY: every method forwards to the system allocator with the same layout it was
// given, and the counters are plain atomics that never touch the returned memory.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if TRACKING.load(Ordering::Relaxed) {
            let live = LIVE.fetch_add(layout.size(), Ordering::Relaxed) + layout.size();
            PEAK.fetch_max(live, Ordering::Relaxed);
        }
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        if TRACKING.load(Ordering::Relaxed) {
            LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
        }
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

/// What a decode of a mutated file may cost, whatever the file claims.
const ALLOCATION_CAP: usize = 64 * 1024 * 1024;
/// What a decode of one of these files may take. Generous by three orders of magnitude:
/// this is a hang detector, not a benchmark.
const TIME_CAP: Duration = Duration::from_secs(5);
/// Mutations per seed file. Enough to reach every parser in the crate, few enough that the
/// whole job stays well inside a couple of minutes.
const MUTATIONS: u32 = 3000;

/// xorshift32, hand-written so a mutation is reproducible from its seed forever. A library
/// generator's stream is only stable as far as that library promises.
struct Rng(u32);

impl Rng {
    fn next(&mut self) -> u32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 17;
        self.0 ^= self.0 << 5;
        self.0
    }

    fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            0
        } else {
            self.next() as usize % n
        }
    }
}

/// A small scene, optionally with the features that add records and byte ranges.
fn seed_file(gaussians: usize, audio: bool, sh_degree: u8, index: bool) -> Vec<u8> {
    let mut state = Rng(0xC0FFEE);
    let mut g = GaussianSet::default();
    for i in 0..gaussians {
        for _ in 0..3 {
            g.positions.push(state.below(2000) as f32 / 1000.0 - 1.0);
        }
        for _ in 0..3 {
            g.scales.push(0.001 + state.below(100) as f32 / 100000.0);
        }
        let mut quat = [0.05f64, -0.05, 0.05, -0.05];
        quat[i % 4] = 1.0;
        let norm = quat.iter().map(|v| v * v).sum::<f64>().sqrt();
        for v in quat {
            g.rotations.push((v / norm) as f32);
        }
        for _ in 0..4 {
            g.colors.push(state.below(1000) as f32 / 1000.0);
        }
        for _ in 0..3 {
            g.motions.push(state.below(200) as f32 / 1000.0 - 0.1);
        }
        g.mu_t.push(state.below(1000) as f32 / 500.0);
        g.sigma_t.push(if i % 6 == 0 {
            f32::INFINITY
        } else {
            0.02 + state.below(100) as f32 / 500.0
        });
        g.win_lo.push(0.0);
        g.win_hi.push(2.0);
    }
    if sh_degree > 0 {
        let per_component = if sh_degree == 1 { 3 } else { 8 };
        g.sh_degree = sh_degree;
        g.sh_coefficients = per_component;
        g.sh = Some(
            (0..gaussians * per_component * 3)
                .map(|i| (i % 251) as u8)
                .collect(),
        );
    }

    let options = WriteOptions {
        min_chunk_gaussians: 4,
        max_depth: 3,
        write_index: index,
        write_statistics: true,
        write_summary_offsets: true,
        ..Default::default()
    };
    let extras = SceneExtras {
        audio_sources: Vec::new(),
        audio: audio.then(|| AudioTrack {
            codec: "wav".into(),
            start_sec: 0.0,
            data: vec![0x5A; 3000],
        }),
        camera: Some(fourdgs::records::Camera::default()),
        metadata: vec![fourdgs::records::Metadata {
            name: "fuzz".into(),
            entries: Default::default(),
        }],
        attachments: vec![fourdgs::records::Attachment {
            name: "a".into(),
            media_type: "text/plain".into(),
            data: b"attached".to_vec(),
        }],
        ..Default::default()
    };
    fourdgs::write_to_vec(&g, 2.0, &options, &extras).expect("the seed encodes")
}

/// One structural mutation. The set is deliberately biased towards length and offset
/// fields, because those are what turn a malformed file into an allocation or a hang
/// rather than into a wrong number.
fn mutate(data: &[u8], rng: &mut Rng) -> Vec<u8> {
    let mut out = data.to_vec();
    if out.is_empty() {
        return out;
    }
    match rng.next() % 8 {
        0 => {
            // Flip bits somewhere.
            let at = rng.below(out.len());
            out[at] ^= (rng.next() % 255 + 1) as u8;
        }
        1 => {
            // Cut the file short. Truncation is the common real-world corruption.
            out.truncate(rng.below(out.len()));
        }
        2 => {
            // Zero a run, which reliably lands on a length field somewhere.
            let at = rng.below(out.len());
            let len = rng.below(32).min(out.len() - at);
            out[at..at + len].fill(0);
        }
        3 => {
            // Make a u64 enormous. This is the classic "declare 16 exabytes" attack.
            if out.len() >= 8 {
                let at = rng.below(out.len() - 8);
                out[at..at + 8].copy_from_slice(&u64::MAX.to_le_bytes());
            }
        }
        4 => {
            // A plausible-looking but wrong length, which is harder to reject than an
            // absurd one.
            if out.len() >= 8 {
                let at = rng.below(out.len() - 8);
                let value = (rng.next() as u64) << 8;
                out[at..at + 8].copy_from_slice(&value.to_le_bytes());
            }
        }
        5 => {
            // Duplicate a span, so record framing desynchronizes rather than breaking.
            let at = rng.below(out.len());
            let len = rng.below(64).min(out.len() - at);
            let span = out[at..at + len].to_vec();
            out.splice(at..at, span);
        }
        6 => {
            // Corrupt an opcode, exercising the skip-what-you-do-not-know path.
            let at = rng.below(out.len());
            out[at] = (rng.next() % 256) as u8;
        }
        _ => {
            // Remove a span.
            let at = rng.below(out.len());
            let len = rng.below(64).min(out.len() - at);
            out.drain(at..at + len);
        }
    }
    out
}

/// Run one decode with the invariant enforced around it.
fn check<F: FnOnce()>(what: &str, seed: u32, step: u32, input_len: usize, body: F) {
    LIVE.store(0, Ordering::Relaxed);
    PEAK.store(0, Ordering::Relaxed);
    TRACKING.store(true, Ordering::Relaxed);
    let started = Instant::now();
    let outcome = catch_unwind(AssertUnwindSafe(body));
    let elapsed = started.elapsed();
    TRACKING.store(false, Ordering::Relaxed);
    let peak = PEAK.load(Ordering::Relaxed);

    assert!(
        outcome.is_ok(),
        "{what} panicked on seed {seed} mutation {step}; a decoder must return a typed error \
         for any input, and across the C ABI a panic is undefined behaviour in the caller"
    );
    assert!(
        peak <= ALLOCATION_CAP,
        "{what} allocated {peak} bytes from a {input_len}-byte input on seed {seed} mutation \
         {step}; a length has to be checked against the resource before anything is sized \
         from it"
    );
    assert!(
        elapsed <= TIME_CAP,
        "{what} took {elapsed:?} on a {input_len}-byte input, seed {seed} mutation {step}; \
         that is a denial of service even if every step terminates"
    );
}

/// The whole fuzz run lives in one test on purpose: the allocation counter is global, so
/// two decodes in parallel would measure each other.
#[test]
fn any_input_decodes_or_fails_cleanly() {
    // Panics are expected during this test and are reported by the assertions above, so
    // the default hook's backtraces would be pure noise. Set FOURDGS_FUZZ_VERBOSE to get
    // them back when one of those assertions has just fired and you need the location.
    let verbose = std::env::var_os("FOURDGS_FUZZ_VERBOSE").is_some();
    let previous = std::panic::take_hook();
    if !verbose {
        std::panic::set_hook(Box::new(|_| {}));
    }

    let seeds = [
        seed_file(32, false, 0, true),
        seed_file(32, true, 0, true),
        seed_file(24, false, 2, true),
        // No index: the reader has to fall back to a front-to-back pass, which is a
        // different set of code to walk off the end of.
        seed_file(24, false, 0, false),
        seed_file(0, false, 0, true),
    ];

    let result = catch_unwind(AssertUnwindSafe(|| {
        for (index, seed_bytes) in seeds.iter().enumerate() {
            let seed = 0x4D47_0000 + index as u32;
            let mut rng = Rng(seed);
            for step in 0..MUTATIONS {
                let input = mutate(seed_bytes, &mut rng);
                let len = input.len();

                check("streamed decode", seed, step, len, || {
                    // The result is deliberately ignored: both Ok and Err are correct
                    // answers, and the invariant is that it is one of them.
                    let _ = fourdgs::read_bytes(&input);
                });

                check("indexed decode", seed, step, len, || {
                    let mut source = OwnedSource(input.clone());
                    if let Ok(mut reader) = fourdgs::SceneReader::open(&mut source) {
                        let _ = reader.load_all(3);
                        let _ = reader.state_at(1.0, 3);
                        let _ = reader.read_audio();
                        let _ = reader.camera();
                        let _ = reader.metadata();
                        let _ = reader.attachments();
                    }
                });

                check("the C ABI", seed, step, len, || {
                    exercise_c_abi(&input);
                });
            }
        }
    }));

    std::panic::set_hook(previous);
    if let Err(payload) = result {
        // The hook above swallowed the message on its way out, and `resume_unwind` does
        // not call a hook at all — so a failure would arrive with no diagnosis unless it
        // is dug out of the payload and raised again.
        let message = payload
            .downcast_ref::<String>()
            .cloned()
            .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
            .unwrap_or_else(|| "a fuzz check failed with an unprintable payload".to_string());
        panic!("{message}");
    }
}

/// Drive the C surface the way a binding does, on bytes that are not a valid file.
///
/// A panic here would unwind into C++ or Swift, which is undefined behaviour rather than
/// an error they can handle — so this is the boundary the invariant matters most at.
fn exercise_c_abi(input: &[u8]) {
    use fourdgs::capi::*;

    let mut scene: *mut fourdgs_scene = std::ptr::null_mut();
    // SAFETY: `input` is a live slice for the duration of the call, and the scene pointer
    // is freed below on exactly the path that set it.
    let status = unsafe { fourdgs_open_memory(input.as_ptr(), input.len(), &mut scene) };
    if status != FOURDGS_STATUS_OK {
        assert!(
            scene.is_null(),
            "a failed open must leave the out parameter untouched"
        );
        return;
    }
    assert!(!scene.is_null(), "an OK open must produce a scene");

    // SAFETY: `scene` came from a successful open and is used only here, then freed once.
    unsafe {
        let _ = fourdgs_scene_load_all(scene, 3);
        let _ = fourdgs_scene_loaded_count(scene);
        let _ = fourdgs_scene_positions(scene);
        let _ = fourdgs_scene_sh(scene);
        let _ = fourdgs_scene_audio_codec(scene);
        let source_count = fourdgs_scene_audio_source_count(scene);
        for index in 0..source_count {
            let mut descriptor = std::mem::MaybeUninit::<fourdgs_audio_source>::uninit();
            if fourdgs_scene_audio_source(scene, index, descriptor.as_mut_ptr())
                == FOURDGS_STATUS_OK
            {
                let descriptor = descriptor.assume_init();
                let mut source_state =
                    std::mem::MaybeUninit::<fourdgs_audio_source_state>::uninit();
                let _ = fourdgs_scene_audio_source_state_at(
                    scene,
                    index,
                    1.0,
                    source_state.as_mut_ptr(),
                );
                if descriptor.data_size > 0 {
                    let mut head = [0u8; 8];
                    let _ = fourdgs_scene_audio_source_read(
                        scene,
                        index,
                        0,
                        8.min(descriptor.data_size),
                        head.as_mut_ptr(),
                    );
                }
            }
        }
        let size = fourdgs_scene_audio_size(scene);
        if size > 0 {
            let mut head = [0u8; 8];
            let _ = fourdgs_scene_audio_read(scene, 0, 8.min(size), head.as_mut_ptr());
        }
        let mut state: *mut fourdgs_state = std::ptr::null_mut();
        if fourdgs_scene_state_at(scene, 1.0, 3, &mut state) == FOURDGS_STATUS_OK {
            let count = fourdgs_state_count(state);
            let indices = fourdgs_state_indices(state);
            let resident = fourdgs_scene_loaded_count(scene);
            if count > 0 && !indices.is_null() {
                let slice = std::slice::from_raw_parts(indices, count as usize);
                for i in slice {
                    assert!(
                        *i < resident,
                        "a state index must point into the resident set"
                    );
                }
            }
            fourdgs_state_free(state);
        }
        fourdgs_scene_free(scene);
    }
}

/// A `Readable` over an owned buffer, so the indexed path can be fuzzed without a file.
struct OwnedSource(Vec<u8>);

impl fourdgs::Readable for OwnedSource {
    fn size(&mut self) -> fourdgs::Result<u64> {
        Ok(self.0.len() as u64)
    }

    fn read(&mut self, offset: u64, length: u64) -> fourdgs::Result<Vec<u8>> {
        fourdgs::BytesReadable::new(&self.0).read(offset, length)
    }
}
