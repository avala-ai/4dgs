// swift-tools-version:5.9
// The tools version is pinned to 5.9 deliberately: CI's macOS runner ships Swift 5.10, so
// anything newer would build on Linux and fail on the platforms this package exists for.
import PackageDescription

let package = Package(
    name: "FourDGS",
    platforms: [.visionOS(.v1), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FourDGS", targets: ["FourDGS"])
    ],
    targets: [
        // The SDK. Pure Swift today: every call into the Rust core goes through one file,
        // Sources/FourDGS/CoreSeam.swift, whose bodies currently throw `.notImplemented`.
        // Wiring the C ABI replaces those bodies and adds a CFourDGS system-library target
        // here; nothing else in the package moves.
        // The C ABI, imported from rust/fourdgs/include/fourdgs.h through a module map
        // rather than a copied header. Linking needs the core's staticlib on the linker
        // search path — see README.md; CI builds it before this package.
        .systemLibrary(name: "CFourDGS", path: "Sources/CFourDGS"),
        .target(name: "FourDGS", dependencies: ["CFourDGS"]),
        .testTarget(name: "FourDGSTests", dependencies: ["FourDGS"]),

        // The conformance runners. Two executables, because the suite tests two read paths
        // and they have to be able to disagree.
        .target(name: "ConformanceSupport", dependencies: ["FourDGS"], path: "conformance/Support"),
        .executableTarget(
            name: "decode_streamed", dependencies: ["ConformanceSupport"], path: "conformance/decode_streamed"),
        .executableTarget(
            name: "decode_indexed", dependencies: ["ConformanceSupport"], path: "conformance/decode_indexed"),

        // The other direction: re-encode a variant's gaussians through the core's writer and
        // write a file the cross-language encode gate diffs against the Rust reference.
        .executableTarget(
            name: "encode_roundtrip", dependencies: ["FourDGS"], path: "conformance/encode_roundtrip"),

        // Prints the canonical JSON for a scene built from a fixed seed, with no decoding
        // involved, so that the Swift emitter can be diffed against canonical.py before
        // there is a decoder. See conformance/selftest.py.
        .executableTarget(
            name: "canonical_selftest", dependencies: ["ConformanceSupport"],
            path: "conformance/canonical_selftest"),
    ]
)
