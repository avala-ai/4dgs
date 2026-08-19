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
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

func refuseMagic(_ bytes: [UInt8]) -> FourDGSError {
    let head = Array(bytes.prefix(magic.count))
    do {
        _ = try SceneReader(InMemoryReader(head))
    } catch let error as FourDGSError {
        return error
    } catch {
        return .unreadableSource(description: "\(error)")
    }
    return .notFourDGS(offset: 0, found: head)
}

public func sentence(_ error: FourDGSError) -> String {
    switch error {
    case .unsupportedCodec(0, "Chunk", let message, _): return message
    case .malformed(0, "file", "", let reason, _): return reason
    case .truncated(0, let message, 0, 0): return message
    case .core(_, let message, _): return message
    default: return "\(error)"
    }
}

public func asFourDGS(_ error: Error) -> FourDGSError {
    (error as? FourDGSError) ?? .unreadableSource(description: "\(error)")
}

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
    public private(set) var brokenPipe = false
    public private(set) var failure: Error?

    public static let out = StandardStream(FileHandle.standardOutput)
    public static let err = StandardStream(FileHandle.standardError)

    /// Ignore the signal so the throwing write API can distinguish EPIPE from other failures.
    /// Without this, Linux kills `4dgs inspect file | head` before Swift can see the error.
    private static let ignoresBrokenPipeSignal: Void = {
        #if canImport(Darwin) || canImport(Glibc)
            _ = signal(SIGPIPE, SIG_IGN)
        #endif
    }()

    init(_ handle: FileHandle) {
        _ = Self.ignoresBrokenPipeSignal
        self.handle = handle
    }

    private static func isBrokenPipe(_ error: Error) -> Bool {
        var system = error as NSError
        // swift-corelibs-foundation wraps POSIX write failures in NSCocoaErrorDomain; Darwin may
        // hand the POSIX error through directly. Follow the bounded Foundation error chain so the
        // same executable recognizes both shapes without treating another write error as EPIPE.
        for _ in 0..<4 {
            #if canImport(Darwin) || canImport(Glibc)
                if system.domain == NSPOSIXErrorDomain && system.code == Int(EPIPE) { return true }
            #endif
            guard let underlying = system.userInfo[NSUnderlyingErrorKey] as? NSError else {
                return false
            }
            system = underlying
        }
        return false
    }

    public func write(_ text: String) {
        guard failure == nil, !brokenPipe else { return }
        do {
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            if Self.isBrokenPipe(error) {
                brokenPipe = true
                return
            }
            failure = error
        }
    }
}

/// Turn buffered stream state into the process result. A downstream reader closing a pipe is a
/// successful pipeline; every other output failure is diagnosed and remains a tool failure.
///
/// A broken pipe does not manufacture a failure, and it does not erase one either. The exit code
/// is a verdict about the *file*, reached before any of it was written, and `head` walking away
/// changes nothing about the file. Returning `exitOk` here meant
/// `4dgs validate corrupt.4dgs | head -1` exited 0 — so a CI step piping this tool through
/// `head`, `grep -m1`, or any early-exiting reader was told a corrupt file was fine.
public func processExit(_ code: Int32, out: StandardStream, err: StandardStream) -> Int32 {
    if out.brokenPipe || err.brokenPipe { return code }
    guard let failure = out.failure ?? err.failure else { return code }
    err.line("4dgs: cannot write output: \(failure)")
    return exitTool
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
      0  validation complete       2  warnings, or incomplete (not proof of validity)
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
