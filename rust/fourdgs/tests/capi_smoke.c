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
    check(fourdgs_scene_loaded_count(NULL) == 0, "loaded count of a null scene is 0");
    check(fourdgs_scene_positions(NULL) == NULL, "positions of a null scene is null");
    check(fourdgs_scene_sh(NULL) == NULL, "sh of a null scene is null");
    check(fourdgs_state_count(NULL) == 0, "count of a null state is 0");
    check(fourdgs_state_centers(NULL) == NULL, "centers of a null state is null");
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

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: capi_smoke <file.4dgs>\n");
        return 2;
    }

    check(fourdgs_format_version() == 1, "this build implements format version 1");
    check_null_safety();
    check_bad_magic();

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
        const float *opacity = fourdgs_state_opacity(state);
        check(visible <= fourdgs_scene_loaded_count(scene),
              "no more gaussians are visible than are resident");
        for (uint32_t i = 0; i < visible; ++i) {
            check(indices[i] < fourdgs_scene_loaded_count(scene),
                  "every index points into the resident set");
            check(opacity[i] >= 0.0f && opacity[i] <= 1.0f, "state opacity is in [0, 1]");
        }
        fourdgs_state_free(state);
    }

    check_summary_surface(scene);
    check(fourdgs_scene_truncated(scene) == 0, "a complete file is not truncated");

    /* Audio is optional in every sense: absence is a value, and it costs nothing. */
    if (fourdgs_scene_has_audio(scene)) {
        uint64_t size = fourdgs_scene_audio_size(scene);
        const char *codec = fourdgs_scene_audio_codec(scene);
        check(codec != NULL && strlen(codec) > 0, "an audio-bearing scene names its codec");
        check(size > 0, "an audio-bearing scene has a non-empty track");
        if (size > 0) {
            uint8_t head[4] = {0};
            check(fourdgs_scene_audio_read(scene, 0, 4, head) == FOURDGS_STATUS_OK,
                  "a range of the track is readable");
            check(fourdgs_scene_audio_read(scene, size, 4, head) != FOURDGS_STATUS_OK,
                  "a range past the track is refused");
        }
    } else {
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
