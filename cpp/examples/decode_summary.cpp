// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// What decoding a scene looks like from C++, end to end.
///
/// Open a file, describe it, seek to an instant, and reconstruct the gaussians alive there.
/// Run in CI over a corpus file, so it cannot rot into a snippet that no longer compiles.
///
///     decode_summary scene.4dgs [time]

#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>

#include "fourdgs/fourdgs.hpp"

int main(int argc, char** argv) {
  if (argc < 2 || argc > 3) {
    std::fprintf(stderr, "usage: decode_summary <file.4dgs> [time]\n");
    return 2;
  }

  auto opened = fourdgs::Scene::openPath(argv[1]);
  if (!opened) {
    // The error names the problem — which byte, which record, what was expected — rather
    // than reporting that something went wrong.
    std::fprintf(stderr, "%s\n", opened.error().toString().c_str());
    return 1;
  }
  fourdgs::Scene& scene = **opened;

  std::printf("duration      %.3f s\n", scene.durationSec());
  std::printf("gaussians     %llu\n", static_cast<unsigned long long>(scene.gaussianCount()));
  std::printf("sh degree     %d\n", scene.shDegree());
  std::printf("chunks        %u%s\n", scene.chunkCount(), scene.isIndexed() ? ", indexed" : "");
  // Audio presence comes from the header alone. Descriptors and payloads are per source.
  if (scene.hasAudio()) {
    std::printf("audio sources %u\n", scene.audioSourceCount());
  } else {
    std::printf("audio         none\n");
  }

  const double t = argc == 3 ? std::atof(argv[2]) : scene.durationSec() / 2.0;

  // What this instant will cost before paying for it. Seek efficiency is a property of the
  // content: a scene whose gaussians all live for the whole clip has one chunk covering
  // everything, and this says so.
  std::printf("\nat t = %.3f s, %llu bytes to transfer\n", t,
              static_cast<unsigned long long>(scene.bytesForTime(t, 3)));

  auto state = scene.stateAt(t, 3);
  if (!state) {
    std::fprintf(stderr, "%s\n", state.error().toString().c_str());
    return 1;
  }
  std::printf("%zu gaussians visible of %zu resident\n", state->count(), scene.gaussians().count);

  // Decoding ends here: positions and opacities at an instant. What draws them is somebody
  // else's library.
  const std::size_t shown = state->count() < 3 ? state->count() : 3;
  for (std::size_t i = 0; i < shown; ++i) {
    std::printf("  [%u] center (%.3f, %.3f, %.3f)  opacity %.3f\n", state->indices()[i],
                static_cast<double>(state->centers()[i * 3 + 0]),
                static_cast<double>(state->centers()[i * 3 + 1]),
                static_cast<double>(state->centers()[i * 3 + 2]),
                static_cast<double>(state->opacity()[i]));
  }
  return 0;
}
