/*
 * Copyright 2026 Avala AI
 * SPDX-License-Identifier: Apache-2.0
 *
 * 4dgs — decode C ABI.
 *
 * This header is the delivery surface for the native tier: the C++ and Swift packages
 * bind to it rather than reimplementing the format. It is hand-written and kept in step
 * with rust/fourdgs/src/capi.rs, which is the only place these symbols are defined.
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS IS FOR
 *
 * Decoding ends at reconstructed gaussian state at time t. This surface hands back
 * positions, scales, rotations, colours, motion, the temporal fields and spherical
 * harmonics, plus the reconstruction at an instant. How that state is drawn — ordering,
 * culling, level of detail, budgets, shaders — is out of scope for this library and for
 * anything built directly on this header.
 *
 * ---------------------------------------------------------------------------
 * THE FOUR RULES
 *
 * 1. NOTHING UNWINDS. No function here can panic, abort or throw across the boundary. A
 *    defect inside the decoder becomes FOURDGS_STATUS_INTERNAL. Callers never need a
 *    catch block, and a panic reaching a binding would be a critical bug in this library.
 *
 * 2. EVERY FALLIBLE CALL RETURNS fourdgs_status. Results come back through out
 *    parameters. A non-OK status leaves every out parameter untouched, so a caller that
 *    checks the status never reads an uninitialised pointer.
 *
 * 3. NULL IS ALWAYS SAFE TO PASS. A null object pointer yields
 *    FOURDGS_STATUS_INVALID_ARGUMENT from the status-returning calls, and a documented
 *    zero value from the value-returning ones. The free functions ignore null.
 *
 * 4. BORROWED POINTERS HAVE A STATED LIFETIME. Every function returning a `const T *`
 *    says below what invalidates it. Nothing returned here is owned by the caller unless
 *    the function name says `_free` exists for it.
 *
 * ---------------------------------------------------------------------------
 * STRINGS ARE NOT NUL-TERMINATED
 *
 * Anything read out of the file's bytes crosses as a (pointer, length) pair, never as a C
 * string. The format's `string` is length-prefixed and may legally contain a NUL, so a
 * C-string accessor would silently truncate there — and silently is the problem. Copy into
 * std::string(ptr, len), String(bytes:), or the equivalent.
 *
 * The one exception is `fourdgs_scene_audio_codec`, which predates this rule and returns a
 * NUL-terminated registry name.
 *
 * CALL FIRST, THEN READ THE OUT PARAMETERS. The two-out-parameter shape invites one
 * specific bug, and it is silent in both C and C++: argument evaluation order is
 * unspecified, so a helper written as
 *
 *     return borrowed(fourdgs_scene_temporal_model(scene, &data, &length), data, length);
 *
 * may read `data` and `length` BEFORE the call that fills them. No warning, no crash — an
 * empty string every time, from a call that returned FOURDGS_STATUS_OK. Sequence it:
 *
 *     const char *data = NULL;
 *     size_t length = 0;
 *     int status = fourdgs_scene_temporal_model(scene, &data, &length);
 *     if (status != FOURDGS_STATUS_OK) return ...;
 *     use(data, length);
 *
 * The same applies to every accessor here that fills more than one out parameter.
 *
 * ---------------------------------------------------------------------------
 * THREADING
 *
 * A fourdgs_scene is not internally synchronised: one scene belongs to one thread at a
 * time, and decoding is pure CPU on immutable input, so the natural pattern is one scene
 * per worker. fourdgs_last_error() is thread-local, so two threads decoding two files
 * never overwrite each other's diagnosis.
 *
 * ---------------------------------------------------------------------------
 * TYPICAL USE
 *
 *     fourdgs_scene *scene = NULL;
 *     if (fourdgs_open_path("scene.4dgs", &scene) != FOURDGS_STATUS_OK) {
 *         fprintf(stderr, "%s\n", fourdgs_last_error());
 *         return 1;
 *     }
 *
 *     fourdgs_state *state = NULL;
 *     if (fourdgs_scene_state_at(scene, 1.5, 3, &state) == FOURDGS_STATUS_OK) {
 *         const uint32_t *indices = fourdgs_state_indices(state);
 *         const float *centers = fourdgs_state_centers(state);
 *         const float *orientations = fourdgs_state_orientations(state);
 *         const float *opacity = fourdgs_state_opacity(state);
 *         const float *scales = fourdgs_scene_scales(scene);
 *         for (uint32_t i = 0; i < fourdgs_state_count(state); ++i) {
 *             uint32_t g = indices[i];
 *             // centers[3*i ..], orientations[4*i ..], opacity[i], scales[3*g ..]
 *         }
 *         fourdgs_state_free(state);
 *     }
 *     fourdgs_scene_free(scene);
 */

#ifndef FOURDGS_H
#define FOURDGS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -------------------------------------------------------------------------
 * Status
 * ------------------------------------------------------------------------- */

/**
 * Outcome of a call. Distinguishing these matters because the fix differs: an
 * unsupported version needs a newer reader, an unsupported codec needs a different build,
 * and a malformed file needs a different file.
 */
typedef enum fourdgs_status {
    FOURDGS_STATUS_OK = 0,
    /** A null or otherwise unusable argument. Nothing was read. */
    FOURDGS_STATUS_INVALID_ARGUMENT = 1,
    /** Not a 4dgs file, or a major version this build does not implement. */
    FOURDGS_STATUS_UNSUPPORTED_VERSION = 2,
    /** The file ended, or a length ran past the end of its container. */
    FOURDGS_STATUS_TRUNCATED = 3,
    /** Structurally invalid: a required record missing, an index out of range. */
    FOURDGS_STATUS_MALFORMED = 4,
    /** A legal but unimplemented codec. The file is fine; this build cannot read it. */
    FOURDGS_STATUS_UNSUPPORTED_CODEC = 5,
    /** The transport failed. */
    FOURDGS_STATUS_IO = 6,
    /** An index or range argument was outside what the scene holds. */
    FOURDGS_STATUS_OUT_OF_RANGE = 7,
    /** A defect inside the decoder, caught at the boundary. Please report it. */
    FOURDGS_STATUS_INTERNAL = 8,
    /**
     * A legal request on the wrong read path — asking a sequential reader for one chunk
     * by index, for instance. Neither the file nor the call is malformed; the operation
     * belongs to the other path, and a caller that meets this should skip rather than fail.
     */
    FOURDGS_STATUS_UNSUPPORTED_MODE = 9
} fourdgs_status;

/**
 * The last error message on this thread, NUL-terminated, never null.
 *
 * Borrowed: valid until the next call on this thread that fails. Empty when nothing on
 * this thread has failed yet.
 */
const char *fourdgs_last_error(void);

/**
 * The identifier the specification's refusal table gives the last error on this thread —
 * "magic-mismatch", "unsupported-major-version", "unknown-temporal-model",
 * "unknown-quantization-scheme", "non-positive-step-time", "unknown-stream-codec",
 * "window-index-out-of-range" — or NULL with *out_len 0 when the last error is not one of
 * them.
 *
 * The status codes say what KIND of thing went wrong, and FOURDGS_STATUS_UNSUPPORTED_CODEC
 * alone covers three of those seven. This is how a caller says WHICH one, in the same words
 * every other implementation of this format uses.
 *
 * NULL is not a failure. A truncated transport, an I/O error and a null-argument mistake
 * are real errors that the refusal table does not name; the call still returns
 * FOURDGS_STATUS_OK and the sentence is in fourdgs_last_error().
 *
 * NOT NUL-terminated — read exactly *out_len bytes, and see CALL FIRST, THEN READ THE OUT
 * PARAMETERS above. The bytes are static and outlive any scene, so nothing frees them;
 * which identifier they spell changes with the next call on this thread that fails.
 *
 * A null out parameter returns FOURDGS_STATUS_INVALID_ARGUMENT and, alone on this surface,
 * leaves fourdgs_last_error() untouched rather than overwriting the diagnosis being read.
 */
int fourdgs_last_refusal_code(const char **out, size_t *out_len);

/**
 * The byte attached to the last failure on this thread, when the operation can place it.
 *
 * Absence is not an error: `*out_has_offset` is 0 and `*out_offset` is 0. Like
 * fourdgs_last_refusal_code, null out parameters return INVALID_ARGUMENT without overwriting
 * the diagnosis being queried.
 */
int fourdgs_last_error_offset(uint64_t *out_offset, int *out_has_offset);

/** A short static name for a status code. Never null; valid forever. */
const char *fourdgs_status_message(int status);

/** The format major version this build implements. */
uint32_t fourdgs_format_version(void);

/* -------------------------------------------------------------------------
 * Transports
 * ------------------------------------------------------------------------- */

/**
 * A byte-range source supplied by the caller: the one abstraction the decoder needs.
 *
 * This is what lets the same decoder run over a file, an HTTP range reader, a cache or a
 * memory buffer without any of them being compiled into the library.
 */
typedef struct fourdgs_reader {
    /** Passed back to every callback. May be null if the callbacks do not need it. */
    void *ctx;

    /** Write the resource's total size to *out_size. Return FOURDGS_STATUS_OK on success. */
    int (*size)(void *ctx, uint64_t *out_size);

    /**
     * Write exactly `length` bytes at `offset` into `out`, which has room for them.
     *
     * Returning FOURDGS_STATUS_OK after a short read is the one behaviour that breaks
     * every caller: report the failure instead. A server that answers 200 to a range
     * request is a failure, not something to slice client-side.
     */
    int (*read)(void *ctx, uint64_t offset, uint64_t length, uint8_t *out);

    /** Called exactly once, when the scene is freed. May be null. */
    void (*release)(void *ctx);
} fourdgs_reader;

/* -------------------------------------------------------------------------
 * Scene
 * ------------------------------------------------------------------------- */

/** An opened scene. Free with fourdgs_scene_free. */
typedef struct fourdgs_scene fourdgs_scene;

/** Reconstructed state at one instant. Free with fourdgs_state_free. */
typedef struct fourdgs_state fourdgs_state;

/**
 * Open a scene from bytes. The bytes are copied, so the caller's buffer may be released
 * as soon as this returns.
 */
int fourdgs_open_memory(const uint8_t *data, size_t length, fourdgs_scene **out);

/** Open a scene from a filesystem path: NUL-terminated and UTF-8. */
int fourdgs_open_path(const char *path, fourdgs_scene **out);

/**
 * Open a scene over a caller-supplied byte-range source.
 *
 * The scene takes ownership of `reader.ctx` and calls `reader.release` once, when the
 * scene is freed — including when this call itself fails.
 */
int fourdgs_open_reader(fourdgs_reader reader, fourdgs_scene **out);

/**
 * Which read path to open on.
 *
 * `AUTO` is the convenient answer and the wrong one for a conformance suite: two runners
 * that both take whichever path AUTO picked test one path twice, and the whole reason there
 * are two is that the paths may differ in everything except what they decode a file to
 * mean. Force the path when you are proving one.
 */
typedef enum fourdgs_open_mode {
    /** Indexed when the file has a usable index, front-to-back otherwise. */
    FOURDGS_OPEN_AUTO = 0,
    /** Front to back, whatever the file carries. Truncation recovery lives here. */
    FOURDGS_OPEN_SEQUENTIAL = 1,
    /**
     * The indexed path. A file with no index still opens — it simply has an empty index
     * and nothing to seek to, which is a property of that file rather than a failure.
     */
    FOURDGS_OPEN_INDEXED = 2
} fourdgs_open_mode;

/** As fourdgs_open_memory, on a chosen read path. */
int fourdgs_open_memory_ex(const uint8_t *data, size_t length, int mode,
                           fourdgs_scene **out);

/** As fourdgs_open_path, on a chosen read path. */
int fourdgs_open_path_ex(const char *path, int mode, fourdgs_scene **out);

/**
 * As fourdgs_open_reader, on a chosen read path. Ownership of `reader.ctx` transfers
 * identically, including when this call fails.
 */
int fourdgs_open_reader_ex(fourdgs_reader reader, int mode, fourdgs_scene **out);

/**
 * Called once for every lifetime gaussian identity introduced by keyframe-delta payloads.
 * `record_offset` is the byte offset of the keyframe or delta record that introduces `id`.
 */
typedef int (*fourdgs_identity_sink)(void *ctx, uint64_t record_offset, uint32_t id);

/**
 * Validate every keyframe-delta payload through one concrete read path over a range source.
 *
 * `mode` is FOURDGS_OPEN_SEQUENTIAL or FOURDGS_OPEN_INDEXED; AUTO is deliberately rejected so
 * a validator states which path it certified. The core retains at most the current population
 * and its GOP keyframe. It calls `identity` once per lifetime introduction with the introducing
 * keyframe or delta record's byte offset, allowing the caller to prove uniqueness and compare
 * the resulting distinct count with
 * `*out_declared_gaussian_count` using bounded scratch storage at its I/O edge.
 *
 * Ownership of `reader.ctx` transfers to this call and `reader.release` is called exactly once,
 * including on failure. The identity context remains caller-owned. On failure the count output is
 * untouched; fourdgs_last_error, fourdgs_last_refusal_code, and fourdgs_last_error_offset carry
 * the diagnosis.
 */
int fourdgs_validate_keyframe_delta_reader(fourdgs_reader reader, int mode,
                                           void *identity_ctx,
                                           fourdgs_identity_sink identity,
                                           uint64_t *out_declared_gaussian_count);

/**
 * Release a scene and invalidate every pointer borrowed from it. Null is ignored.
 *
 * Any fourdgs_state obtained from this scene remains valid and must still be freed, but
 * its indices no longer refer to anything.
 */
void fourdgs_scene_free(fourdgs_scene *scene);

/* --- Header ------------------------------------------------------------- */

/** Scene length in seconds; playback covers [0, duration). 0 when `scene` is null. */
double fourdgs_scene_duration_sec(const fourdgs_scene *scene);

/**
 * The Header's marginal visibility threshold.
 *
 * Not decoration: it sets the support constant the per-gaussian velocity grid is derived
 * from, and the decoder reads it from the file rather than assuming the 0.05 default.
 */
double fourdgs_scene_cutoff(const fourdgs_scene *scene);

/** Total gaussians the Header declares, across all chunks. */
uint64_t fourdgs_scene_gaussian_count(const fourdgs_scene *scene);

/** Spherical harmonic degree, 0 to 3. 0 means the scene carries none. */
uint8_t fourdgs_scene_sh_degree(const fourdgs_scene *scene);

/** 1 when the file was opened on the indexed path, 0 when it is read front to back. */
int fourdgs_scene_is_indexed(const fourdgs_scene *scene);

/** Chunk index entries. 0 for a file with no index, which must be read sequentially. */
uint32_t fourdgs_scene_chunk_count(const fourdgs_scene *scene);

/**
 * The interval [t0, t1) of chunk `i`. Either out parameter may be null.
 *
 * Returns FOURDGS_STATUS_OUT_OF_RANGE when `i` is past the index.
 */
int fourdgs_scene_chunk_interval(const fourdgs_scene *scene, uint32_t i,
                                 double *out_t0, double *out_t1);

/**
 * A conservative upper bound on a cold seek to `t`, with spherical harmonics capped at
 * `max_sh_band`, so a caller can budget before asking. It includes every Object Track
 * that the chunks could reference; actual transfer may be lower after membership is
 * decoded or track validation is cached.
 *
 * Seek efficiency is a property of the content, not of the container: a scene whose
 * gaussians all live for the whole clip has one chunk covering everything, and this will
 * say so.
 */
uint64_t fourdgs_scene_bytes_for_time(const fourdgs_scene *scene, double t,
                                      uint8_t max_sh_band);

/* --- Audio sources ------------------------------------------------------ */

/**
 * One independently timed encoded payload and its scene-space pose.
 *
 * String fields are pointer/length pairs and may contain NUL. They and this descriptor's
 * other borrowed pointers remain valid until the scene is freed. `data_size` describes
 * the encoded payload; fetching a descriptor never transfers those bytes.
 */
typedef struct fourdgs_audio_source {
    uint32_t source_id;
    const char *name;
    size_t name_length;
    const char *codec;
    size_t codec_length;
    const char *channel_layout;
    size_t channel_layout_length;
    double start_sec;
    double duration_sec;
    double gain;
    int spatial;
    int loop_playback;
    double position[3];
    /** Unit quaternion in xyzw order. */
    double rotation[4];
    uint32_t keyframe_count;
    const char *interpolation;
    size_t interpolation_length;
    uint64_t data_size;
} fourdgs_audio_source;

typedef struct fourdgs_audio_source_keyframe {
    /** Scene time in seconds. */
    double time;
    double position[3];
    /** Unit quaternion in xyzw order. */
    double rotation[4];
} fourdgs_audio_source_keyframe;

/**
 * Format reconstruction for one source at scene time t.
 *
 * The player combines this with its own listener pose and chooses HRTF/panning, distance
 * attenuation, occlusion and mixing. Those playback policies are intentionally not
 * format state.
 */
typedef struct fourdgs_audio_source_state {
    int active;
    double local_time;
    double position[3];
    double rotation[4];
    double gain;
} fourdgs_audio_source_state;

/**
 * Whether the scene has one or more audio sources.
 *
 * Answered from the Header alone — no probing, no speculative range request. A scene
 * without audio carries no audio record at all, and that is a normal, complete file.
 */
int fourdgs_scene_has_audio(const fourdgs_scene *scene);

/** Number of independently timed sources. */
uint32_t fourdgs_scene_audio_source_count(const fourdgs_scene *scene);

/**
 * Fetch source `index` without transferring its encoded payload.
 *
 * Sources are ordered by source_id. Returns FOURDGS_STATUS_OUT_OF_RANGE for an invalid
 * index.
 */
int fourdgs_scene_audio_source(fourdgs_scene *scene, uint32_t index,
                               fourdgs_audio_source *out);

/** Fetch one pose keyframe from a moving source. */
int fourdgs_scene_audio_source_keyframe(fourdgs_scene *scene, uint32_t source_index,
                                        uint32_t keyframe_index,
                                        fourdgs_audio_source_keyframe *out);

/** Reconstruct source timing and pose at scene time `t`. */
int fourdgs_scene_audio_source_state_at(fourdgs_scene *scene, uint32_t source_index,
                                        double t, fourdgs_audio_source_state *out);

/**
 * Copy a range of source `index`'s encoded payload into `out`.
 *
 * Offsets are relative to that payload. Only the requested range is transferred.
 */
int fourdgs_scene_audio_source_read(fourdgs_scene *scene, uint32_t index,
                                    uint64_t offset, uint64_t length, uint8_t *out);

/**
 * The first source's codec, retained for compatibility with the pre-spatial ABI.
 *
 * Borrowed: valid until the scene is freed.
 */
const char *fourdgs_scene_audio_codec(fourdgs_scene *scene);

/** The first source's payload length, retained for compatibility. */
uint64_t fourdgs_scene_audio_size(const fourdgs_scene *scene);

/**
 * Copy bytes from the first source, retained for compatibility.
 *
 * Offsets are relative to the track, not to the file, and the read touches only those
 * bytes — the audio can be streamed independently of any gaussian data, or skipped
 * entirely. `out` must have room for `length` bytes.
 */
int fourdgs_scene_audio_read(fourdgs_scene *scene, uint64_t offset, uint64_t length,
                             uint8_t *out);

/* --- The resident gaussians --------------------------------------------- */

/*
 * A scene has a working set: the gaussians currently decoded. fourdgs_scene_load_all
 * fills it with every chunk; fourdgs_scene_load_at fills it with only the chunks the seek
 * rule names for one instant. Every array below is sized from
 * fourdgs_scene_loaded_count() and is invalidated by the next load on the same scene.
 *
 * All of them return null when the working set is empty, which is a normal state before
 * the first load and for a scene with no gaussians.
 */

/** Decode every chunk into the working set. */
int fourdgs_scene_load_all(fourdgs_scene *scene, uint8_t max_sh_band);

/**
 * Decode only the chunks covering `t` into the working set.
 *
 * The seek rule is the whole algorithm: every chunk index entry whose [t0, t1) contains t.
 */
int fourdgs_scene_load_at(fourdgs_scene *scene, double t, uint8_t max_sh_band);

/** How many gaussians are resident. Every array below is sized from this. */
uint32_t fourdgs_scene_loaded_count(const fourdgs_scene *scene);

/** Rest positions, 3 floats per resident gaussian. */
const float *fourdgs_scene_positions(const fourdgs_scene *scene);

/** Gaussian scales, linear, 3 floats per resident gaussian. */
const float *fourdgs_scene_scales(const fourdgs_scene *scene);

/** Unit quaternions, xyzw, 4 floats per resident gaussian. */
const float *fourdgs_scene_rotations(const fourdgs_scene *scene);

/** Linear RGB and opacity, each in [0, 1], 4 floats per resident gaussian. */
const float *fourdgs_scene_colors(const fourdgs_scene *scene);

/** Linear velocity in units per second, 3 floats per resident gaussian. */
const float *fourdgs_scene_motions(const fourdgs_scene *scene);

/** Temporal centre in seconds, 1 float per resident gaussian. */
const float *fourdgs_scene_mu_t(const fourdgs_scene *scene);

/**
 * Temporal standard deviation in seconds, 1 float per resident gaussian.
 *
 * Positive infinity means the gaussian never fades inside its window. That is a value,
 * not a sentinel: it survives encode and decode as infinity and should be surfaced as
 * such rather than pattern-matched into something else.
 */
const float *fourdgs_scene_sigma_t(const fourdgs_scene *scene);

/** Validity window start in seconds, 1 float per resident gaussian. */
const float *fourdgs_scene_win_lo(const fourdgs_scene *scene);

/**
 * Validity window end in seconds, 1 float per resident gaussian.
 *
 * The validity window is the format's only hard temporal gate: a gaussian outside it does
 * not exist at that time, whatever its marginal.
 */
const float *fourdgs_scene_win_hi(const fourdgs_scene *scene);

/**
 * Spherical harmonic coefficients, or null when the scene carries none.
 *
 * 3 * fourdgs_scene_sh_coefficients() bytes per resident gaussian, component-major: every
 * coefficient of red, then of green, then of blue.
 *
 * The stored byte is the coefficient. The Quantization record's step_sh describes what
 * the encoder did before storing them and is NOT applied at decode; multiplying by it
 * scales appearance by a factor of one to three and is the most likely way to misread it.
 */
const uint8_t *fourdgs_scene_sh(const fourdgs_scene *scene);

/**
 * Coefficients per colour component in the working set, so an `sh` row is three times
 * this wide. 0 when the scene carries none.
 *
 * Bands are whole: capping `max_sh_band` at load time yields a lower degree, never a
 * partial one.
 */
uint32_t fourdgs_scene_sh_coefficients(const fourdgs_scene *scene);

/* --- State at an instant ------------------------------------------------- */

/**
 * Reconstruct the state at scene time `t`, loading the chunks that instant needs.
 *
 * This is where decoding ends. For each gaussian, with the file's own cutoff:
 *
 *     visible  =  win_lo <= t < win_hi  AND  marginal >= cutoff
 *     marginal =  sigma_t == +inf ? 1 : exp(-0.5 * ((t - mu_t) / sigma_t)^2)
 *     center   =  position + motion * (t - mu_t)
 *     orientation = rotation
 *     opacity  =  color.a * marginal
 *
 * The result is owned by the caller and freed with fourdgs_state_free. Its indices refer
 * to the scene's resident arrays, which this call has just populated — so read the state
 * and the arrays together, before the next load.
 */
int fourdgs_scene_state_at(fourdgs_scene *scene, double t, uint8_t max_sh_band,
                           fourdgs_state **out);

/** Release a state. Null is ignored. */
void fourdgs_state_free(fourdgs_state *state);

/** How many gaussians exist at that instant. */
uint32_t fourdgs_state_count(const fourdgs_state *state);

/**
 * Indices into the scene's resident arrays, one per visible gaussian.
 *
 * Borrowed: valid until the state is freed. Null when nothing is visible.
 */
const uint32_t *fourdgs_state_indices(const fourdgs_state *state);

/**
 * position + motion * (t - mu_t), 3 floats per visible gaussian, packed by visible index
 * rather than by gaussian index.
 *
 * Borrowed: valid until the state is freed. Null when nothing is visible.
 */
const float *fourdgs_state_centers(const fourdgs_state *state);

/**
 * Reconstructed orientation, 4 xyzw floats per visible gaussian, packed by visible index.
 * Object tracks are composed onto the base rotation.
 *
 * Borrowed: valid until the state is freed. Null when nothing is visible.
 */
const float *fourdgs_state_orientations(const fourdgs_state *state);

/**
 * color.a * marginal, 1 float per visible gaussian, packed by visible index.
 *
 * Borrowed: valid until the state is freed. Null when nothing is visible.
 */
const float *fourdgs_state_opacity(const fourdgs_state *state);

/* -------------------------------------------------------------------------
 * The rest of the file
 *
 * A scene is more than its gaussians, and a consumer that can only report the gaussians
 * cannot state what it read. Everything below is what the file says about itself.
 *
 * Strings here are (pointer, length) and borrowed until the scene is freed. Accessors
 * taking a non-const `fourdgs_scene *` may perform I/O on first use, because the records
 * behind them live at byte ranges an indexed open deliberately did not read.
 * ------------------------------------------------------------------------- */

/** The Header's `temporal_model`: "gaussian-birth" for version 1. */
int fourdgs_scene_temporal_model(const fourdgs_scene *scene, const char **out,
                                 size_t *out_length);

/** The Header's `profile`: a promise about the file's shape, or empty for none. */
int fourdgs_scene_profile(const fourdgs_scene *scene, const char **out, size_t *out_length);

/** The Header's `library`: free-form producer identification. */
int fourdgs_scene_library(const fourdgs_scene *scene, const char **out, size_t *out_length);

/** Key/value pairs in the Header's attributes map. */
uint32_t fourdgs_scene_attribute_count(const fourdgs_scene *scene);

/** Attribute `i`, in sorted key order. */
int fourdgs_scene_attribute_at(const fourdgs_scene *scene, uint32_t i,
                               const char **out_key, size_t *out_key_length,
                               const char **out_value, size_t *out_value_length);

/**
 * Fetch the Camera, Metadata and Attachment records.
 *
 * Opening a file frames these and stops, so a camera nobody asked for costs nothing. Every
 * accessor below calls this implicitly; calling it directly is how you find out whether
 * those records are readable at all, rather than discovering it one accessor at a time.
 */
int fourdgs_scene_load_records(fourdgs_scene *scene);

/** Metadata records the file carries. Known at open from the ranges: no I/O. */
uint32_t fourdgs_scene_metadata_count(const fourdgs_scene *scene);

/** The name of Metadata record `i`. */
int fourdgs_scene_metadata_name(fourdgs_scene *scene, uint32_t i, const char **out,
                                size_t *out_length);

/** Entries in Metadata record `i`, or 0 when `i` is out of range. */
uint32_t fourdgs_scene_metadata_entry_count(fourdgs_scene *scene, uint32_t i);

/** Entry `j` of Metadata record `i`, in sorted key order. */
int fourdgs_scene_metadata_entry_at(fourdgs_scene *scene, uint32_t i, uint32_t j,
                                    const char **out_key, size_t *out_key_length,
                                    const char **out_value, size_t *out_value_length);

/** Attachment records the file carries. Known at open from the ranges: no I/O. */
uint32_t fourdgs_scene_attachment_count(const fourdgs_scene *scene);

/** The name of attachment `i`. */
int fourdgs_scene_attachment_name(fourdgs_scene *scene, uint32_t i, const char **out,
                                  size_t *out_length);

/** The media type of attachment `i`. */
int fourdgs_scene_attachment_media_type(fourdgs_scene *scene, uint32_t i, const char **out,
                                        size_t *out_length);

/** The payload length of attachment `i`, or 0 when `i` is out of range. */
uint64_t fourdgs_scene_attachment_size(fourdgs_scene *scene, uint32_t i);

/**
 * Copy `length` bytes of attachment `i` from `offset` into `out`.
 *
 * The bytes, not just their length: a decoder that reported the length and discarded the
 * payload would otherwise be indistinguishable from one that read it.
 */
int fourdgs_scene_attachment_read(fourdgs_scene *scene, uint32_t i, uint64_t offset,
                                  uint64_t length, uint8_t *out);

/** A default viewpoint and optional suggested path. Purely advisory. */
typedef struct fourdgs_camera {
    double fov_y_deg;
    double position[3];
    double target[3];
    uint32_t keyframe_count;
    /** 0 or 1. */
    int loop_enabled;
    /** Registry name, "linear" or "spline". Borrowed; not NUL-terminated. */
    const char *interpolation;
    size_t interpolation_length;
} fourdgs_camera;

/** Whether the file carries a Camera record. Known at open from the ranges: no I/O. */
int fourdgs_scene_has_camera(const fourdgs_scene *scene);

/** The camera's own fields. FOURDGS_STATUS_OUT_OF_RANGE when the file carries none. */
int fourdgs_scene_camera(fourdgs_scene *scene, fourdgs_camera *out);

/**
 * Keyframe `i` of the suggested path. Any out parameter may be null; `out_position` and
 * `out_target` must have room for three doubles each.
 */
int fourdgs_scene_camera_keyframe(fourdgs_scene *scene, uint32_t i, double *out_time,
                                  double *out_position, double *out_target);

/** Whether the file carries a Statistics record. */
int fourdgs_scene_has_statistics(const fourdgs_scene *scene);

/**
 * The Statistics record's fields. Advisory — a reader that needs certainty computes from
 * the chunks. Any out parameter may be null; `out_aabb` must have room for six doubles.
 */
int fourdgs_scene_statistics(const fourdgs_scene *scene, uint64_t *out_gaussian_count,
                             uint32_t *out_chunk_count, double *out_duration_sec,
                             double *out_aabb);

/** Summary Offset records the file carries. */
uint32_t fourdgs_scene_summary_offset_count(const fourdgs_scene *scene);

/** Summary Offset `i`. Any out parameter may be null. */
int fourdgs_scene_summary_offset_at(const fourdgs_scene *scene, uint32_t i,
                                    uint8_t *out_group_opcode, uint64_t *out_group_start,
                                    uint64_t *out_group_length);

/**
 * The three states the summary CRC can be in.
 *
 * Three, not two: "not checked" and "did not match" are different claims about a file, and
 * collapsing them reports corruption nobody observed. A mismatch means the index is
 * untrustworthy — it does not implicate the chunks, and a front-to-back read is the correct
 * recovery rather than a refusal.
 */
typedef enum fourdgs_crc_state {
    FOURDGS_CRC_NOT_CHECKED = -1,
    FOURDGS_CRC_FAILED = 0,
    FOURDGS_CRC_VERIFIED = 1
} fourdgs_crc_state;

/** Which of the three the summary CRC is. */
int fourdgs_scene_summary_crc_state(const fourdgs_scene *scene);

/**
 * Whether the file ended inside a record, with everything complete before the cut still
 * decoded. Always 0 on the indexed path, which requires a complete file.
 *
 * A file cut short mid-write is common and recoverable, and this is how a caller tells a
 * short scene from a complete one.
 */
int fourdgs_scene_truncated(const fourdgs_scene *scene);

/**
 * Decode exactly chunk `i` into the working set.
 *
 * fourdgs_scene_load_at cannot isolate a chunk when intervals overlap, and isolating one is
 * what a byte-budget check needs: load this chunk at this cap, then compare what your
 * transport moved against fourdgs_scene_bytes_for_chunk.
 *
 * FOURDGS_STATUS_UNSUPPORTED_MODE on a sequential reader, which has no index to fetch from
 * and has already decoded every chunk.
 */
int fourdgs_scene_load_chunk(fourdgs_scene *scene, uint32_t i, uint8_t max_sh_band);

/**
 * What reading chunk `i` at `max_sh_band` will transfer, from the index alone. 0 when `i`
 * is outside the index.
 */
uint64_t fourdgs_scene_bytes_for_chunk(const fourdgs_scene *scene, uint32_t i,
                                       uint8_t max_sh_band);

/* -------------------------------------------------------------------------
 * Encoding
 *
 * The decode surface above ends at gaussian state; this is the other direction. The C++
 * and Swift packages are bindings over the core rather than parallel encoders, so an
 * authoring surface for the native tier is these `fourdgs_writer_*` functions and a thin
 * shim per language — the same shape as the decode surface.
 *
 * The four rules hold unchanged. Encoding adds one owned type, fourdgs_buffer: the encoder
 * produces a whole file at once rather than streaming, and the caller owns those bytes
 * until it has written them somewhere. Free it with fourdgs_buffer_free.
 *
 * TYPICAL USE
 *
 *     fourdgs_writer *writer = fourdgs_writer_new();
 *     fourdgs_writer_set_duration(writer, 2.0);
 *     fourdgs_writer_set_gaussians(writer, count, positions, scales, rotations, colors,
 *                                  motions, mu_t, sigma_t, win_lo, win_hi);
 *
 *     fourdgs_buffer *out = NULL;
 *     if (fourdgs_writer_encode(writer, &out) == FOURDGS_STATUS_OK) {
 *         fwrite(fourdgs_buffer_data(out), 1, fourdgs_buffer_len(out), file);
 *         fourdgs_buffer_free(out);
 *     } else {
 *         fprintf(stderr, "%s\n", fourdgs_last_error());
 *     }
 *     fourdgs_writer_free(writer);
 * ------------------------------------------------------------------------- */

/** A scene being assembled for encoding. Free with fourdgs_writer_free. */
typedef struct fourdgs_writer fourdgs_writer;

/** An owned buffer of encoded bytes. Free with fourdgs_buffer_free. */
typedef struct fourdgs_buffer fourdgs_buffer;

/**
 * Create an empty writer with the encoder's default options, or null on allocation
 * failure — checked exactly as a failed open is.
 */
fourdgs_writer *fourdgs_writer_new(void);

/** Release a writer. Null is ignored. */
void fourdgs_writer_free(fourdgs_writer *writer);

/** Scene length in seconds; playback will cover [0, duration). */
int fourdgs_writer_set_duration(fourdgs_writer *writer, double duration_sec);

/**
 * The Header's marginal visibility threshold. It sets the support constant the per-gaussian
 * velocity grid is derived from, so it must be the one the decoder will read back.
 */
int fourdgs_writer_set_cutoff(fourdgs_writer *writer, double cutoff);

/**
 * The temporal partition's depth and the smallest chunk worth its own record. `max_depth`
 * of 0 writes one chunk per window.
 */
int fourdgs_writer_set_chunking(fourdgs_writer *writer, uint32_t max_depth,
                                size_t min_chunk_gaussians);

/**
 * Which parts of the summary the file carries. Each argument is a boolean: non-zero writes
 * that part. The index is what makes seeking work; the rest are advisory.
 */
int fourdgs_writer_set_summary(fourdgs_writer *writer, int write_index, int write_statistics,
                               int write_summary_offsets, int write_crc);

/** The highest spherical harmonic band to write, 0 to 3. Excess coefficients are dropped. */
int fourdgs_writer_set_sh_bands(fourdgs_writer *writer, uint8_t sh_bands);

/**
 * Per-band spherical harmonic bit depths, band 1 first. A null pointer or a zero count
 * clears the ladder, leaving the coefficients as the profile alone decides.
 */
int fourdgs_writer_set_sh_bit_depths(fourdgs_writer *writer, const uint8_t *depths,
                                     size_t count);

/**
 * The Header's `profile`. A (pointer, length) UTF-8 string, not NUL-terminated: the
 * format's `string` may legally contain a NUL.
 */
int fourdgs_writer_set_profile(fourdgs_writer *writer, const char *data, size_t length);

/** The Header's `library`. The same (pointer, length) UTF-8 convention as the profile. */
int fourdgs_writer_set_library(fourdgs_writer *writer, const char *data, size_t length);

/**
 * Add one key/value pair to the Header's attributes map. Both are (pointer, length) UTF-8
 * strings. A repeated key overwrites.
 */
int fourdgs_writer_add_attribute(fourdgs_writer *writer, const char *key, size_t key_length,
                                 const char *value, size_t value_length);

/**
 * Set every gaussian column at once, structure-of-arrays. The columns are copied, so the
 * caller's arrays may be released as soon as this returns.
 *
 * Widths are per gaussian: `positions`, `scales` and `motions` are three floats each,
 * `rotations` and `colors` four, and `mu_t`, `sigma_t`, `win_lo` and `win_hi` one. A null
 * column is FOURDGS_STATUS_INVALID_ARGUMENT unless `count` is zero. `sigma_t` may hold
 * positive infinity for a gaussian that never fades. Setting the columns clears any
 * harmonics previously attached — set the gaussians first, then the harmonics.
 */
int fourdgs_writer_set_gaussians(fourdgs_writer *writer, uint32_t count,
                                 const float *positions, const float *scales,
                                 const float *rotations, const float *colors,
                                 const float *motions, const float *mu_t,
                                 const float *sigma_t, const float *win_lo,
                                 const float *win_hi);

/**
 * Attach spherical harmonic coefficients to the gaussians already set.
 *
 * `coefficients` is the count per colour component, so a row is three times that wide and
 * the payload is `count * 3 * coefficients` bytes, component-major. A null payload, a zero
 * degree or a zero coefficient count clears the harmonics. A payload whose length does not
 * match the gaussians already set is FOURDGS_STATUS_MALFORMED. The payload is copied.
 */
int fourdgs_writer_set_sh(fourdgs_writer *writer, uint8_t degree, uint32_t coefficients,
                          const uint8_t *sh, size_t length);

/**
 * Encode the scene into an owned buffer.
 *
 * The encoder verifies its own bounds before returning — it decodes every chunk back and
 * refuses a file whose measured deviation exceeds what it declares — so a success is a file
 * whose Quantization record was checked on every gaussian. On failure the out parameter is
 * untouched and fourdgs_last_error names the reason.
 */
int fourdgs_writer_encode(fourdgs_writer *writer, fourdgs_buffer **out);

/** The encoded bytes, borrowed until the buffer is freed. Null for an empty buffer. */
const uint8_t *fourdgs_buffer_data(const fourdgs_buffer *buffer);

/** How many bytes the buffer holds. 0 for a null buffer. */
size_t fourdgs_buffer_len(const fourdgs_buffer *buffer);

/** Release an encoded buffer. Null is ignored. */
void fourdgs_buffer_free(fourdgs_buffer *buffer);

/* -------------------------------------------------------------------------
 * keyframe-delta
 *
 * The keyframe-delta temporal model (spec section 11) is a whole-file format, not a variant
 * of the gaussian-birth scene the accessors above read: an opened fourdgs_scene refuses a
 * temporal model this build's scene reader does not implement. These three functions bind it
 * additively. They take the whole file as bytes and return owned strings — the canonical
 * states summary is computed entirely in the Rust core, so every binding emits identical
 * bytes with no per-language arithmetic to drift.
 *
 * The returned string is NOT NUL-terminated — it carries its length, like every string read
 * out of a file — and it is OWNED by the caller: free it with fourdgs_string_free, passing
 * back the same pointer and length. The two-out-parameter sequencing rule at the top of this
 * header applies: read `out`/`out_len` only after the call has returned FOURDGS_STATUS_OK.
 * ------------------------------------------------------------------------- */

/**
 * The Header's declared temporal model, read from bytes without opening a scene.
 *
 * A binding dispatches on this: "keyframe-delta" goes to fourdgs_keyframe_delta_states_json,
 * anything else through the ordinary open. On success `out` owns a string freed with
 * fourdgs_string_free.
 */
int fourdgs_peek_temporal_model(const uint8_t *data, size_t length, const char **out,
                                size_t *out_len);

/**
 * Decode a keyframe-delta file and return its canonical states JSON.
 *
 * `indexed == 0` walks the file front to back, composing each chunk onto the last; a non-zero
 * `indexed` reads the index and walks only each instant's chain. The two must agree. On
 * success `out` owns a string freed with fourdgs_string_free. A file whose Header is not
 * keyframe-delta is reported FOURDGS_STATUS_UNSUPPORTED_CODEC on either path: it declares
 * a legal temporal model handled by a different reader, not a malformed file.
 */
int fourdgs_keyframe_delta_states_json(const uint8_t *data, size_t length, int indexed,
                                       const char **out, size_t *out_len);

/**
 * Canonical provenance JSON for the opened scene (spec §5.15), or an empty string when the
 * file carries none.
 *
 * The object shape matches the shared conformance summary: frames, anchors, sensors,
 * trajectories (with stored samples and `posesAt` probes), and `sensorPosesAt`. On the
 * indexed path the records are fetched here if not already resident; on the sequential path
 * they were read at open. An empty result is not an error — the binding should omit the
 * `provenance` key rather than emit null. On success `out` owns a string freed with
 * fourdgs_string_free. The two-out-parameter sequencing rule at the top of this header
 * applies.
 */
int fourdgs_scene_provenance_json(fourdgs_scene *scene, const char **out, size_t *out_len);

/**
 * The `objects` member of the canonical scene summary (spec 5.15.6-5.15.7): the Object
 * Table's entries and the SE(3) tracks with their `posesAt` probes.
 *
 * The composition is performed here so every binding shares one base-then-track order and
 * one slerp. An empty result is not an error — the binding should omit the key rather than
 * emit null. On success `out` owns a string freed with fourdgs_string_free. The
 * two-out-parameter sequencing rule at the top of this header applies.
 *
 * THIS CALL LOADS. The summary describes every gaussian, so it decodes the whole
 * population, and at the file's full SH degree rather than the caller's cap — the
 * canonical order keys the harmonics before `object_id`, so summarizing at a lower degree
 * would sort a legal file differently from the reference. The cap is restored before this
 * returns, so a caller that capped for memory keeps it, at the cost of a second decode.
 *
 * The working set is not restored. Treat this exactly like fourdgs_scene_load_all: every
 * pointer previously handed out by fourdgs_scene_positions and its siblings, including
 * fourdgs_scene_object_ids, is invalidated by it, and a caller that had seeked to an
 * instant holds the whole scene afterwards. Call it before taking the pointers, not
 * between taking them and reading them — the mistake this paragraph exists to prevent, and
 * a silent one on a scene already loaded whole, because then the load is a no-op.
 *
 * The companion `states` member comes from fourdgs_scene_object_states_json. They are two
 * calls because they are two root keys of the summary, sitting beside `sample` and
 * `aggregate` — returning one document would make every binding cut it apart.
 */
/**
 * Object membership, 1 unsigned integer per resident gaussian, or NULL when the scene
 * carries no `object_id` stream (spec 6.6).
 *
 * NULL and all-zero are different claims and both are legal: a file with no membership at
 * all, and a file where every gaussian is background. Borrowed until the next load.
 */
const uint32_t *fourdgs_scene_object_ids(const fourdgs_scene *scene);

int fourdgs_scene_objects_json(fourdgs_scene *scene, const char **out, size_t *out_len);

/**
 * The `states` member of the canonical scene summary: the composed centres, orientations
 * and membership at each scene-clock probe.
 *
 * Same contract as fourdgs_scene_objects_json in every other respect.
 */
int fourdgs_scene_object_states_json(fourdgs_scene *scene, const char **out, size_t *out_len);

/**
 * Release a string owned by the caller — the result of fourdgs_peek_temporal_model,
 * fourdgs_keyframe_delta_states_json, fourdgs_scene_provenance_json or
 * fourdgs_scene_objects_json. Null is ignored.
 * The length must be the one the producing call returned; the pair identifies the same
 * allocation.
 */
void fourdgs_string_free(const char *data, size_t length);

/* ---------------------------------------------------------------------------
 * Encoding a keyframe-delta file
 *
 * fourdgs_writer_* authors a gaussian-birth file — one population whose gaussians each
 * carry their own birth time — and there is no way through it to say what this model is
 * for: the same population, with identity, restated at a sequence of instants. So this is
 * a second writer handle rather than a mode on the first, for the same reason a Delta
 * Chunk is its own record and not a flag on Chunk (spec 5.18).
 *
 * The arithmetic stays in the core. A delta is a DIFFERENCE OF BINS, never a quantization
 * of a difference (spec 11.7), which holds only if every sample is quantized up front on
 * one set of grids derived from the whole sequence. So samples are accumulated by the
 * handle and encoded in one pass at the end: a binding that assembled deltas itself would
 * be a second encoder with its own rounding, and its files would not match the reference
 * byte for byte.
 *
 * Two counting rules follow from that and catch implementers reading only the record
 * layout: the Header's `gaussian_count` under this model is the number of DISTINCT ids
 * across the sequence, not a sum over chunks; and a delta's update count counts
 * OPERATIONS, not the population.
 *
 * The encoded buffer is the same owned fourdgs_buffer the gaussian-birth writer returns.
 *
 * TYPICAL USE
 *
 *     fourdgs_kd_writer *writer = fourdgs_kd_writer_new();
 *     fourdgs_kd_writer_set_duration(writer, 1.0);
 *     for (uint32_t i = 0; i < frames; i++)
 *         fourdgs_kd_writer_add_sample(writer, i / (double)frames, count, ids,
 *                                      positions, scales, rotations, colors,
 *                                      motions, mu_t, sigma_t, win_lo, win_hi);
 *
 *     fourdgs_buffer *out = NULL;
 *     if (fourdgs_kd_writer_encode(writer, &out) == FOURDGS_STATUS_OK) {
 *         fwrite(fourdgs_buffer_data(out), 1, fourdgs_buffer_len(out), file);
 *         fourdgs_buffer_free(out);
 *     } else {
 *         fprintf(stderr, "%s\n", fourdgs_last_error());
 *     }
 *     fourdgs_kd_writer_free(writer);
 * ------------------------------------------------------------------------- */

/** A sample sequence being assembled for encoding. Free with fourdgs_kd_writer_free. */
typedef struct fourdgs_kd_writer fourdgs_kd_writer;

/**
 * Create an empty keyframe-delta writer with the reference encoder's defaults — a keyframe
 * every 8 samples, chained deltas, the "default" bound profile, a 0.05 cutoff and deflate
 * at level 6 — or null on allocation failure.
 */
fourdgs_kd_writer *fourdgs_kd_writer_new(void);

/** Release a keyframe-delta writer. Null is ignored. */
void fourdgs_kd_writer_free(fourdgs_kd_writer *writer);

/**
 * Scene length in seconds. The last sample's interval ends here, so this is what closes
 * the tiling the model requires (spec 11.1) rather than a separate advisory field.
 */
int fourdgs_kd_writer_set_duration(fourdgs_kd_writer *writer, double duration_sec);

/** The Header's marginal visibility threshold, as on fourdgs_writer_set_cutoff. */
int fourdgs_kd_writer_set_cutoff(fourdgs_kd_writer *writer, double cutoff);

/**
 * Cadence and reference mode. `keyframe_every` is samples per group of pictures; 1 writes
 * every sample as a keyframe, which is legal. `delta_mode` is 0 for keyframe-referenced
 * and 1 for chained (spec 11.4) — any other value is FOURDGS_STATUS_INVALID_ARGUMENT
 * rather than a file no reader would accept.
 */
int fourdgs_kd_writer_set_cadence(fourdgs_kd_writer *writer, uint32_t keyframe_every,
                                  uint8_t delta_mode);

/**
 * Force a keyframe at one sample index, beyond whatever the cadence would place. Call once
 * per index; order does not matter and a repeat is harmless.
 */
int fourdgs_kd_writer_add_keyframe_at(fourdgs_kd_writer *writer, uint32_t sample_index);

/**
 * The bound profile the whole sequence is quantized against, and the Header's `profile`:
 * "fine", "default" or "coarse". A (pointer, length) UTF-8 string. Unlike the
 * gaussian-birth writer, where the Header's `profile` is a free-form promise separate from
 * the bounds, these are one value under this model — the grids come from it.
 */
int fourdgs_kd_writer_set_profile(fourdgs_kd_writer *writer, const char *data, size_t length);

/** The Header's `library`. Same string convention. */
int fourdgs_kd_writer_set_library(fourdgs_kd_writer *writer, const char *data, size_t length);

/** The stream codec and its level, applied to every chunk's block. Default: deflate at 6. */
int fourdgs_kd_writer_set_compression(fourdgs_kd_writer *writer, uint8_t codec, uint32_t level);

/**
 * Append one sample: a population, at one instant, with identity.
 *
 * `ids` is aligned with the gaussian columns and is what a delta names them by (spec 11.2).
 * It is required rather than derived from row order, because the model rests on
 * correspondence between samples and row order asserts none.
 *
 * The columns are copied. Widths are per gaussian, exactly as
 * fourdgs_writer_set_gaussians: `positions`, `scales` and `motions` are three floats each,
 * `rotations` and `colors` four, and `mu_t`, `sigma_t`, `win_lo` and `win_hi` one. A null
 * column — or a null `ids` — is an error unless `count` is zero.
 *
 * Samples are appended in time order and must tile the timeline: sample i covers
 * [t0_i, t0_{i+1}), the first starts at 0 and the last ends at the duration (spec 11.1).
 * The encoder derives each t1 from the next sample's t0; at encode time it refuses a
 * non-finite or out-of-order start, a first start other than 0, or a final start after the
 * duration. A zero-width interval is accepted only for an empty sample; a populated one
 * would be unreachable under the half-open seek rule. The failure is
 * FOURDGS_STATUS_INVALID_ARGUMENT, and fourdgs_last_error() names the sample and the
 * expected time relationship.
 *
 * Every sigma_t must be finite. The format allows +inf for a gaussian that never fades and
 * this reference encoder does not write one; a non-finite value is refused at encode.
 *
 * Spherical harmonics are not carried; a file written here declares sh_degree 0.
 */
int fourdgs_kd_writer_add_sample(fourdgs_kd_writer *writer, double t0, uint32_t count,
                                 const uint32_t *ids, const float *positions,
                                 const float *scales, const float *rotations,
                                 const float *colors, const float *motions, const float *mu_t,
                                 const float *sigma_t, const float *win_lo,
                                 const float *win_hi);

/** How many samples have been appended. 0 for a null writer. */
uint32_t fourdgs_kd_writer_sample_count(const fourdgs_kd_writer *writer);

/**
 * Encode the appended sequence into an owned buffer, freed with fourdgs_buffer_free.
 *
 * On failure `out` is untouched and fourdgs_last_error names the reason: an empty
 * sequence, a sample whose id count does not match its gaussian count, sample times that
 * do not tile the duration, a non-finite sigma_t, or a gaussian whose sigma_t or window
 * changes inside a group — the last refused rather than written, because those values ARE
 * the grid a bin difference is taken on (spec 11.5) and a file carrying one decodes
 * silently into a wrong velocity.
 */
int fourdgs_kd_writer_encode(fourdgs_kd_writer *writer, fourdgs_buffer **out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* FOURDGS_H */
