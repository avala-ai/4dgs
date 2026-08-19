# 4dgs — Swift

The package decodes real files through the Rust core's C ABI and is checked by the shared
conformance corpus on both read paths.

`FourDGS` is a thin Swift layer over `rust/fourdgs`, for visionOS, iOS and macOS — a binding, not a
second decoder. Every call into the core goes through one file,
[`Sources/FourDGS/CoreSeam.swift`](Sources/FourDGS/CoreSeam.swift), which states the four
buffer-ownership rules the boundary holds to. Above it is ordinary Swift: value types, errors that
separate a malformed file from a legal one this build is too old for, and §3's reconstruction
arithmetic.

Scope: decoding a `.4dgs` to gaussian state and audio source state at time `t`. **RealityKit, Metal
rendering and listener-relative spatialization are out of scope.**

```swift
let reader = try SceneReader(path: "scene.4dgs")   // or readPath: .streamed / .indexed
let live = try reader.gaussians(at: 1.5)   // §3: the window, then marginal against the file's cutoff
let moved = live[0].state(at: 1.5)         // centre moved, opacity faded
let cost = reader.bytesForTime(1.5)        // conservative cold-seek transfer bound
let sourceState = try reader.audioSourceState(0, at: 1.5)
```

A `SceneReader` is a class and is not `Sendable` — one open scene belongs to one thread. What comes
out of it is `Sendable`, because every array is copied out of the core's memory before it returns.

## The manifest is at the repository root

`Package.swift` is at the top of the repository, not in this directory, and the sources it names
stay here — every target in it carries a `path:` under `swift/`.

That is SwiftPM's rule rather than a preference: it clones the URL it is given and looks for
`Package.swift` at the top of the clone. A manifest at `swift/Package.swift` cannot be reached by
`.package(url:)` at all, so the whole package was undependable while it lived here. The root of a
six-language repository belonging to one of them is the price, and it was judged the cheaper one
against maintaining a generated mirror repository.

```swift
.package(url: "https://github.com/avala-ai/4dgs", from: "0.1.0")
```

The versions that resolves against come from plain `vX.Y.Z` tags on this repository, because those
are the only tags SwiftPM reads — the `releases/<lang>/vX.Y.Z` tags every other package here is cut
from are invisible to it. **A bare `v0.1.0` tag is the Swift package's version and nothing else**;
it says nothing about Python, Rust, TypeScript, C++ or Dart. See
[RELEASING.md](../RELEASING.md#swift-tags-look-repository-wide-and-are-not).

Read the next section before you write that line into a manifest, though.

## The core is not in the box

**`FourDGS` links the Rust core, and this package ships no prebuilt copy of it.** Resolving the
package fetches Swift sources and a module map; it does not fetch a `libfourdgs`. Nothing here
builds until one is on the linker's search path.

Inside a checkout of this repository that is one `cargo` invocation, below. Outside one — a consumer
who resolved the package from its URL — it currently means building the core from the resolved
checkout by hand and passing its directory with `-Xlinker -L`, which is not something to ask of
anyone. The fix is a binary target pointing at a prebuilt `.xcframework` attached to a GitHub
Release with its checksum, built for visionOS, iOS and macOS; it is not done. Until it is, **the
package resolves and does not link out of tree.**

The manifest says so itself: if it finds no `libfourdgs` in `target/release` under the package
directory, evaluating it emits a warning naming what is missing and how to supply it, so the first
thing anyone sees is that sentence rather than `cannot find -lfourdgs` seven times.

## Building

Swift 5.9 or newer; the tools version is pinned to 5.9 because CI's macOS runner ships 5.10.

The package links the core, so build that first and put it on the linker's search path:

```bash
cargo build -p fourdgs --release
swift build --scratch-path swift/.build -Xlinker -L"$PWD/target/release"
swift test  --scratch-path swift/.build -Xlinker -L"$PWD/target/release"
```

Both commands run from the repository root, where the manifest is. `--scratch-path` is not cosmetic:
`tests/conformance/run.py` looks the runners up at `swift/.build/release`, and it keeps SwiftPM's
build directory inside the language it belongs to rather than at the root of a repository five other
languages share.

The `-L` is passed on the command line rather than written into `Package.swift`, because an unsafe
flag there would make the package undependable as a versioned dependency — the same reason the
manifest warns about the missing library instead of pointing at it.

`conformance/` builds `decode_streamed` and `decode_indexed`, registered in
`tests/conformance/run.py` and skipped until built.

## `4dgs`, the tool

Two commands over the same binding, for the moment somebody is holding a file that will not open and
wants to know _where_ it stops being a 4dgs file.

```bash
LD_LIBRARY_PATH="$PWD/target/release${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  swift run -Xlinker -L"$PWD/target/release" 4dgs inspect scene.4dgs
LD_LIBRARY_PATH="$PWD/target/release${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  swift run -Xlinker -L"$PWD/target/release" 4dgs validate scene.4dgs
```

`inspect` walks the records — offset, opcode, content and total length, and whether the Footer's
summary checksum covers that record and agrees. `--json` prints the same walk for a script. A file
that was cut is walked as far as it goes and then says at which byte, and how many complete records
before it a streamed reader keeps.

`validate` checks the file and, when the reader refuses it, prints the refusal identifier and the
byte it fired at beneath the finding it belongs to — the same identifiers the conformance corpus is
written against, and the same bytes the Rust and C++ tools print. Exit codes: `0` valid, `1` refused
or invalid, `2` warnings or incomplete validation, `3` the tool could not run.

The tool's own tests run it in-process, so `swift test` covers the commands and their exit codes;
they read the generated corpus and skip themselves when it is not on disk.

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
