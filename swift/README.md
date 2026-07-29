# 4dgs — Swift

**In progress.** The package decodes real files through the Rust core's C ABI. It cannot yet emit a
conformance summary, so every Swift cell in the [feature matrix](../website/docs/reference/index.md)
stays `Planned`.

`FourDGS` is a thin Swift layer over `rust/fourdgs`, for visionOS, iOS and macOS — a binding, not a
second decoder. Every call into the core goes through one file,
[`Sources/FourDGS/CoreSeam.swift`](Sources/FourDGS/CoreSeam.swift), which states the four
buffer-ownership rules the boundary holds to. Above it is ordinary Swift: value types, errors that
separate a malformed file from a legal one this build is too old for, and §3's reconstruction
arithmetic.

Scope: decoding a `.4dgs` to gaussian state at a time `t`. **RealityKit and Metal rendering are out
of scope for this repository — the SDK ends at decoded state.**

```swift
let reader = try SceneReader(path: "scene.4dgs")   // or readPath: .streamed / .indexed
let live = try reader.gaussians(at: 1.5)   // §3: the window, then marginal against the file's cutoff
let moved = live[0].state(at: 1.5)         // centre moved, opacity faded
let cost = reader.bytesForTime(1.5)        // what that seek transfers, before asking for it
```

A `SceneReader` is a class and is not `Sendable` — one open scene belongs to one thread. What comes
out of it is `Sendable`, because every array is copied out of the core's memory before it returns.

## What is not reachable yet

The ABI exposes the Header's numbers, the audio track, the chunk intervals and the gaussians. It has
no accessor for the metadata, attachment, camera, statistics or summary-offset records, nor for the
Footer's summary CRC. `Scene.recordsAvailable` reports that, so an empty `metadata` is never
mistaken for a file that carries none. The conformance runners refuse to print a partial summary for
the same reason, and their CI job stays disabled until the accessors exist.

## Building

Swift 5.9 or newer; the tools version is pinned to 5.9 because CI's macOS runner ships 5.10.

The package links the core, so build that first and put it on the linker's search path:

```bash
cargo build -p fourdgs --release
swift build --package-path swift -Xlinker -L"$PWD/target/release"
swift test  --package-path swift -Xlinker -L"$PWD/target/release"
```

The `-L` is passed on the command line rather than written into `Package.swift`, because an unsafe
flag there would make the package undependable as a versioned dependency. A published package would
ship a binary target instead; that is a distribution decision and not settled.

`conformance/` builds `decode_streamed` and `decode_indexed`, registered in
`tests/conformance/run.py` and skipped until built.

### Platforms

The core builds for visionOS, iOS, macOS and Linux on stable toolchains — the Apple targets ship a
distributed standard library, so nothing here needs a nightly compiler. CI cross-compiles and links
against each of them, because a Linux build proves nothing about the platforms this package is for.

### Two things that will bite an integrator

Both were found by CI rather than by reading, and both are properties of linking a Rust staticlib
rather than anything specific to this package.

**The linker prefers the shared library.** `cargo` emits `libfourdgs.a` and `libfourdgs.so` into the
same directory, and a linker given that directory takes the `.so`. Everything then builds and fails
at _load_ time instead — on Linux, set `LD_LIBRARY_PATH` alongside `-L`, or link the archive
explicitly. Apple platforms take the staticlib and never show this, so a green macOS build is not
evidence that a Linux one will run.

**A short read must be reported as a failure.** If you supply your own byte-range reader, returning
success after delivering fewer bytes than asked for breaks the decoder rather than truncating it
gracefully. `FourDGS` returns a truncation status in that case, and a custom transport should do the
same — an HTTP server answering `200` to a range request is a failure to report, not a response to
slice client-side.
