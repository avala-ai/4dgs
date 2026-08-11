// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Walk the records: offset, opcode, length, CRC status.
///
/// Framing only, plus the summary region the Footer names. A record's content is never read, so
/// this is as cheap on a file with an embedded audio payload as on one without, and an opcode
/// nobody here has heard of is stepped over by its own declared length — which is the whole
/// forward-compatibility story, exercised rather than described.
///
/// A file that was cut is walked as far as it goes and then says so. That is what the library
/// does with one: records are length-prefixed, so everything complete before the cut is intact,
/// and the question its holder has is how much of it survived rather than whether the file is
/// broken, which they already know.

#include <cctype>
#include <iomanip>
#include <memory>
#include <ostream>
#include <string>

#include "tool.hpp"

namespace fourdgs {
namespace tool {

namespace {

/// One table row, in the column widths the Rust tool prints. The two tools are expected to
/// agree, and a report a reader diffs is a report where alignment is part of the agreement.
void row(std::ostream& out, const std::string& offset, const std::string& record,
         const std::string& content, const std::string& total, const char* crc) {
  out << std::setw(12) << std::right << offset << "  " << std::setw(18) << std::left << record
      << " " << std::setw(14) << std::right << content << "  " << std::setw(14) << std::right
      << total << "  " << crc << "\n";
}

std::string jsonString(const std::string& value) {
  std::string out = "\"";
  for (char c : value) {
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          static const char* digits = "0123456789abcdef";
          out += "\\u00";
          out.push_back(digits[(static_cast<unsigned char>(c) >> 4) & 0x0F]);
          out.push_back(digits[static_cast<unsigned char>(c) & 0x0F]);
        } else {
          out.push_back(c);
        }
    }
  }
  out += "\"";
  return out;
}

void printText(std::ostream& out, Readable& source, const Walk& walk,
               const std::optional<Coverage>& covered) {
  row(out, "offset", "record", "content", "total", "crc");
  row(out, "0", "(magic)", "", "8", "-");
  (void)fourdgs::tool::walk(source, [&](const Frame& frame, bool) {
    row(out, commas(frame.offset), opcodeName(frame.opcode), commas(frame.length),
        commas(frame.total()), coverageCell(covered, frame.offset, frame.total()));
  });
  if (walk.trailingMagic) {
    row(out, commas(walk.size - kMagicSize), "(magic)", "", "8", "-");
  }
  out << "\n" << walk.recordCount << " records, " << commas(walk.size) << " bytes\n";
  if (walk.cut.has_value()) {
    out << "truncated at byte " << commas(walk.cut->at) << ": " << walk.cut->reason << "\n";
    out << "the " << walk.intact()
        << " complete records above are the intact prefix, which is what a streamed reader keeps"
        << (walk.cut->insideARecord ? "; the last row is the record the file was cut inside" : "")
        << "\n";
  } else if (!walk.trailingMagic) {
    out << "note: the file does not end with the magic\n";
  }
  if (covered.has_value()) {
    out << "crc: the Footer's summary checksum covers bytes " << commas(covered->start) << ".."
        << commas(covered->end) << "; `-` is a record it does not cover\n";
  } else {
    out << "crc: this file declares no summary checksum, so nothing here is covered\n";
  }
}

void printJson(std::ostream& out, Readable& source, const Walk& walk,
               const std::optional<Coverage>& covered) {
  out << "{\n";
  out << "  \"size\": " << walk.size << ",\n";
  out << "  \"trailing_magic\": " << (walk.trailingMagic ? "true" : "false") << ",\n";
  if (walk.cut.has_value()) {
    out << "  \"stopped\": " << jsonString(walk.cut->reason) << ",\n";
    out << "  \"truncated_at\": " << walk.cut->at << ",\n";
  } else {
    out << "  \"stopped\": null,\n";
    out << "  \"truncated_at\": null,\n";
  }
  if (covered.has_value()) {
    out << "  \"summary_crc\": {\"start\": " << covered->start << ", \"end\": " << covered->end
        << ", \"ok\": " << (covered->ok ? "true" : "false") << "},\n";
  } else {
    out << "  \"summary_crc\": null,\n";
  }
  out << "  \"records\": [\n";
  std::uint64_t i = 0;
  (void)fourdgs::tool::walk(source, [&](const Frame& frame, bool) {
    const std::string cell = coverageCell(covered, frame.offset, frame.total());
    std::string crc = "null";
    if (cell != "-") {
      std::string lowered = cell;
      for (char& c : lowered) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
      crc = jsonString(lowered);
    }
    out << "    {\"offset\": " << frame.offset
        << ", \"opcode\": " << static_cast<unsigned>(frame.opcode)
        << ", \"name\": " << jsonString(opcodeName(frame.opcode))
        << ", \"content_length\": " << frame.length << ", \"total_length\": " << frame.total()
        << ", \"crc\": " << crc << "}" << (i + 1 == walk.recordCount ? "" : ",") << "\n";
    i += 1;
  });
  out << "  ]\n";
  out << "}\n";
}

}  // namespace

int runInspect(const std::string& path, bool json, std::ostream& out, std::ostream& err) {
  // Ranges, not a file. The walk reads nine bytes per record and steps over the content, and the
  // summary checksum is accumulated through one 64 KiB buffer — so the sentence at the top of
  // this file, that inspecting a capture with an hour of embedded audio costs what inspecting one
  // without it costs, is a property of the code rather than a description of it.
  Result<FileReadable*> file = FileReadable::open(path);
  if (!file) {
    err << "4dgs: " << path << ": " << file.error().message << "\n";
    return kExitTool;
  }
  std::unique_ptr<FileReadable> source(*file);
  Result<Walk> walked = walk(*source);
  if (!walked) {
    err << "4dgs: " << path << ": " << walked.error().message << "\n";
    // And the identifier, plus the byte, for the refusals the specification names. There is no
    // walk to place it against — the walk is what just failed — so only the two refusals about
    // the magic itself are placeable here, and those need no walk.
    std::optional<Named> named = describe(walked.error(), nullptr, std::nullopt);
    if (named.has_value()) err << "4dgs: " << named->toString() << "\n";
    return kExitFailed;
  }

  const std::optional<Coverage> covered = coverage(*source, *walked);
  if (json) {
    printJson(out, *source, *walked, covered);
  } else {
    printText(out, *source, *walked, covered);
  }
  // The prefix was recovered and reported; the file is still not a whole one, and a pipeline that
  // goes on to read it should not be told otherwise.
  //
  // A missing trailing magic counts, and it is not the same condition as a cut. A file cut
  // exactly on a record boundary — the shape `head -c` produces most often, because it needs no
  // luck to land there — leaves the walk with no cut to report and only the closing magic absent.
  // That file used to print "the file does not end with the magic" and exit 0, so a script
  // reading the exit code was told the incomplete file inspected cleanly.
  const bool whole = !walked->cut.has_value() && walked->trailingMagic;
  return whole ? kExitOk : kExitFailed;
}

}  // namespace tool
}  // namespace fourdgs
