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
/// * **It knows `keyframe-delta`.** Python reports a conforming keyframe-delta file as invalid,
///   because its structural checks assume the gaussian-birth chunk shape. The core implements the
///   model — the conformance suite proves it — so refusing a file for declaring it was never a
///   statement about the file.

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

/// Every check, over bytes already in hand.
public func validate(_ bytes: [UInt8]) -> Report {
    var report = Report()

    // Framing first, and for two reasons: it refuses a file that is not ours before anything
    // reads a byte as an opcode, and it is what gives every later refusal a byte to point at.
    let walked: Walk
    do {
        walked = try walk(bytes)
    } catch {
        report.refused("", asFourDGS(error), nil, nil)
        return report
    }

    if Array(bytes.suffix(magic.count)) != magic {
        report.error(
            "file does not end with the magic; it is truncated or was written by a broken encoder")
    }

    // Only the whole records: a record the file was cut inside is reported by the note below, and
    // counting it as present would say a Footer exists in a file that stops before one.
    var seen: [UInt8] = []
    var hasHeader = false
    var hasQuantization = false
    var hasFooter = false
    for frame in walked.intactRecords {
        let opcode = frame.opcode
        seen.append(opcode)
        if opcode == Opcode.header { hasHeader = true }
        if opcode == Opcode.quantization { hasQuantization = true }
        if opcode == Opcode.footer { hasFooter = true }
        if isPrivate(opcode) {
            report.note(
                "private record 0x\(hex2(opcode)) (\(frame.length) bytes) — skipped, as required")
        } else if isProvenance(opcode) && !isSpecified(opcode) {
            // The reserved tail of the provenance family, which is a different thing from an
            // unknown record: the range is spoken for, so a reader that meets one knows it is
            // looking at a record from a later revision rather than at a byte it cannot account
            // for.
            report.note(
                "reserved provenance record 0x\(hex2(opcode)) — skipped, as required "
                    + "(0x26-0x2F, section 5.15.8)")
        } else if !isSpecified(opcode) {
            report.note("unknown record 0x\(hex2(opcode)) — skipped, as required")
        }
    }

    guard let firstOpcode = seen.first else {
        report.error("no records at all")
        return report
    }
    if firstOpcode != Opcode.header {
        report.error("first record is \(opcodeName(firstOpcode)); the Header must come first")
    }
    if !hasHeader { report.error("no Header record") }
    if !hasQuantization { report.error("no Quantization record") }
    if !hasFooter { report.error("no Footer record") }

    // Which chunk shape the rest of this validator is entitled to assume. A `keyframe-delta`
    // file's Chunks are keyframes and its Delta Chunks are differences against them, so the index
    // check below is about the gaussian-birth shape and about nothing else. Read from the Header
    // rather than guessed from the records, because a file that carries Delta Chunks and does not
    // say so is itself a fault.
    //
    // Asked of the reader rather than parsed here: this is the one field the whole branch turns
    // on, and a tool that read it out of the Header itself could disagree with the reader about
    // which model a file declares — which is the one disagreement that would matter.
    let keyframeDelta = (try? peekTemporalModel(bytes)) == "keyframe-delta"

    let index = chunkIndexEntries(bytes, walked)
    for (i, entry) in index.enumerated() {
        let (end, overflow) = entry.offset.addingReportingOverflow(entry.length)
        if overflow || end > UInt64(bytes.count) {
            report.error("chunk index entry \(i) points past the end of the file")
            continue
        }
        // A `keyframe-delta` file indexes both kinds: a Chunk is a keyframe and a Delta Chunk is
        // a difference against one, and an index that could only name the former could not seek
        // the model at all.
        let at = bytes[Int(entry.offset)]
        if at != Opcode.chunk && !(keyframeDelta && at == Opcode.deltaChunk) {
            report.error("chunk index entry \(i) does not point at a Chunk record")
        }
    }

    if let summary = summaryDeclaration(bytes, walked) {
        if summary.start > summary.end {
            report.error(
                "the Footer's summary starts at \(summary.start), after the summary ends at "
                    + "\(summary.end)")
        } else if let covered = coverage(bytes, walked), !covered.ok {
            report.error(
                "summary CRC mismatch: the index is untrustworthy (a streamed read still works)")
        }
    }

    if hasHeader && index.isEmpty {
        report.warn("no chunk index: this file can only be read front to back, not seeked")
    }

    // What survived the cut, which is the question the errors above do not answer.
    //
    // A cut file is invalid and every finding about it stands — but records are length-prefixed,
    // so everything complete before the cut is intact and the SDK's streamed reader keeps it.
    // Saying only that the file stopped reading leaves its holder to guess whether anything is
    // salvageable; this says how much.
    if let cut = walked.cut {
        report.note(
            "the file is cut at byte \(commas(cut.at)): \(cut.reason). The \(walked.intact) "
                + "complete records before it are intact, and a streamed reader recovers them")
    }

    if keyframeDelta {
        checkKeyframeDelta(bytes, walked, &report)
    } else {
        checkGaussianBirth(bytes, walked, index, &report)
    }

    return report
}

/// The two checks only a reader can perform: open the file, then decode it.
///
/// Opening it the way a seeking client would is where the front-matter refusals fire — an
/// unimplemented temporal model, an unimplemented quantization scheme. Decoding the chunks is
/// where the rest do, and there is no substitute for it: the framing walk steps over a chunk by
/// its declared length, so an unimplemented stream codec and an out-of-range window index are
/// both invisible to everything before this point. Both are in the invalid corpus.
private func checkGaussianBirth(
    _ bytes: [UInt8], _ walked: Walk, _ index: [IndexEntry], _ report: inout Report
) {
    do {
        _ = try SceneReader(InMemoryReader(bytes), path: .indexed)
    } catch {
        report.refused(
            "a seeking reader cannot open this file: ", asFourDGS(error), walked, nil)
        // A file that will not open will not decode either, and the second error would say the
        // same thing about the same byte.
        return
    }
    if let refusal = scanChunks(bytes, index: index) {
        report.refused("a chunk does not decode: ", refusal.error, walked, refusal.site)
    }
}

/// The same, for the temporal model whose chunks are keyframes and differences.
///
/// This is the same statement as the branch above — open the file the way a client would, and
/// decode what it carries — expressed in the reader the file's declared model actually needs.
/// The alternative, which is what the Python validator still does, is to run the gaussian-birth
/// reader over it and report its refusal as a fault in the file.
///
/// One call, because one call is the whole surface the C ABI offers for this model: the core
/// composes every chain and hands back the canonical states. So this branch cannot name the index
/// entry that refused, and cannot compose one chain at a time — the memory the composition takes
/// is the core's, and a binding that wanted per-entry control would have to reimplement the model
/// on this side of the ABI, which is exactly the second decoder this package exists not to be.
private func checkKeyframeDelta(_ bytes: [UInt8], _ walked: Walk, _ report: inout Report) {
    do {
        _ = try keyframeDeltaStatesJson(bytes, indexed: true)
    } catch {
        report.refused("a seeking reader cannot open this file: ", asFourDGS(error), walked, nil)
    }
}

/// `4dgs validate <file>` — check a file against the specification.
public func runValidate(_ path: String, _ out: TextOutput, _ err: TextOutput) -> Int32 {
    let bytes: [UInt8]
    do {
        bytes = try readWhole(path)
    } catch {
        // Not the file's fault, and not a refusal. See ``exitTool``.
        err.line("4dgs: \(path): \(sentence(asFourDGS(error)))")
        return exitTool
    }
    let report = validate(bytes)
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
