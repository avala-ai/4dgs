// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The process, and nothing else.
///
/// Everything the tool does lives in `fourdgs::tool::run`, which takes its arguments as strings
/// and prints to streams the caller supplies — so the unit tests drive the whole tool, exit code
/// and output together, without spawning a process.

#include <iostream>
#include <string>
#include <vector>

#include "tool.hpp"

int main(int argc, char** argv) {
  std::vector<std::string> args;
  args.reserve(static_cast<std::size_t>(argc > 1 ? argc - 1 : 0));
  for (int i = 1; i < argc; ++i) args.emplace_back(argv[i]);
  return fourdgs::tool::run(args, std::cout, std::cerr);
}
