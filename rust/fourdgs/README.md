# 4dgs — Rust

Decoder for the 4dgs container format, and the **C ABI the native tier is delivered through**: the
C++ and Swift packages bind to `include/fourdgs.h` rather than reimplementing the format.

The crate is `fourdgs` because Cargo identifiers cannot start with a digit. The format is `4dgs`
everywhere else.

## Status

Decoding is complete and proved by the shared conformance suite — 28 variants over both read paths,
run in this repository's CI.

Encoding is complete too. Python's encoder is the _reference_ one, optimized for being obviously
correct and the one the corpus is generated from; this is the _production_ one, which is why it
verifies its own error bounds on every gaussian rather than trusting the grid arithmetic to have
been right. It is gated by `rust/encode-roundtrip.sh`, which re-encodes every corpus variant and
requires the Rust and Python decoders to agree on the result.

The crate is `publish = false` until there is a release to publish.

## Reading

Two modes, both first-class. Neither is an optimization of the other.

```rust
// Streamed: front to back. Works on a pipe, on a file with no index, and on a file cut
// short mid-write — everything complete before the cut is recovered.
let scene = fourdgs::read_path("scene.4dgs")?;
let state = scene.gaussians.state_at(1.5, scene.header.cutoff);

// Indexed: the Footer, then the index, then only the byte ranges the instant needs.
let source = fourdgs::FileReadable::open("scene.4dgs")?;
let mut reader = fourdgs::SceneReader::open(source)?;
let state = reader.state_at(1.5, 3)?;
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
belongs in the consumer, not here.

## Bounded memory

No path in this crate reads a whole file. The streamed reader takes an `io::Read` and reads one
record at a time, growing a buffer only as bytes actually arrive — a crafted length cannot make it
allocate what the resource does not contain. The indexed reader walks the front matter by stepping
over record **headers**, so a scene with an embedded audio track costs nothing to open, and fetches
each chunk and each spherical harmonic band by its own byte range.

## Features

| feature | default | effect                                                                             |
| ------- | ------- | ---------------------------------------------------------------------------------- |
| `zstd`  | off     | Decode `zstd` streams. Without it, such a file is refused **by name**, not misread |

`deflate` is the format's default codec and is always available.

## The C ABI

`include/fourdgs.h` is hand-written, committed, and kept in step with `src/capi.rs`. Four rules hold
across the whole surface:

1. **Nothing unwinds.** Every entry point runs inside `catch_unwind`; a defect becomes
   `FOURDGS_STATUS_INTERNAL` rather than undefined behaviour in the caller's runtime.
2. **Every fallible call returns a status**, with results in out parameters that a non-`OK` status
   leaves untouched.
3. **Null is always safe to pass.**
4. **Borrowed pointers have a stated lifetime**, documented per function in the header.

`cargo build` produces `libfourdgs.a` and `libfourdgs.{so,dylib}` alongside the rlib.
`tests/capi_smoke.c` is a C program that links against them and checks the header compiles as C,
every symbol links, and the documented null and error behaviour holds:

```sh
cargo build --release -p fourdgs
cc -std=c11 -I rust/fourdgs/include rust/fourdgs/tests/capi_smoke.c \
   -o capi_smoke target/release/libfourdgs.a -lm -lpthread -ldl
./capi_smoke tests/conformance/data/OneWindow-UseChunkIndex-UseCrc-WithAudio.4dgs
```

## Writing

```rust
let options = fourdgs::WriteOptions { profile: fourdgs::quantization::Profile::Default, ..Default::default() };
let bytes = fourdgs::write_to_vec(&gaussians, 8.0, &options, &fourdgs::SceneExtras::default())?;
```

Two properties are contracts rather than niceties. **Chunks are independent** — nothing in one
references another, which is what makes seeking work at all. And **output is deterministic**: the
same scene and options produce byte-identical files, run after run.

`WriteOptions::verify` is on by default. It decodes every chunk back and refuses to return a file
whose measured deviation exceeds the bounds the file is about to declare, because a bound nobody
checked is worse than no bound — consumers will trust it.

## Conformance

The runners live in `rust/conformance` and are wired into the shared harness:

```sh
python3 tests/conformance/generate.py
cargo build --release --workspace
python3 tests/conformance/run.py --runner rust
rust/encode-roundtrip.sh
```

## Fuzzing

`tests/fuzz.rs` mutates files this crate's own encoder produced and asserts one invariant: **any
input at all produces either a decoded scene or a typed error.** Never a panic, never a hang, never
an allocation out of proportion to the input. Three things are measured rather than hoped for — a
counting global allocator caps the peak of each decode, each decode is timed, and every one runs
inside `catch_unwind`. The C ABI is fuzzed alongside the two Rust read paths, because a panic
crossing that boundary is undefined behaviour in the caller's runtime rather than an error it can
handle.

Seeds are encoded rather than read from the corpus, so `cargo test` runs it with nothing generated
first. Mutations are seeded, so a failure names the seed and step that produced it.

It has already earned its keep. It found a record reader that reserved a declared length before
checking it against the file — `Read::read_to_end` on a `Take` reserves the limit up front — and an
offset that overflowed on a corrupt length field. Both are the class of bug that a corpus of
well-formed files cannot reach.

## Scope

Decoding ends at reconstructed gaussian state at time `t`. Nothing in this crate describes how that
state is drawn, ordered, culled or budgeted — the format is renderer-agnostic and so is this.
