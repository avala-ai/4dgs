// swift-tools-version:5.9
// The tools version is pinned to 5.9 deliberately: CI's macOS runner ships Swift 5.10, so
// anything newer would build on Linux and fail on the platforms this package exists for.
//
// This manifest is at the repository root and describes the Swift package only. That is not
// a claim on the other five languages: SwiftPM clones the URL it is given and looks for
// `Package.swift` at the top of that clone, so a manifest under `swift/` was invisible to
// `.package(url:)` and nobody could depend on this package at all. The sources did not move
// with it — every target below names its own path under `swift/`.
import Foundation
import PackageDescription

// Where `cargo build -p fourdgs --release` leaves the core, relative to this manifest.
//
// The package is a binding, not a second decoder: `CFourDGS` links `libfourdgs`, and SwiftPM
// is given no search path to find it in. A checkout of this repository builds the core and
// passes `-Xlinker -L…` (see swift/README.md). A consumer who resolved this package from a
// URL has no such build, and the link failure they get — `cannot find -lfourdgs` — names a
// library rather than the thing to do about it. So say it here, while the manifest is being
// evaluated and before anything is compiled.
let packageDirectory = Context.packageDirectory
let coreDirectory = packageDirectory + "/target/release"
// SwiftPM evaluates the manifest once with no real package directory — it reports "/", or
// nothing at all — while it works out which versions a tag offers. Naming "//target/release"
// there would be worse than naming nothing, so the message says which directory it means
// rather than a path that does not exist.
let coreLocation = packageDirectory.count > 1 ? coreDirectory : "the resolved checkout's target/release"
let coreLibraries = ["libfourdgs.a", "libfourdgs.dylib", "libfourdgs.so", "fourdgs.lib"]
if !coreLibraries.contains(where: { FileManager.default.fileExists(atPath: coreDirectory + "/" + $0) }) {
    print(
        """
        warning: the 4dgs Rust core is not built, so linking FourDGS will fail with \
        'cannot find -lfourdgs'. This package binds rust/fourdgs through its C ABI and needs \
        that staticlib on the linker's search path; there is no prebuilt binary to fall back \
        on yet. Inside a checkout of avala-ai/4dgs:

            cargo build -p fourdgs --release
            swift build -Xlinker -L"$PWD/target/release"

        Consuming this package by URL — .package(url: "https://github.com/avala-ai/4dgs", …) \
        — resolves, and does not yet link: the core would have to be built into \
        \(coreLocation) and that directory passed with -Xlinker -L. A binary \
        target shipping a prebuilt XCFramework is the fix, and is not done. See \
        swift/README.md, "The core is not in the box".
        """
    )
}

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
        // The C ABI, imported from rust/fourdgs/include/fourdgs.h through a module map
        // rather than a copied header. Linking needs the core's staticlib on the linker
        // search path — see swift/README.md; CI builds it before this package.
        //
        // Every call into the core goes through one file,
        // swift/Sources/FourDGS/CoreSeam.swift, which today makes about ninety-five of
        // them and carries the whole decode and encode surface. What stood here until
        // now — that those bodies "currently throw `.notImplemented`" — described the
        // skeleton and stopped being true when the seam was wired: the shared conformance
        // suite passes 105 checks through this ABI on both read paths.
        .systemLibrary(name: "CFourDGS", path: "swift/Sources/CFourDGS"),
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

        // Prints the canonical JSON for a scene built from a fixed seed, with no decoding
        // involved, so that the Swift emitter can be diffed against canonical.py before
        // there is a decoder. See swift/conformance/selftest.py.
        .executableTarget(
            name: "canonical_selftest", dependencies: ["ConformanceSupport"],
            path: "swift/conformance/canonical_selftest"),
    ]
)
