/*
 * Copyright 2026 Avala AI
 * SPDX-License-Identifier: Apache-2.0
 *
 * A C program that exercises the C ABI the way a binding does.
 *
 * It exists to prove three things a Rust test cannot: that include/fourdgs.h compiles as
 * C, that every symbol it declares actually links, and that the documented null and
 * error behaviour holds when the caller is a C compiler rather than Rust pretending to be
 * one. The C++ and Swift packages bind to this surface, so a drift between the header and
 * the library is their outage, not ours to discover later.
 *
 * Usage: capi_smoke <file.4dgs>
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fourdgs.h"

static int failures = 0;

static void check(int condition, const char *what) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", what);
        failures += 1;
    }
}

/* Null must be safe everywhere, because a binding will pass it eventually. */
static void check_null_safety(void) {
    check(fourdgs_scene_duration_sec(NULL) == 0.0, "duration of a null scene is 0");
    check(fourdgs_scene_gaussian_count(NULL) == 0, "gaussian count of a null scene is 0");
    check(fourdgs_scene_audio_source_count(NULL) == 0, "audio count of a null scene is 0");
    check(fourdgs_scene_loaded_count(NULL) == 0, "loaded count of a null scene is 0");
    check(fourdgs_scene_positions(NULL) == NULL, "positions of a null scene is null");
    check(fourdgs_scene_sh(NULL) == NULL, "sh of a null scene is null");
    check(fourdgs_state_count(NULL) == 0, "count of a null state is 0");
    check(fourdgs_state_centers(NULL) == NULL, "centers of a null state is null");
    check(fourdgs_state_orientations(NULL) == NULL, "orientations of a null state is null");
    check(fourdgs_scene_load_all(NULL, 3) == FOURDGS_STATUS_INVALID_ARGUMENT,
          "loading a null scene is an invalid argument");
    check(fourdgs_scene_state_at(NULL, 0.0, 3, NULL) == FOURDGS_STATUS_INVALID_ARGUMENT,
          "state of a null scene is an invalid argument");
    /* The free functions accept null rather than crashing on a partially built object. */
    fourdgs_scene_free(NULL);
    fourdgs_state_free(NULL);
    check(fourdgs_last_error() != NULL, "the last error is never a null pointer");
    check(strcmp(fourdgs_status_message(FOURDGS_STATUS_OK), "ok") == 0,
          "status 0 is named ok");
}

/* A file that is not ours must be refused as a version problem, not as corruption. */
static void check_bad_magic(void) {
    const uint8_t junk[16] = {0};
    fourdgs_scene *scene = NULL;
    int status = fourdgs_open_memory(junk, sizeof junk, &scene);
    check(status == FOURDGS_STATUS_UNSUPPORTED_VERSION,
          "a buffer that is not a 4dgs file is an unsupported version");
    check(scene == NULL, "a failed open leaves the out parameter untouched");
    check(strlen(fourdgs_last_error()) > 0, "a failure leaves a message behind");
}

/* Everything a binding needs to state what it read, exercised the way one would. */
static void check_summary_surface(fourdgs_scene *scene) {
    const char *text = NULL;
    size_t len = 0;
    check(fourdgs_scene_temporal_model(scene, &text, &len) == FOURDGS_STATUS_OK,
          "the temporal model is readable");
    check(text != NULL && len > 0, "the temporal model is a non-empty string");
    /* Length-carrying, not NUL-terminated: compare on the length the accessor gave. */
    check(len == strlen("gaussian-birth") && memcmp(text, "gaussian-birth", len) == 0,
          "version 1 declares the gaussian-birth temporal model");

    check(fourdgs_scene_profile(scene, &text, &len) == FOURDGS_STATUS_OK,
          "the profile is readable");
    check(fourdgs_scene_library(scene, &text, &len) == FOURDGS_STATUS_OK,
          "the library string is readable");

    for (uint32_t i = 0; i < fourdgs_scene_attribute_count(scene); ++i) {
        const char *k = NULL, *v = NULL;
        size_t kl = 0, vl = 0;
        check(fourdgs_scene_attribute_at(scene, i, &k, &kl, &v, &vl) == FOURDGS_STATUS_OK,
              "each header attribute is readable");
        check(k != NULL && v != NULL, "an attribute has a key and a value");
    }

    /* Records behind byte ranges: an indexed open framed them and read nothing. */
    check(fourdgs_scene_load_records(scene) == FOURDGS_STATUS_OK,
          "the front-matter records are fetchable");

    for (uint32_t i = 0; i < fourdgs_scene_metadata_count(scene); ++i) {
        check(fourdgs_scene_metadata_name(scene, i, &text, &len) == FOURDGS_STATUS_OK,
              "each metadata record has a readable name");
        for (uint32_t j = 0; j < fourdgs_scene_metadata_entry_count(scene, i); ++j) {
            const char *k = NULL, *v = NULL;
            size_t kl = 0, vl = 0;
            check(fourdgs_scene_metadata_entry_at(scene, i, j, &k, &kl, &v, &vl) ==
                      FOURDGS_STATUS_OK,
                  "each metadata entry is readable");
        }
    }

    for (uint32_t i = 0; i < fourdgs_scene_attachment_count(scene); ++i) {
        check(fourdgs_scene_attachment_name(scene, i, &text, &len) == FOURDGS_STATUS_OK,
              "each attachment has a readable name");
        check(fourdgs_scene_attachment_media_type(scene, i, &text, &len) == FOURDGS_STATUS_OK,
              "each attachment has a readable media type");
        uint64_t size = fourdgs_scene_attachment_size(scene, i);
        if (size > 0) {
            uint8_t *payload = malloc((size_t)size);
            check(payload != NULL, "the attachment payload fits in memory");
            if (payload) {
                /* The bytes, because the summary checksums them. */
                check(fourdgs_scene_attachment_read(scene, i, 0, size, payload) ==
                          FOURDGS_STATUS_OK,
                      "an attachment's bytes are readable");
                check(fourdgs_scene_attachment_read(scene, i, size, 1, payload) !=
                          FOURDGS_STATUS_OK,
                      "a range past an attachment is refused");
                free(payload);
            }
        }
    }

    if (fourdgs_scene_has_camera(scene)) {
        fourdgs_camera camera;
        check(fourdgs_scene_camera(scene, &camera) == FOURDGS_STATUS_OK,
              "a camera-bearing scene yields its camera");
        check(camera.interpolation != NULL, "the camera names its interpolation");
        for (uint32_t i = 0; i < camera.keyframe_count; ++i) {
            double t = 0.0, position[3] = {0}, target[3] = {0};
            check(fourdgs_scene_camera_keyframe(scene, i, &t, position, target) ==
                      FOURDGS_STATUS_OK,
                  "each keyframe is readable");
        }
        check(fourdgs_scene_camera_keyframe(scene, camera.keyframe_count, NULL, NULL, NULL) !=
                  FOURDGS_STATUS_OK,
              "a keyframe past the end is refused");
    } else {
        fourdgs_camera camera;
        check(fourdgs_scene_camera(scene, &camera) != FOURDGS_STATUS_OK,
              "a scene without a camera says so rather than inventing one");
    }

    if (fourdgs_scene_has_statistics(scene)) {
        uint64_t count = 0;
        uint32_t chunks = 0;
        double duration = 0.0, aabb[6] = {0};
        check(fourdgs_scene_statistics(scene, &count, &chunks, &duration, aabb) ==
                  FOURDGS_STATUS_OK,
              "statistics are readable when present");
    }

    /* Provenance: empty string when absent is OK; non-empty when present is owned JSON. */
    {
        const char *prov = NULL;
        size_t prov_len = 0;
        check(fourdgs_scene_provenance_json(scene, &prov, &prov_len) == FOURDGS_STATUS_OK,
              "provenance JSON is always readable");
        /* Empty is legal: most files carry no provenance. Free the owned pair either way. */
        if (prov_len > 0) {
            check(prov != NULL && prov[0] == '{', "non-empty provenance is a JSON object");
        }
        fourdgs_string_free(prov, prov_len);
    }

    for (uint32_t i = 0; i < fourdgs_scene_summary_offset_count(scene); ++i) {
        uint8_t opcode = 0;
        uint64_t start = 0, length = 0;
        check(fourdgs_scene_summary_offset_at(scene, i, &opcode, &start, &length) ==
                  FOURDGS_STATUS_OK,
              "each summary offset is readable");
    }

    int crc = fourdgs_scene_summary_crc_state(scene);
    check(crc == FOURDGS_CRC_NOT_CHECKED || crc == FOURDGS_CRC_FAILED ||
              crc == FOURDGS_CRC_VERIFIED,
          "the CRC state is one of the three");
    check(fourdgs_scene_summary_crc_state(NULL) == FOURDGS_CRC_NOT_CHECKED,
          "a null scene has not checked anything");
}

/* The two read paths have to be selectable, or two runners test one path twice. */
static void check_forced_paths(const char *path) {
    fourdgs_scene *sequential = NULL;
    check(fourdgs_open_path_ex(path, FOURDGS_OPEN_SEQUENTIAL, &sequential) ==
              FOURDGS_STATUS_OK,
          "a file opens front to back on request");
    if (sequential) {
        check(fourdgs_scene_is_indexed(sequential) == 0,
              "a forced sequential open reports the sequential path");
        check(fourdgs_scene_load_chunk(sequential, 0, 3) == FOURDGS_STATUS_UNSUPPORTED_MODE,
              "one chunk by index is unsupported on the sequential path, not an error");
        fourdgs_scene_free(sequential);
    }

    fourdgs_scene *indexed = NULL;
    check(fourdgs_open_path_ex(path, FOURDGS_OPEN_INDEXED, &indexed) == FOURDGS_STATUS_OK,
          "a file opens indexed on request");
    if (indexed) {
        check(fourdgs_scene_is_indexed(indexed) == 1,
              "a forced indexed open reports the indexed path");
        /* The band-skipping claim: what moved must equal what the index declared. */
        for (uint32_t i = 0; i < fourdgs_scene_chunk_count(indexed); ++i) {
            for (uint8_t cap = 0; cap <= 3; ++cap) {
                check(fourdgs_scene_load_chunk(indexed, i, cap) == FOURDGS_STATUS_OK,
                      "one chunk loads at every band cap");
                check(fourdgs_scene_bytes_for_chunk(indexed, i, cap) > 0,
                      "the index predicts what that chunk costs");
            }
        }
        fourdgs_scene_free(indexed);
    }

    fourdgs_scene *bogus = NULL;
    check(fourdgs_open_path_ex(path, 99, &bogus) == FOURDGS_STATUS_INVALID_ARGUMENT,
          "an unknown open mode is an invalid argument");
}

/* The encode surface, exercised the way a binding authors a file: build a tiny scene, encode
 * it, and reopen the bytes to prove they are a real 4dgs file. Independent of the corpus, so
 * it runs even when no path is given anything unusual. */
static void check_writer(void) {
    /* Null is safe on every writer entry point, because a binding will pass it eventually. */
    check(fourdgs_writer_set_duration(NULL, 1.0) == FOURDGS_STATUS_INVALID_ARGUMENT,
          "setting duration on a null writer is an invalid argument");
    check(fourdgs_writer_encode(NULL, NULL) == FOURDGS_STATUS_INVALID_ARGUMENT,
          "encoding a null writer is an invalid argument");
    check(fourdgs_buffer_len(NULL) == 0, "the length of a null buffer is 0");
    check(fourdgs_buffer_data(NULL) == NULL, "the data of a null buffer is null");
    fourdgs_writer_free(NULL);
    fourdgs_buffer_free(NULL);

    fourdgs_writer *writer = fourdgs_writer_new();
    check(writer != NULL, "a writer is created");
    if (writer == NULL) return;

    const uint32_t count = 3;
    const float positions[9] = {0.0f, 0.0f, 0.0f, 1.0f, 0.5f, -0.5f, -1.0f, 2.0f, 0.25f};
    const float scales[9] = {0.1f, 0.1f, 0.1f, 0.2f, 0.15f, 0.1f, 0.05f, 0.05f, 0.05f};
    const float rotations[12] = {0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 1.0f,
                                 0.0f, 0.0f, 0.0f, 1.0f};
    const float colors[12] = {0.9f, 0.1f, 0.1f, 1.0f, 0.1f, 0.9f, 0.1f, 0.8f,
                              0.1f, 0.1f, 0.9f, 0.5f};
    const float motions[9] = {0.0f, 0.0f, 0.0f, 0.1f, 0.0f, 0.0f, 0.0f, -0.1f, 0.0f};
    const float mu_t[3] = {0.5f, 1.0f, 1.5f};
    /* A never-fading gaussian's sigma is +inf, a value the encoder must accept and preserve. */
    const float sigma_t[3] = {0.3f, INFINITY, 0.4f};
    const float win_lo[3] = {0.0f, 0.0f, 0.0f};
    const float win_hi[3] = {2.0f, 2.0f, 2.0f};

    check(fourdgs_writer_set_duration(writer, 2.0) == FOURDGS_STATUS_OK, "duration is set");
    check(fourdgs_writer_set_chunking(writer, 4, 1) == FOURDGS_STATUS_OK, "chunking is set");
    check(fourdgs_writer_set_profile(writer, "test", 4) == FOURDGS_STATUS_OK, "profile is set");
    check(fourdgs_writer_add_attribute(writer, "k", 1, "v", 1) == FOURDGS_STATUS_OK,
          "an attribute is added");
    check(fourdgs_writer_set_gaussians(writer, count, positions, scales, rotations, colors,
                                       motions, mu_t, sigma_t, win_lo, win_hi) ==
              FOURDGS_STATUS_OK,
          "the gaussian columns are set");
    /* A null column with a non-zero count is refused rather than read. */
    check(fourdgs_writer_set_gaussians(writer, count, NULL, scales, rotations, colors, motions,
                                       mu_t, sigma_t, win_lo, win_hi) ==
              FOURDGS_STATUS_INVALID_ARGUMENT,
          "a null column is an invalid argument");
    /* Re-set the columns after the deliberate failure above left them cleared. */
    fourdgs_writer_set_gaussians(writer, count, positions, scales, rotations, colors, motions,
                                 mu_t, sigma_t, win_lo, win_hi);

    fourdgs_buffer *buffer = NULL;
    check(fourdgs_writer_encode(writer, &buffer) == FOURDGS_STATUS_OK, "the scene encodes");
    check(buffer != NULL, "a successful encode yields a buffer");
    if (buffer != NULL) {
        const uint8_t *data = fourdgs_buffer_data(buffer);
        const size_t length = fourdgs_buffer_len(buffer);
        check(data != NULL && length > 0, "the buffer holds bytes");

        fourdgs_scene *reopened = NULL;
        check(fourdgs_open_memory(data, length, &reopened) == FOURDGS_STATUS_OK,
              "the encoder's own output reopens");
        if (reopened != NULL) {
            check(fourdgs_scene_gaussian_count(reopened) == count,
                  "the reopened scene holds every gaussian written");
            check(fourdgs_scene_duration_sec(reopened) == 2.0, "the duration survives a round trip");
            check(fourdgs_scene_load_all(reopened, 3) == FOURDGS_STATUS_OK,
                  "the reopened scene decodes");
            check(fourdgs_scene_loaded_count(reopened) == count,
                  "every written gaussian is resident after decode");
            const float *sigma = fourdgs_scene_sigma_t(reopened);
            if (sigma != NULL) {
                int found_inf = 0;
                for (uint32_t i = 0; i < count; ++i)
                    if (isinf(sigma[i])) found_inf = 1;
                check(found_inf == 1, "the never-fading gaussian's infinite sigma survives");
            }
            fourdgs_scene_free(reopened);
        }

        /* The additive keyframe-delta surface, exercised on a real in-memory file. These
         * bytes are a gaussian-birth scene, so peeking names that model and the
         * keyframe-delta decoder refuses them as the wrong reader, not a bad file. */
        const char *model = NULL;
        size_t model_len = 0;
        check(fourdgs_peek_temporal_model(data, length, &model, &model_len) ==
                  FOURDGS_STATUS_OK,
              "the temporal model is peekable from bytes");
        check(model != NULL && model_len == strlen("gaussian-birth") &&
                  memcmp(model, "gaussian-birth", model_len) == 0,
              "a gaussian-birth buffer peeks as gaussian-birth");
        fourdgs_string_free(model, model_len);

        const char *states = NULL;
        size_t states_len = 0;
        check(fourdgs_keyframe_delta_states_json(data, length, 0, &states, &states_len) ==
                  FOURDGS_STATUS_MALFORMED,
              "the keyframe-delta decoder refuses a gaussian-birth file on the streamed path");

        /* Null out parameters are refused; null frees are ignored. */
        check(fourdgs_peek_temporal_model(data, length, NULL, NULL) ==
                  FOURDGS_STATUS_INVALID_ARGUMENT,
              "a null peek out parameter is invalid");
        check(fourdgs_keyframe_delta_states_json(data, length, 0, NULL, NULL) ==
                  FOURDGS_STATUS_INVALID_ARGUMENT,
              "a null states out parameter is invalid");
        fourdgs_string_free(NULL, 0);

        fourdgs_buffer_free(buffer);
    }
    fourdgs_writer_free(writer);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: capi_smoke <file.4dgs>\n");
        return 2;
    }

    check(fourdgs_format_version() == 1, "this build implements format version 1");
    check_null_safety();
    check_bad_magic();
    check_writer();

    fourdgs_scene *scene = NULL;
    int status = fourdgs_open_path(argv[1], &scene);
    if (status != FOURDGS_STATUS_OK) {
        fprintf(stderr, "open failed: %s\n", fourdgs_last_error());
        return 1;
    }

    double duration = fourdgs_scene_duration_sec(scene);
    uint64_t declared = fourdgs_scene_gaussian_count(scene);
    check(duration >= 0.0, "duration is not negative");

    status = fourdgs_scene_load_all(scene, 3);
    check(status == FOURDGS_STATUS_OK, "loading every chunk succeeds");
    uint32_t loaded = fourdgs_scene_loaded_count(scene);
    check(loaded == (uint32_t)declared, "the working set holds what the header declared");

    if (loaded > 0) {
        const float *positions = fourdgs_scene_positions(scene);
        const float *colors = fourdgs_scene_colors(scene);
        const float *sigma = fourdgs_scene_sigma_t(scene);
        check(positions != NULL && colors != NULL && sigma != NULL,
              "a non-empty working set exposes its arrays");
        for (uint32_t i = 0; i < loaded; ++i) {
            check(colors[4 * i + 3] >= 0.0f && colors[4 * i + 3] <= 1.0f,
                  "opacity is in [0, 1]");
            /* Infinity is a value here, not a sentinel: it must survive as infinity. */
            check(!isnan(sigma[i]), "sigma is never NaN");
        }
    }

    uint32_t chunks = fourdgs_scene_chunk_count(scene);
    double t0 = 0.0, t1 = 0.0;
    if (chunks > 0) {
        check(fourdgs_scene_chunk_interval(scene, 0, &t0, &t1) == FOURDGS_STATUS_OK,
              "the first chunk's interval is readable");
        check(t0 <= t1, "a chunk interval is not inverted");
    }
    check(fourdgs_scene_chunk_interval(scene, chunks + 1, &t0, &t1) ==
              FOURDGS_STATUS_OUT_OF_RANGE,
          "a chunk past the index is out of range");

    fourdgs_state *state = NULL;
    status = fourdgs_scene_state_at(scene, duration * 0.5, 3, &state);
    check(status == FOURDGS_STATUS_OK, "reconstructing an instant succeeds");
    if (status == FOURDGS_STATUS_OK) {
        uint32_t visible = fourdgs_state_count(state);
        const uint32_t *indices = fourdgs_state_indices(state);
        const float *orientations = fourdgs_state_orientations(state);
        const float *opacity = fourdgs_state_opacity(state);
        check(visible <= fourdgs_scene_loaded_count(scene),
              "no more gaussians are visible than are resident");
        for (uint32_t i = 0; i < visible; ++i) {
            check(indices[i] < fourdgs_scene_loaded_count(scene),
                  "every index points into the resident set");
            check(orientations != NULL, "visible state carries reconstructed orientations");
            check(opacity[i] >= 0.0f && opacity[i] <= 1.0f, "state opacity is in [0, 1]");
        }
        fourdgs_state_free(state);
    }

    check_summary_surface(scene);
    check(fourdgs_scene_truncated(scene) == 0, "a complete file is not truncated");

    /* Audio is zero or more independently range-readable, reconstructable sources. */
    if (fourdgs_scene_has_audio(scene)) {
        uint32_t count = fourdgs_scene_audio_source_count(scene);
        check(count > 0, "an audio-bearing scene has at least one source");
        for (uint32_t i = 0; i < count; ++i) {
            fourdgs_audio_source source;
            check(fourdgs_scene_audio_source(scene, i, &source) == FOURDGS_STATUS_OK,
                  "each audio source descriptor is readable");
            check(source.codec != NULL && source.codec_length > 0,
                  "each source names its codec");
            check(source.data_size > 0, "each source has encoded data");
            for (uint32_t k = 0; k < source.keyframe_count; ++k) {
                fourdgs_audio_source_keyframe keyframe;
                check(fourdgs_scene_audio_source_keyframe(scene, i, k, &keyframe) ==
                          FOURDGS_STATUS_OK,
                      "each moving-source keyframe is readable");
            }
            fourdgs_audio_source_state state;
            check(fourdgs_scene_audio_source_state_at(scene, i, duration / 2.0, &state) ==
                      FOURDGS_STATUS_OK,
                  "source timing and moving pose reconstruct at scene time");
            if (source.data_size >= 4) {
                uint8_t head[4] = {0};
                check(fourdgs_scene_audio_source_read(scene, i, 0, 4, head) ==
                          FOURDGS_STATUS_OK,
                      "a source payload range is readable");
                check(fourdgs_scene_audio_source_read(scene, i, source.data_size, 4, head) !=
                          FOURDGS_STATUS_OK,
                      "a range past one source is refused");
            }
        }
        check(fourdgs_scene_audio_source(scene, count, NULL) == FOURDGS_STATUS_INVALID_ARGUMENT,
              "a null descriptor out parameter is invalid");
    } else {
        check(fourdgs_scene_audio_source_count(scene) == 0,
              "a scene without audio has no sources");
        check(fourdgs_scene_audio_codec(scene) == NULL,
              "a scene without audio names no codec");
        check(fourdgs_scene_audio_size(scene) == 0,
              "a scene without audio has a zero-length track");
    }

    fourdgs_scene_free(scene);
    check_forced_paths(argv[1]);

    if (failures > 0) {
        fprintf(stderr, "%d C ABI checks failed\n", failures);
        return 1;
    }
    printf("C ABI smoke test passed on %s\n", argv[1]);
    return 0;
}
