// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// `4dgs`: walk a `.4dgs` file's records, and say why one is refused.
///
/// Two commands, one positional and one flag. A parser for that is shorter than the paragraph
/// justifying a dependency for it, and it means the tool's whole dependency tree stays the
/// binding and the core it links.
///
/// The tool is expected to agree with the other SDKs' validators. Where a command exists in
/// more than one, it reads the same records, prints the same findings in the same words and
/// exits the same way; a difference between them on one file is a bug in one of them, not a
/// matter of taste.

#include <ostream>
#include <string>
#include <vector>

#include "tool.hpp"

namespace fourdgs {
namespace tool {

const char* const kUsage =
    "4dgs — inspect and validate .4dgs files\n"
    "\n"
    "usage:\n"
    "  4dgs validate <file>               check a file against the specification\n"
    "  4dgs inspect <file> [--json]       walk the records: offset, opcode, length, crc\n"
    "  4dgs --version\n"
    "  4dgs --help\n"
    "\n"
    "options:\n"
    "  --json          machine-readable output (inspect)\n"
    "\n"
    "exit codes:\n"
    "  0  fine                       2  valid, with warnings\n"
    "  1  refused, or invalid        3  the tool could not run (no such file, bad usage)\n";

int run(const std::vector<std::string>& argv, std::ostream& out, std::ostream& err) {
  if (argv.empty()) {
    out << kUsage;
    return kExitOk;
  }
  const std::string& first = argv[0];
  // A request that was served, not a failure.
  if (first == "-h" || first == "--help" || first == "help") {
    out << kUsage;
    return kExitOk;
  }
  if (first == "-V" || first == "--version" || first == "version") {
    out << FOURDGS_TOOL_VERSION << "\n";
    return kExitOk;
  }

  const bool validate = first == "validate";
  const bool inspect = first == "inspect";
  if (!validate && !inspect) {
    err << "4dgs: unknown command `" << first << "`\n\n" << kUsage;
    return kExitTool;
  }

  std::string file;
  bool json = false;
  for (std::size_t i = 1; i < argv.size(); ++i) {
    const std::string& arg = argv[i];
    if (arg == "--json") {
      json = true;
    } else if (!arg.empty() && arg[0] == '-' && arg != "-") {
      err << "4dgs: unknown option `" << arg << "`\n\n" << kUsage;
      return kExitTool;
    } else if (file.empty()) {
      file = arg;
    } else {
      err << "4dgs: " << first << " takes one file\n\n" << kUsage;
      return kExitTool;
    }
  }
  if (file.empty()) {
    err << "4dgs: " << first << " needs a file\n\n" << kUsage;
    return kExitTool;
  }
  if (json && validate) {
    err << "4dgs: validate has no --json output\n\n" << kUsage;
    return kExitTool;
  }
  return validate ? runValidate(file, out, err) : runInspect(file, json, out, err);
}

}  // namespace tool
}  // namespace fourdgs
