// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// What the conformance runners claim when a file will not decode.
///
/// The harness reads two things from a runner: its exit status and its stdout. Those carry
/// two different claims, and the invalid corpus only means anything while they stay apart.
/// Exit 0 with `{"refused": "<identifier>"}` says "I refused this file, and here is the rule
/// it broke" — an answer, diffed against the committed expectation. A non-zero exit says "I
/// did not produce an answer at all".
///
/// An error the refusal table does not name belongs to the second claim. Printed as
/// `{"refused": ""}` with exit 0 it becomes the first: the empty string is not an identifier
/// the format defines, so the harness is handed a refusal it cannot check, and
/// `run.py --update` — which writes what a runner prints, before parsing it — would commit
/// that as the expectation every other SDK is scored against.
///
/// Both entry points are driven as subprocesses, because stdout, stderr and the exit status
/// together are what the harness branches on, and `Runner.main` ends in `exit` so nothing
/// in-process can observe them. All three are asserted at once on purpose: the old handling
/// satisfied two of them, printing a well-formed JSON document and exiting cleanly, and only
/// the identifier inside it said anything was wrong.
import Foundation
import FourDGS
import XCTest

@testable import ConformanceSupport

/// Too short to hold the magic: a truncated transport. That is a real decode failure, and
/// one `FourDGSError.refusalCode` deliberately does not name. Both read paths reach it — the
/// streamed runner front to back, the indexed one through its opener — so it asks both the
/// same question.
private let unnamed = Data([0x34, 0x44, 0x47])

/// The magic is the one refusal a file this small can still carry a name for, which makes it
/// the control: the fix must not turn named refusals into failures on its way to turning
/// unnamed ones into failures.
private let named = Data("NOT4DGS!\n".utf8)

private struct Runs {
    let code: Int32
    let out: String
    let err: String
}

/// The built runners, wherever this checkout put them.
///
/// `swift test` and `swift build --configuration release` leave them in different
/// directories, and CI runs both, so both are looked in — starting beside the test binary
/// itself, which is where the debug build puts everything.
private func runnerExecutable(_ name: String) throws -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    var candidates: [URL] = []
    if let given = ProcessInfo.processInfo.environment["FOURDGS_SWIFT_RUNNERS"] {
        candidates.append(URL(fileURLWithPath: given))
    }
    candidates.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
    candidates.append(root.appendingPathComponent("swift/.build/debug"))
    candidates.append(root.appendingPathComponent("swift/.build/release"))
    for directory in candidates {
        let path = directory.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: path.path) { return path }
    }
    XCTFail(
        "\(name) is not built; looked in \(candidates.map(\.path).joined(separator: ", ")). "
            + "Build the package, or point FOURDGS_SWIFT_RUNNERS at the directory holding it.")
    throw CocoaError(.fileNoSuchFile)
}

/// `bytes` on disk in a directory the test owns, decoded by `name` in its own process.
private func decode(_ name: String, _ bytes: Data) throws -> Runs {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fourdgs-runner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("input.4dgs")
    try bytes.write(to: input)

    let process = Process()
    process.executableURL = try runnerExecutable(name)
    process.arguments = [input.path]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    // Read before waiting: a runner that filled a pipe buffer would otherwise deadlock here
    // rather than fail, and a hung test says nothing about the thing under test.
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Runs(
        code: process.terminationStatus,
        out: String(decoding: outData, as: UTF8.self),
        err: String(decoding: errData, as: UTF8.self))
}

final class ConformanceRunnerTests: XCTestCase {

    private let runners = ["decode_streamed", "decode_indexed"]

    func testAnUnnamedErrorIsAFailedInvocation() throws {
        for name in runners {
            let done = try decode(name, unnamed)
            XCTAssertNotEqual(
                done.code, 0, "\(name) claimed an answer for an error it cannot name")
            XCTAssertEqual(
                done.out, "", "\(name) printed a document for a failed invocation")
            XCTAssertFalse(
                done.out.contains("refused"), "\(name) printed a refusal: \(done.out)")
            XCTAssertFalse(
                done.err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(name) failed without saying why")
        }
    }

    func testANamedRefusalIsStillAnAnswer() throws {
        for name in runners {
            let done = try decode(name, named)
            XCTAssertEqual(
                done.code, 0,
                "\(name) failed the invocation for a refusal it named: \(done.err)")
            XCTAssertEqual(done.err, "")
            let parsed = try JSONSerialization.jsonObject(with: Data(done.out.utf8))
            XCTAssertEqual(parsed as? [String: String], ["refused": "magic-mismatch"])
        }
    }

    /// The rule both runners share, asked of the classifier directly: `nil` is "not one of
    /// the refusals the corpus compares", which the callers turn into a failed invocation
    /// rather than into a refusal nobody can check.
    func testOnlyAnErrorCarryingAnIdentifierIsAnAnswer() {
        XCTAssertNil(
            Runner.refusal(.truncated(offset: 0, record: "magic", needed: 8, available: 3)))
        XCTAssertNil(Runner.refusal(.unreadableSource(description: "no such file")))
        XCTAssertEqual(
            Runner.refusal(.notFourDGS(offset: 0, found: []))?.serialized(),
            JSON.object(["refused": .string("magic-mismatch")]).serialized())
    }
}
