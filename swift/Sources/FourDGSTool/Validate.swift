// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Structural validation.
///
/// This is what makes a third-party encoder possible: a way to find out *why* a file is wrong
/// that does not involve reading someone else's decoder. Every finding names the record, the
/// field and what was expected.
///
/// The findings, their severities and their wording are `python/fourdgs/fourdgs/validate.py`'s.
/// Two validators that disagree about whether a file conforms are worse than one, so where the
/// two differ the Python module is the reference and this is the bug.
///
/// **What this validator does not check, and why.** The Python and Rust validators parse every
/// record's body and check its fields — the Header's gaussian count against the chunks, each
/// Audio Source's pose and timing, every quantization step for finiteness. This one does not,
/// because the Swift package is a binding: it has no record parsers of its own, every call into
/// the format goes through `CoreSeam.swift`, and writing parsers here would make the tool a
/// second implementation of the format that could disagree with the decoder it ships beside. So
/// the checks below are the ones that need no parser — framing, the records a file must carry,
/// where the index points, the summary checksum — plus everything the reader itself decides,
/// which is where the six named refusals live.
///
/// The consequence is worth stating plainly: on a file this tool calls valid, Python may still
/// have something to say. It reports a subset of Python's findings and never a finding Python
/// contradicts, which is the property that matters — a validator that is quieter is a gap, and
/// one that disagrees is a bug.
///
/// Three things it does that the Python tool does not:
///
/// * **It prints the refusal identifier and the byte.** The finding lines themselves match
///   Python's word for word; the identifier goes on a line of its own beneath the finding it
///   belongs to. Python's exceptions carry the same `code` — its CLI simply does not print it.
/// * **It decodes the chunks.** A framing walk steps over a chunk by its declared length, so a
///   fault inside a chunk's streams is invisible to it; two of the invalid corpus's seven files
///   are exactly that, and Python calls them clean.
/// * **It recognizes `keyframe-delta`.** Python reports a conforming keyframe-delta file as
///   invalid, because its structural checks assume the gaussian-birth chunk shape. This tool uses
///   the model's own Chunk-or-DeltaChunk index rule. Its current ABI has no ranged composition
///   entry point, so bounded validation stops at framing, index and checksum for that model.

import FourDGS

public enum Severity: Int, Comparable {
    case note
    case warning
    case error

    /// `note`, `warning`, `error` — the prefix a finding is printed under.
    public var name: String {
        switch self {
        case .note: return "note"
        case .warning: return "warning"
        case .error: return "error"
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One thing wrong with a file, and — when the SDK named it — which refusal it is.
public struct Finding {
    public let severity: Severity
    /// Word for word what the Python validator prints for the same bytes.
    public let message: String
    /// The refusal identifier and the byte it fired at, for the findings that have one. Most do
    /// not: "first record is Footer; the Header must come first" is a rule this validator checks
    /// itself, not a refusal the reader raised, and the refusal table does not name it.
    public let refusal: Named?
}

public struct Report {
    public var findings: [Finding] = []

    public var ok: Bool { !findings.contains { $0.severity == .error } }
    public var worst: Severity? { findings.map(\.severity).max() }

    mutating func push(_ severity: Severity, _ message: String, _ refusal: Named?) {
        findings.append(Finding(severity: severity, message: message, refusal: refusal))
    }

    mutating func error(_ message: String) { push(.error, message, nil) }
    mutating func warn(_ message: String) { push(.warning, message, nil) }
    mutating func note(_ message: String) { push(.note, message, nil) }

    /// An error the reader raised, carrying its identifier and the byte if it has one.
    ///
    /// `prefix` is what the message is introduced with, so the sentence stays the one the other
    /// validators print; the identifier arrives on its own line and changes nothing about it.
    mutating func refused(_ prefix: String, _ error: FourDGSError, _ walk: Walk?, _ site: Site?) {
        push(.error, prefix + sentence(error), describe(error, walk: walk, site: site))
    }
}

/// Every check, over one size-and-range transport.
func validate(_ source: ToolReader) -> Report {
    var report = Report()

    // Framing first, and for two reasons: it refuses a file that is not ours before anything
    // reads a byte as an opcode, and it is what gives every later refusal a byte to point at.
    var firstOpcode: UInt8?
    var lastOpcode: UInt8?
    var hasHeader = false
    var hasQuantization = false
    var hasFooter = false
    // Two are enough to preserve the refusal-placement rule: one can be placed, more than one is
    // ambiguous. Footer content is read only from the first. Chunk Index frames are the format's
    // small seek index; every unrelated top-level frame is consumed and immediately discarded.
    var retainedHeaders = 0
    var retainedQuantizations = 0
    var retainedFooters = 0
    let walked: Walk
    do {
        walked = try walk(
            source,
            retaining: { frame in
                switch frame.opcode {
                case Opcode.header:
                    defer { retainedHeaders += 1 }
                    return retainedHeaders < 2
                case Opcode.quantization:
                    defer { retainedQuantizations += 1 }
                    return retainedQuantizations < 2
                case Opcode.footer:
                    defer { retainedFooters += 1 }
                    return retainedFooters == 0
                case Opcode.chunkIndex:
                    return true
                default:
                    return false
                }
            },
            visit: { frame, intact in
                guard intact else { return }
                let opcode = frame.opcode
                if firstOpcode == nil { firstOpcode = opcode }
                lastOpcode = opcode
                if opcode == Opcode.header { hasHeader = true }
                if opcode == Opcode.quantization { hasQuantization = true }
                if opcode == Opcode.footer { hasFooter = true }
                if isPrivate(opcode) {
                    report.note(
                        "private record 0x\(hex2(opcode)) (\(frame.length) bytes) — skipped, as required")
                } else if isProvenance(opcode) && !isSpecified(opcode) {
                    // The reserved tail of the provenance family is spoken for, so this is a
                    // future-revision record rather than a byte the reader cannot account for.
                    report.note(
                        "reserved provenance record 0x\(hex2(opcode)) — skipped, as required "
                            + "(0x26-0x2F, section 5.15.8)")
                } else if !isSpecified(opcode) {
                    report.note("unknown record 0x\(hex2(opcode)) — skipped, as required")
                }
            })
    } catch {
        report.refused("", asFourDGS(error), nil, nil)
        return report
    }

    if !walked.trailingMagic {
        report.error(
            "file does not end with the magic; it is truncated or was written by a broken encoder")
    }

    // Report the cut before any early return. In particular, a file cut inside its first record
    // has no intact first opcode, but the walk still knows that record's byte, kind, declared
    // length and the resource size — the useful diagnosis must not be hidden by "no records".
    if let cut = walked.cut {
        report.note(
            "the file is cut at byte \(commas(cut.at)): \(cut.reason). The \(walked.intact) "
                + "complete records before it are intact, and a streamed reader recovers them")
    }

    // Only whole records set these values: a record the file was cut inside is reported by the
    // note above, and counting it as present would say a Footer exists before its bytes do.
    guard let firstOpcode else {
        report.error("no records at all")
        return report
    }
    if firstOpcode != Opcode.header {
        report.error("first record is \(opcodeName(firstOpcode)); the Header must come first")
    }
    if !hasHeader { report.error("no Header record") }
    if !hasQuantization { report.error("no Quantization record") }
    if !hasFooter { report.error("no Footer record") }
    if hasFooter && lastOpcode != Opcode.footer {
        report.error(
            "last record is \(opcodeName(lastOpcode ?? 0)); the Footer must be the final record")
    }

    // Which chunk shape the rest of this validator is entitled to assume. A `keyframe-delta`
    // file's Chunks are keyframes and its Delta Chunks are differences against them, so the index
    // check below is about the gaussian-birth shape and about nothing else. Read from the Header
    // rather than guessed from the records, because a file that carries Delta Chunks and does not
    // say so is itself a fault.
    //
    // The two length-prefixed strings before this field are skipped by their declared lengths;
    // only four-byte lengths and the fourteen-byte dispatch value are read. A fixed prefix is not
    // sufficient because a conforming profile or library name can put this field arbitrarily far
    // into the Header.
    let keyframeDelta: Bool
    do {
        keyframeDelta = try isKeyframeDelta(source, walked)
    } catch {
        report.refused("", asFourDGS(error), walked, nil)
        return report
    }

    let index: [IndexEntry]
    do {
        index = try chunkIndexEntries(source, walked)
    } catch {
        report.refused("", asFourDGS(error), walked, nil)
        return report
    }
    for (i, entry) in index.enumerated() {
        let (end, overflow) = entry.offset.addingReportingOverflow(entry.length)
        if overflow || end > walked.size || entry.offset >= walked.size {
            report.error("chunk index entry \(i) points past the end of the file")
            continue
        }
        // A `keyframe-delta` file indexes both kinds: a Chunk is a keyframe and a Delta Chunk is
        // a difference against one, and an index that could only name the former could not seek
        // the model at all.
        let at: UInt8
        do {
            at = try source.exactly(offset: entry.offset, count: 1, record: "Chunk Index target")[0]
        } catch {
            report.refused("", asFourDGS(error), walked, nil)
            continue
        }
        if at != Opcode.chunk && !(keyframeDelta && at == Opcode.deltaChunk) {
            let expected = keyframeDelta ? "a Chunk or DeltaChunk record" : "a Chunk record"
            report.error("chunk index entry \(i) does not point at \(expected)")
        }
    }

    let summary: SummaryDeclaration?
    do {
        summary = try summaryDeclaration(source, walked)
    } catch {
        report.refused("", asFourDGS(error), walked, nil)
        return report
    }
    if let summary {
        if summary.start > summary.end {
            report.error(
                "the Footer's summary starts at \(summary.start), after the summary ends at "
                    + "\(summary.end)")
        } else {
            do {
                if let covered = try coverage(source, walked), !covered.ok {
                    report.error(
                        "summary CRC mismatch: the index is untrustworthy "
                            + "(a streamed read still works)")
                }
            } catch {
                report.refused("", asFourDGS(error), walked, nil)
                return report
            }
        }
    }

    if hasHeader && index.isEmpty {
        report.warn("no chunk index: this file can only be read front to back, not seeked")
    }

    if !keyframeDelta {
        checkGaussianBirth(source, walked, index, &report)
    }

    return report
}

/// The in-memory convenience used by parser tests and callers that already own their bytes.
public func validate(_ bytes: [UInt8]) -> Report {
    validate(ToolReader(InMemoryReader(bytes)))
}

/// The two checks only a reader can perform: open the file, then decode it.
///
/// Opening it the way a seeking client would is where the front-matter refusals fire — an
/// unimplemented temporal model, an unimplemented quantization scheme. Decoding the chunks is
/// where the rest do, and there is no substitute for it: the framing walk steps over a chunk by
/// its declared length, so an unimplemented stream codec and an out-of-range window index are
/// both invisible to everything before this point. Both are in the invalid corpus.
private func checkGaussianBirth(
    _ source: ToolReader, _ walked: Walk, _ index: [IndexEntry], _ report: inout Report
) {
    let reader: SceneReader
    do {
        reader = try SceneReader(source, path: .indexed)
    } catch {
        report.refused(
            "a seeking reader cannot open this file: ", asFourDGS(error), walked, nil)
        // A file that will not open will not decode either, and the second error would say the
        // same thing about the same byte.
        return
    }
    if let refusal = scanChunks(reader, index: index) {
        report.refused("a chunk does not decode: ", refusal.error, walked, refusal.site)
    }
}

/// `4dgs validate <file>` — check a file against the specification.
public func runValidate(_ path: String, _ out: TextOutput, _ err: TextOutput) -> Int32 {
    let source: ToolReader
    do {
        source = try ToolReader(FileReader(path: path))
    } catch {
        // Not the file's fault, and not a refusal. See ``exitTool``.
        err.line("4dgs: \(path): \(sentence(asFourDGS(error)))")
        return exitTool
    }
    let report = validate(source)
    for finding in report.findings {
        out.line("\(finding.severity.name): \(finding.message)")
        // Indented, and with a prefix of its own, so that a caller filtering the findings on
        // `error:`/`warning:`/`note:` — which is how the validators are compared — sees exactly
        // what it saw before.
        if let refusal = finding.refusal { out.line("  \(refusal)") }
    }
    if !report.ok {
        err.line("INVALID")
        return exitFailed
    }
    out.line(report.findings.isEmpty ? "valid" : "valid (with notes)")
    // The one deliberate divergence from the Python tool, which exits 0 here, and the Rust and
    // C++ tools' too. A warning a script cannot see is a warning nobody acts on, so it gets its
    // own code.
    return report.worst == .warning ? exitWarnings : exitOk
}
