// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

#include <cstdint>
#include <vector>

#include "fourdgs/fourdgs.hpp"

int main() {
  if (!fourdgs::backendAvailable()) return 1;

  // Cross the ABI, not merely the C++ inline surface. These bytes are deliberately not a
  // file; a linked core returns a typed refusal, while a stub returns kNotImplemented.
  const std::vector<std::uint8_t> bytes = {'n', 'o', 't', ' ', '4', 'd', 'g', 's'};
  const auto opened =
      fourdgs::Scene::openMemory(fourdgs::Span<const std::uint8_t>(bytes.data(), bytes.size()));
  if (opened.ok()) return 2;
  return opened.error().code == fourdgs::ErrorCode::kNotImplemented ? 3 : 0;
}
