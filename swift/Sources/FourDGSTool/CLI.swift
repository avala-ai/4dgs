// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// `4dgs`: walk a `.4dgs` file's records, and say why one is refused.
///
/// Two commands, one positional and one flag. A parser for that is shorter than the paragraph
/// justifying a dependency for it, and it keeps the tool's whole dependency tree at `FourDGS` and
/// the core it links.
///
/// The tool is expected to agree with the other SDKs' validators. Where a command exists in more
/// than one, it reads the same records, prints the same findings in the same words and exits the
/// same way; a difference between them on one file is a bug in one of them, not a matter of taste.
///
/// Everything here takes its arguments as strings and prints to sinks the caller supplies, so the
/// unit tests drive the whole tool — exit code and output together — without spawning a process.

import Foundation
import FourDGS

/// Exit codes, which are the only part of a command-line tool another program reads.
///
/// ``exitFailed`` and ``exitTool`` are the split that matters. `1` is an answer about the file:
/// it was read, and it is bad. `3` is the absence of an answer — no such file, an argument this
/// tool does not understand — and a pipeline that saw `1` for both could not tell a corrupt asset
/// from a typo in a path. A tool that exits 1 for both is indistinguishable from a broken one.
public let exitOk: Int32 = 0
public let exitFailed: Int32 = 1
public let exitWarnings: Int32 = 2
public let exitTool: Int32 = 3

/// Somewhere a line of output goes. A protocol so a test can hold the lines and the process can
/// write them.
public protocol TextOutput: AnyObject {
    func write(_ text: String)
}

extension TextOutput {
    public func line(_ text: String) { write(text + "\n") }
}

/// Output a test reads back.
public final class TextBuffer: TextOutput {
    public private(set) var text = ""

    public init() {}

    public func write(_ text: String) { self.text += text }

    public func contains(_ needle: String) -> Bool { text.contains(needle) }
}

/// Output the process writes.
public final class StandardStream: TextOutput {
    private let handle: FileHandle

    public static let out = StandardStream(FileHandle.standardOutput)
    public static let err = StandardStream(FileHandle.standardError)

    private init(_ handle: FileHandle) { self.handle = handle }

    public func write(_ text: String) { handle.write(Data(text.utf8)) }
}

/// A whole file, for the commands that need one.
///
/// `validate` does: the summary checksum has to cover a contiguous region to mean anything, and
/// the reader is handed the same bytes rather than a second transport that could disagree with
/// this walk. Cross-SDK principle 1 is about decode paths, and the decode this performs is chunk
/// by chunk.
public func readWhole(_ path: String) throws -> [UInt8] {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw FourDGSError.unreadableSource(description: "cannot open \(path) for reading")
    }
    return [UInt8](data)
}

/// The usage text, which is also where the exit codes are documented.
public let usage = """
    4dgs — inspect and validate .4dgs files

    usage:
      4dgs validate <file>               check a file against the specification
      4dgs inspect <file> [--json]       walk the records: offset, opcode, length, crc
      4dgs --version
      4dgs --help

    options:
      --json          machine-readable output (inspect)

    exit codes:
      0  fine                       2  valid, with warnings
      1  refused, or invalid        3  the tool could not run (no such file, bad usage)

    """

/// What `--version` prints.
///
/// `unreleased` rather than a number, because the package has none: `swift/CHANGELOG.md` has one
/// heading and it is `[Unreleased]`, and a tool that answered `0.1.0` would be claiming a release
/// that nobody can fetch. The line becomes a version the day the package has one.
public let toolVersion = "4dgs (Swift) unreleased"

/// Parse the arguments and run the command. Returns the process's exit code.
public func run(_ arguments: [String], out: TextOutput, err: TextOutput) -> Int32 {
    guard let first = arguments.first else {
        out.write(usage)
        return exitOk
    }
    // A request that was served, not a failure.
    if first == "-h" || first == "--help" || first == "help" {
        out.write(usage)
        return exitOk
    }
    if first == "-V" || first == "--version" || first == "version" {
        out.line(toolVersion)
        return exitOk
    }

    let isValidate = first == "validate"
    let isInspect = first == "inspect"
    guard isValidate || isInspect else {
        err.line("4dgs: unknown command `\(first)`\n")
        err.write(usage)
        return exitTool
    }

    var file: String?
    var json = false
    for argument in arguments.dropFirst() {
        if argument == "--json" {
            json = true
        } else if argument.hasPrefix("-") && argument != "-" {
            err.line("4dgs: unknown option `\(argument)`\n")
            err.write(usage)
            return exitTool
        } else if file == nil {
            file = argument
        } else {
            err.line("4dgs: \(first) takes one file\n")
            err.write(usage)
            return exitTool
        }
    }
    guard let file else {
        err.line("4dgs: \(first) needs a file\n")
        err.write(usage)
        return exitTool
    }
    if json && isValidate {
        err.line("4dgs: validate has no --json output\n")
        err.write(usage)
        return exitTool
    }
    return isValidate ? runValidate(file, out, err) : runInspect(file, json: json, out, err)
}
