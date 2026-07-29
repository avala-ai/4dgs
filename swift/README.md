# 4dgs — Swift

**In progress.** The package, the API surface and the conformance runners exist; decoding does not
yet, because this is a binding rather than a second implementation.

`FourDGS` is a thin Swift layer over the Rust core's C ABI, for visionOS, iOS and macOS. Every call
into the core goes through one file —
[`Sources/FourDGS/CoreSeam.swift`](Sources/FourDGS/CoreSeam.swift), which also states the
buffer-ownership rule at the boundary — and its bodies throw `FourDGSError.notImplemented` until
`rust/fourdgs/include/fourdgs.h` lands. Everything above the seam is real Swift and is tested: the
value types, the errors, the two readers, and §3's visibility arithmetic.

Scope: decoding a `.4dgs` to gaussian state at a time `t`. **RealityKit and Metal rendering are out
of scope for this repository — the SDK ends at decoded state.**

```swift
var reader = try IndexedReader(FileReader(path: "scene.4dgs"))
let live = try reader.gaussians(at: 1.5)   // §3: the window, then marginal against the file's cutoff
let moved = live[0].state(at: 1.5)         // centre moved, opacity faded
```

Two read paths, both first class: `StreamedReader` walks a file front to back and works on a pipe or
a truncated file; `IndexedReader` reads the Footer and the index and then only the byte ranges an
instant needs. Neither is an optimization of the other.

Every Swift cell in the [feature matrix](../website/docs/reference/index.md) stays `Planned` until
the conformance suite proves otherwise, which is that table's own rule.

## Building

Swift 5.9 or newer. The tools version is pinned to 5.9 because CI's macOS runner ships 5.10.

```bash
swift build          # from swift/
swift test
```

`conformance/` builds `decode_streamed` and `decode_indexed`, which `tests/conformance/run.py`
invokes the way it invokes every other language's runners. They are registered there already and are
skipped until built.
