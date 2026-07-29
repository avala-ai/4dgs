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
 *         const float *opacity = fourdgs_state_opacity(state);
 *         const float *scales = fourdgs_scene_scales(scene);
 *         const float *rotations = fourdgs_scene_rotations(scene);
 *         for (uint32_t i = 0; i < fourdgs_state_count(state); ++i) {
 *             uint32_t g = indices[i];
 *             // centers[3*i .. 3*i+2], opacity[i], scales[3*g .. ], rotations[4*g .. ]
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
 * What a seek to `t` will transfer with spherical harmonics capped at `max_sh_band`, so a
 * caller can budget before asking.
 *
 * Seek efficiency is a property of the content, not of the container: a scene whose
 * gaussians all live for the whole clip has one chunk covering everything, and this will
 * say so.
 */
uint64_t fourdgs_scene_bytes_for_time(const fourdgs_scene *scene, double t,
                                      uint8_t max_sh_band);

/* --- Audio -------------------------------------------------------------- */

/**
 * Whether the scene has a soundtrack.
 *
 * Answered from the Header alone — no probing, no speculative range request. A scene
 * without audio carries no audio record at all, and that is a normal, complete file.
 */
int fourdgs_scene_has_audio(const fourdgs_scene *scene);

/**
 * The audio codec's registry name ("wav", "opus", ...), or null when there is no track.
 *
 * Borrowed: valid until the scene is freed.
 */
const char *fourdgs_scene_audio_codec(fourdgs_scene *scene);

/** The track's length in bytes, computed without fetching it. 0 when there is no track. */
uint64_t fourdgs_scene_audio_size(const fourdgs_scene *scene);

/**
 * Copy `length` bytes of the track from `offset` into `out`.
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

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* FOURDGS_H */
