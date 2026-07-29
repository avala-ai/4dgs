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
    FOURDGS_STATUS_INTERNAL = 8
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

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* FOURDGS_H */
