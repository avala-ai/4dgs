# Cross-SDK design principles

Rules every implementation in this repository follows, whatever the language. They exist
so that four SDKs behave like one format rather than four interpretations of it.

## 1. Bounded memory, always

No implementation ever buffers a whole file. The index is small, chunks are independent,
and every stream declares its decoded size before it is decoded. If an API can only work
by reading everything first, that API is wrong.

Concretely: no `readAll()` in a decode path, no unbounded accumulation across chunks, and
every allocation sized from a value the reader has already validated.

## 2. Decode is streamable and range-seekable

Two modes, both supported: front-to-back streaming that works on a pipe or a truncated
file, and indexed reads that touch only what an instant needs. Neither is an optimization
of the other; they serve different consumers and both are first-class.

## 3. I/O lives at the edges

The core of every SDK depends on one abstraction — something that can report its size and
read a byte range — and nothing else. No HTTP client, no filesystem, no platform types in
the core. Transports are separate, small, and swappable: a file handle, an HTTP range
reader, an in-memory buffer, a cache.

This is what lets the same decoder run in a browser, on a server, and in a test with a
byte array, and it is what keeps the core testable without a network.

## 4. Decoders are fast; the encoder is a reference

**Decoders should be genuinely fast**, using ordinary, well-understood techniques: typed
arrays rather than object arrays, views rather than copies where the language allows,
worker- and thread-friendly APIs, buffer reuse, streaming. A slow decoder misrepresents
the format.

**The reference encoder optimizes for clarity and correctness**, not for output size or
throughput. It produces conforming files that are easy to reason about. Rate and quality
heuristics are where encoders differentiate, and this repository is not where that
competition happens.

## 5. Decode ends at gaussian state

**Decoding ends at reconstructed gaussian state at time `t`. The format is
renderer-agnostic; rendering strategy is out of scope for this repository.**

Nothing here — code, comments, documentation, tests — describes how a renderer should
consume that state: no ordering or sorting strategy, no culling, no level-of-detail
policy, no device tiering, no budget management, no GPU or shader code. Those belong to
whatever draws the splats, which is somebody else's repository, including ours.

## 6. Errors name the problem

A decoder that refuses a file says which byte, which record, which value, and what was
expected. Implementations parse untrusted bytes; a bare exception type is not a diagnosis.
Unknown-but-legal values (an unrecognized codec, a future record type) are distinguished
in the error message from malformed ones, because the fix is different.

## 7. One vocabulary

The nouns in `website/docs/guides/concepts.md` are the nouns every SDK uses, in
identifiers and in messages. Where a language's conventions differ (casing, naming style),
follow the language; do not rename the concept.

## 8. Conformance is the contract

An SDK claims a feature by passing the conformance suite for it, and the feature matrix
records only what the suite proves. Implementations may differ in structure, API shape and
performance; they may not differ in what they decode a file to mean.
