# Decode in Rust

The `fourdgs` crate is the decoder the native tier is delivered through: the C++ and Swift packages
bind to its C ABI rather than reimplementing the format. See the
[feature matrix](../../reference/index.md) for what the conformance suite proves today, and the
crate's [README](https://github.com/avala-ai/4dgs/blob/main/rust/fourdgs/README.md) for the full
surface.

The crate is named `fourdgs` because Cargo identifiers cannot start with a digit. The format, the
CLI and the file extension are always `4dgs`.

## Two read paths

Both are first-class; neither is an optimization of the other.

```rust
// Streamed: front to back. Works on a pipe, on a file with no index, and on a file
// cut short mid-write — everything complete before the cut is recovered.
let scene = fourdgs::read_path("scene.4dgs")?;
let state = scene.gaussians.state_at(1.5, scene.header.cutoff);

// Indexed: the Footer, then the index, then only the byte ranges the instant needs.
let source = fourdgs::FileReadable::open("scene.4dgs")?;
let mut reader = fourdgs::SceneReader::open(source)?;
let state = reader.state_at(1.5, 3)?;

for index in 0..reader.audio_source_count() {
    let source = reader.audio_source(index)?.expect("in range");
    let source_state = source.state_at(1.5);
    // The player combines this scene-space pose with its listener pose.
}
```

`SceneReader` uses the index when the file has one and falls back to a front-to-back read when it
does not, which is what the specification requires of a reader that meets `summary_start == 0`.

## Transports

The core depends on `Readable` — something that can report its size and read a byte range — and on
nothing else. No HTTP client, no filesystem in the decode path, no platform types.

```rust
pub trait Readable {
    fn size(&mut self) -> fourdgs::Result<u64>;
    fn read(&mut self, offset: u64, length: u64) -> fourdgs::Result<Vec<u8>>;
}
```

`FileReadable` and `BytesReadable` ship with the crate. An HTTP range reader is a dozen lines and
belongs in the consumer.

## Bounded memory

No path in the crate reads a whole file. The streamed reader takes an `io::Read` and reads one
record at a time, growing a buffer only as bytes actually arrive, so a crafted length cannot make it
allocate what the resource does not contain. The indexed reader steps over front-matter records by
their headers, so a scene with large audio payloads costs nothing to open. Audio descriptors and
source-relative payload ranges, chunks and spherical-harmonic bands are fetched independently.

## Writing

```rust
let options = fourdgs::WriteOptions {
    profile: fourdgs::quantization::Profile::Default,
    ..Default::default()
};
let bytes = fourdgs::write_to_vec(&gaussians, 8.0, &options, &fourdgs::SceneExtras::default())?;
```

Two properties are contracts rather than niceties: chunks are independent, which is what makes
seeking work at all, and output is deterministic — the same scene and options produce byte-identical
files. `WriteOptions::verify` is on by default and refuses to return a file whose measured deviation
exceeds the bounds that file is about to declare.

## Codecs

`deflate` is the format's default and is always available. `zstd` is behind an off-by-default
feature; without it, a `zstd` file is refused **by name** rather than misread.

## The C ABI

`rust/fourdgs/include/fourdgs.h` is hand-written, committed, and kept in step with `src/capi.rs`.
Four rules hold across the whole surface: nothing unwinds across the boundary, every fallible call
returns a status with results in out parameters, null is always safe to pass, and borrowed pointers
have a lifetime documented per function.

Strings read out of file bytes cross as a `(pointer, length)` pair rather than as C strings, because
the format's `string` is length-prefixed and may legally contain a NUL. The `_ex` openers take a
`fourdgs_open_mode` so a caller can force the sequential or indexed path rather than accept
auto-selection.

## Scope

Gaussian decoding ends at reconstructed gaussian state. Audio reconstruction ends at active/local
time, gain and scene-space source pose. Nothing here chooses rendering strategy, listener pose,
HRTF/panning, attenuation, occlusion or mixing.
