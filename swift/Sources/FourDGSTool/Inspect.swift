// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Walk the records: offset, opcode, length, CRC status.
///
/// Framing only, plus the summary region the Footer names. A record's content is never read, so
/// this is as cheap on a file with an embedded audio payload as on one without, and an opcode
/// nobody here has heard of is stepped over by its own declared length — which is the whole
/// forward-compatibility story, exercised rather than described.
///
/// A file that was cut is walked as far as it goes and then says so. That is what the SDK does
/// with one: records are length-prefixed, so everything complete before the cut is intact, and
/// the question its holder has is how much of it survived rather than whether the file is broken,
/// which they already know.

import FourDGS

func walk(_ source: ToolReader) throws -> Walk {
    try walk(source, retaining: { _ in true })
}

public func walk(_ bytes: [UInt8]) throws -> Walk {
    try walk(ToolReader(InMemoryReader(bytes)))
}

/// One table row, in the column widths the Rust and C++ tools print. The tools are expected to
/// agree, and a report a reader diffs is a report where alignment is part of the agreement.
private func row(
    _ out: TextOutput, _ offset: String, _ record: String, _ content: String, _ total: String,
    _ crc: String
) {
    out.line(
        pad(offset, 12, left: false) + "  " + pad(record, 18, left: true) + " "
            + pad(content, 14, left: false) + "  " + pad(total, 14, left: false) + "  " + crc)
}

/// A field padded to `width`, left- or right-aligned, and never truncated: a value wider than its
/// column pushes the row out rather than losing a digit.
private func pad(_ value: String, _ width: Int, left: Bool) -> String {
    let fill = String(repeating: " ", count: max(0, width - value.count))
    return left ? value + fill : fill + value
}

private func printText(
    _ out: TextOutput, _ source: ToolReader, _ walked: Walk, _ declared: SummaryDeclaration?,
    _ covered: Coverage?
) throws {
    row(out, "offset", "record", "content", "total", "crc")
    row(out, "0", "(magic)", "", "8", "-")
    _ = try walk(
        source, retaining: { _ in false },
        visit: { frame, _ in
            row(
                out, commas(frame.offset), opcodeName(frame.opcode), commas(frame.length),
                commas(frame.total), Coverage.cell(covered, at: frame.offset, total: frame.total))
        })
    if walked.trailingMagic {
        row(out, commas(walked.size - UInt64(magic.count)), "(magic)", "", "8", "-")
    }
    out.line("")
    out.line("\(walked.recordCount) records, \(commas(walked.size)) bytes")
    if let cut = walked.cut {
        out.line("truncated at byte \(commas(cut.at)): \(cut.reason)")
        out.line(
            "the \(walked.intact) complete records above are the intact prefix, which is what a "
                + "streamed reader keeps"
                + (cut.insideARecord ? "; the last row is the record the file was cut inside" : ""))
    } else if !walked.trailingMagic {
        out.line("note: the file does not end with the magic")
    }
    if let covered {
        out.line(
            "crc: the Footer's summary checksum covers bytes \(commas(covered.start)).."
                + "\(commas(covered.end)); `-` is a record it does not cover")
    } else if let declared, declared.start > declared.end {
        out.line(
            "crc: INVALID: the Footer's summary starts at \(commas(declared.start)), after "
                + "the summary ends at \(commas(declared.end))")
    } else {
        out.line("crc: this file declares no summary checksum, so nothing here is covered")
    }
}

private func printJson(
    _ out: TextOutput, _ source: ToolReader, _ walked: Walk, _ declared: SummaryDeclaration?,
    _ covered: Coverage?
) throws {
    out.line("{")
    out.line("  \"size\": \(walked.size),")
    out.line("  \"trailing_magic\": \(walked.trailingMagic),")
    if let cut = walked.cut {
        out.line("  \"stopped\": \(jsonString(cut.reason)),")
        out.line("  \"truncated_at\": \(cut.at),")
    } else {
        out.line("  \"stopped\": null,")
        out.line("  \"truncated_at\": null,")
    }
    if let covered {
        out.line(
            "  \"summary_crc\": {\"start\": \(covered.start), \"end\": \(covered.end), "
                + "\"ok\": \(covered.ok)},")
    } else if let declared, declared.start > declared.end {
        out.line(
            "  \"summary_crc\": {\"start\": \(declared.start), \"end\": \(declared.end), "
                + "\"ok\": null, \"error\": \"start is after end\"},")
    } else {
        out.line("  \"summary_crc\": null,")
    }
    out.line("  \"records\": [")
    var index = 0
    _ = try walk(
        source, retaining: { _ in false },
        visit: { frame, _ in
            let cell = Coverage.cell(covered, at: frame.offset, total: frame.total)
            let crc = cell == "-" ? "null" : jsonString(cell.lowercased())
            index += 1
            let comma = index == walked.recordCount ? "" : ","
            out.line(
                "    {\"offset\": \(frame.offset), \"opcode\": \(frame.opcode), "
                    + "\"name\": \(jsonString(opcodeName(frame.opcode))), "
                    + "\"content_length\": \(frame.length), \"total_length\": \(frame.total), "
                    + "\"crc\": \(crc)}\(comma)")
        })
    out.line("  ]")
    out.line("}")
}

/// A string as a JSON string. The only escapes a record's fields can need are these: names are
/// UTF-8, and control characters are spelled `\u00XX`.
func jsonString(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case let c where c.value < 0x20:
            out += "\\u00" + hex2(UInt8(c.value)).lowercased()
        case let c: out.unicodeScalars.append(c)
        }
    }
    return out + "\""
}

/// `4dgs inspect <file> [--json]` — walk the records: offset, opcode, length, CRC status.
public func runInspect(_ path: String, json: Bool, _ out: TextOutput, _ err: TextOutput) -> Int32 {
    let source: ToolReader
    do {
        source = try ToolReader(FileReader(path: path))
    } catch {
        err.line("4dgs: \(path): \(sentence(asFourDGS(error)))")
        return exitTool
    }
    var retainedFooter = false
    let walked: Walk
    do {
        walked = try walk(
            source,
            retaining: { frame in
                guard frame.opcode == Opcode.footer, !retainedFooter else { return false }
                retainedFooter = true
                return true
            })
    } catch {
        let refusal = asFourDGS(error)
        err.line("4dgs: \(path): \(sentence(refusal))")
        // And the identifier, plus the byte, for the refusals the specification names. There is
        // no walk to place it against — the walk is what just failed — so only the two refusals
        // about the magic itself are placeable here, and those need no walk.
        if let named = describe(refusal, walk: nil, site: nil) { err.line("4dgs: \(named)") }
        return exitFailed
    }

    let declared: SummaryDeclaration?
    let covered: Coverage?
    do {
        declared = try summaryDeclaration(source, walked)
        covered = try coverage(source, walked)
    } catch {
        err.line("4dgs: \(path): \(sentence(asFourDGS(error)))")
        return exitTool
    }
    do {
        if json {
            try printJson(out, source, walked, declared, covered)
        } else {
            try printText(out, source, walked, declared, covered)
        }
    } catch {
        err.line("4dgs: \(path): \(sentence(asFourDGS(error)))")
        return exitTool
    }
    // The prefix was recovered and reported; the file is still not a whole one, and a pipeline
    // that goes on to read it should not be told otherwise.
    return walked.cut != nil || !walked.trailingMagic ? exitFailed : exitOk
}
