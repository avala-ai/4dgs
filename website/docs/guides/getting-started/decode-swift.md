# Decode in Swift

`FourDGS` is a thin Swift layer over the Rust core, for visionOS, iOS and macOS — a binding, not a
second decoder. Every call into the core goes through one file,
[`Sources/FourDGS/CoreSeam.swift`](https://github.com/avala-ai/4dgs/blob/main/swift/Sources/FourDGS/CoreSeam.swift),
which states the four buffer-ownership rules the boundary holds to. Above it is ordinary Swift:
value types, errors that separate a malformed file from a legal one this build is too old for, and
the specification's reconstruction arithmetic.

See the [feature matrix](../../reference/index.md) for what the conformance suite proves today, and
the package's [README](https://github.com/avala-ai/4dgs/blob/main/swift/README.md) for its current
status.

## Decode

```swift
let reader = try SceneReader(path: "scene.4dgs")   // or readPath: .streamed / .indexed
let live = try reader.gaussians(at: 1.5)   // the window, then marginal against the file's cutoff
let moved = live[0].state(at: 1.5)         // centre moved, opacity faded
let cost = reader.bytesForTime(1.5)        // what that seek transfers, before asking for it

for (index, source) in reader.scene.audioSources.enumerated() {
    let sourceState = try reader.audioSourceState(index, at: 1.5)
    let encodedPrefix = try reader.audioSourceData(index, length: min(source.dataSize, 4096))
    // scene-space pose + local playback time; the player supplies the listener
}
```

A `SceneReader` is a class and is not `Sendable` — one open scene belongs to one thread. What comes
out of it is `Sendable`, because every array is copied out of the core's memory before it returns.
Source descriptors are populated on open, but their `data` arrays remain empty; `dataSize` is known
without transfer and `audioSourceData` performs the requested bounded payload read.

## Building

Swift 5.9 or newer. The package links the core, so build that first and put it on the linker's
search path:

```bash
cargo build -p fourdgs --release
swift build --package-path swift -Xlinker -L"$PWD/target/release"
swift test  --package-path swift -Xlinker -L"$PWD/target/release"
```

The `-L` is passed on the command line rather than written into `Package.swift`, because an unsafe
flag there would make the package undependable as a versioned dependency.

## Two things that will bite an integrator

Both were found by CI rather than by reading, and both are properties of linking a Rust staticlib
rather than anything specific to this package.

**The linker prefers the shared library.** `cargo` emits `libfourdgs.a` and `libfourdgs.so` into the
same directory, and a linker given that directory takes the `.so`. Everything then builds and fails
at _load_ time instead — on Linux, set `LD_LIBRARY_PATH` alongside `-L`, or link the archive
explicitly. Apple platforms take the staticlib and never show this, so a green macOS build is not
evidence that a Linux one will run.

**A short read must be reported as a failure.** If you supply your own byte-range reader, returning
success after delivering fewer bytes than were asked for breaks the decoder rather than truncating
it gracefully. `FourDGS` returns a truncation status in that case, and a custom transport should do
the same — an HTTP server answering `200` to a range request is a failure to report, not a response
to slice client-side.

## Scope

Decoding a `.4dgs` to gaussian state and audio source state at `t`. Rendering and listener-relative
spatialization are out of scope: the player owns HRTF/panning, attenuation, occlusion and mixing.
