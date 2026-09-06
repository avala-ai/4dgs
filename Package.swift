// swift-tools-version:5.9
// The tools version is pinned to 5.9 deliberately: CI's macOS runner ships Swift 5.10, so
// anything newer would build on Linux and fail on the platforms this package exists for.
//
// This manifest is at the repository root and describes the Swift package only. That is not
// a claim on the other five languages: SwiftPM clones the URL it is given and looks for
// `Package.swift` at the top of that clone, so a manifest under `swift/` was invisible to
// `.package(url:)` and nobody could depend on this package at all. The sources did not move
// with it — every target below names its own path under `swift/`.
import PackageDescription

// Apple consumers get the immutable, checksummed core published by the Rust 0.7.1 release. The
// manifest is evaluated on macOS for every Apple destination, so one binary target covers macOS,
// iOS and visionOS device and simulator slices. Linux CI deliberately keeps the source-built
// system-library route: that is where the Swift binding is tested against the current checkout's
// C ABI rather than against the last published one.
#if os(macOS)
let cFourDGSTarget: Target = .binaryTarget(
    name: "CFourDGS",
    url: "https://github.com/avala-ai/4dgs/releases/download/releases/rust/v0.7.1/fourdgs-core-apple-0.7.1.xcframework.zip",
    checksum: "1e68e9c1b8f126f1d304c482aa6e7a2d92374fc70c8aa07abd7254798dd99387"
)
#else
let cFourDGSTarget: Target = .systemLibrary(
    name: "CFourDGS", path: "swift/Sources/CFourDGS")
#endif

let package = Package(
    name: "FourDGS",
    platforms: [.visionOS(.v1), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FourDGS", targets: ["FourDGS"]),
        // `4dgs`, the same name the Rust and C++ tools install under. The product carries the
        // name because a Swift module cannot start with a digit; the executable a user runs is
        // what the name is for.
        .executable(name: "4dgs", targets: ["FourDGSCommand"]),
    ],
    targets: [
        // The C ABI. Apple hosts import it from the published XCFramework above; Linux
        // imports rust/fourdgs/include/fourdgs.h through the source module map and CI puts
        // the checkout's staticlib on the linker search path.
        //
        // Every call into the core goes through one file,
        // swift/Sources/FourDGS/CoreSeam.swift, which today makes about ninety-five of
        // them and carries the whole decode and encode surface. What stood here until
        // now — that those bodies "currently throw `.notImplemented`" — described the
        // skeleton and stopped being true when the seam was wired: the shared conformance
        // suite passes 105 checks through this ABI on both read paths.
        cFourDGSTarget,
        .target(name: "FourDGS", dependencies: ["CFourDGS"], path: "swift/Sources/FourDGS"),
        .testTarget(name: "FourDGSTests", dependencies: ["FourDGS"], path: "swift/Tests/FourDGSTests"),

        // `4dgs`, the inspect-and-validate tool. A library plus a three-line executable, so
        // the tests drive the whole tool — arguments in, output and exit code out — without
        // spawning a process.
        .target(
            name: "FourDGSTool", dependencies: ["FourDGS", "CFourDGS"],
            path: "swift/Sources/FourDGSTool"),
        .executableTarget(
            name: "FourDGSCommand", dependencies: ["FourDGSTool"],
            path: "swift/Sources/FourDGSCommand"),
        .testTarget(
            name: "FourDGSToolTests", dependencies: ["FourDGSTool", "FourDGS", "CFourDGS"],
            path: "swift/Tests/FourDGSToolTests"),

        // The conformance runners. Two executables, because the suite tests two read paths
        // and they have to be able to disagree.
        .target(
            name: "ConformanceSupport", dependencies: ["FourDGS"], path: "swift/conformance/Support"),
        .executableTarget(
            name: "decode_streamed", dependencies: ["ConformanceSupport"],
            path: "swift/conformance/decode_streamed"),
        .executableTarget(
            name: "decode_indexed", dependencies: ["ConformanceSupport"],
            path: "swift/conformance/decode_indexed"),
        // What those two executables claim about a file they will not decode: a named
        // refusal is an answer on stdout, and anything else is a failed invocation. The
        // tests spawn the built binaries, because `Runner.main` ends in `exit` and the
        // three things the harness reads — stdout, stderr, status — cannot be observed
        // from inside the process.
        .testTarget(
            name: "ConformanceRunnerTests", dependencies: ["ConformanceSupport", "FourDGS"],
            path: "swift/Tests/ConformanceRunnerTests"),

        // The other direction: re-encode a variant's gaussians through the core's writer and
        // write a file the cross-language encode gate diffs against the Rust reference.
        .executableTarget(
            name: "encode_roundtrip", dependencies: ["FourDGS"], path: "swift/conformance/encode_roundtrip"),

        // The same direction for the other temporal model. Separate because it produces a
        // sequence of populations rather than re-encoding one scene, and because its gate
        // grades it differently: there is no second keyframe-delta encoder here to diff
        // against, so the claim is made against the Python reference's decode.
        .executableTarget(
            name: "encode_keyframe_delta", dependencies: ["FourDGS"],
            path: "swift/conformance/encode_keyframe_delta"),

        // Prints the canonical JSON for a scene built from a fixed seed, with no decoding
        // involved, so that the Swift emitter can be diffed against canonical.py before
        // there is a decoder. See swift/conformance/selftest.py.
        .executableTarget(
            name: "canonical_selftest", dependencies: ["ConformanceSupport"],
            path: "swift/conformance/canonical_selftest"),
    ]
)
