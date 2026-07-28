# Implementation notes (non-normative)

Nothing here changes what a conforming file contains. These are the decode-side lessons that are
easy to get wrong and expensive to rediscover.

**Scope.** These notes end where decoding ends: you have reconstructed gaussian state at time `t`.
What a consumer does with that state — how it is drawn, ordered, culled, budgeted or scheduled — is
outside this repository entirely. The format is renderer-agnostic by design, and this document stays
on the decode side of that line.

---

## Reading over HTTP

A `.4dgs` file is designed to be read with range requests, and a reader that uses them well can
display an instant after transferring a small fraction of the file.

**The three-read open.** Read the last few kilobytes to get the magic and Footer; read the index
from `summary_start`; read the chunks the index says you need. In practice a first read of 64 KiB
from the tail covers the Footer and most indexes, so opening a scene costs one round trip before you
know exactly what to fetch.

**Coalesce adjacent ranges.** The chunks covering one instant are often contiguous or nearly so.
Issuing one request for a span that includes a small gap beats issuing four requests separated by a
few kilobytes — latency dominates, not bytes. A reasonable rule is to merge ranges separated by less
than roughly 64 KiB.

**Cache the coarse ranges.** In a hierarchical index, the chunks covering a wide interval are
re-fetched by every nearby seek. An LRU over decoded chunks keyed by byte range makes scrubbing
dramatically cheaper than the byte counts alone suggest, because consecutive seeks share most of
their working set.

**Verify the server honours ranges.** A server that ignores `Range` and answers `200` with the whole
body turns every chunk read into a full-file download — silently, and only visible as a bandwidth
bill. Treat a `200` where you asked for a range as an error, not as something to slice client-side.
Probing once with a `HEAD` or a one-byte range at open time is cheap insurance.

**Don't buffer the file.** Every read path in this format is bounded: the index is small, chunks are
independent, and attribute streams decode into typed arrays sized from the stream header. A reader
that calls `readAll()` first has thrown away the property the format exists to provide.

---

## Streaming versus indexed reads

Two decode modes, both legitimate:

- **Streamed.** Read records front to back, decode chunks as they arrive, never seek. This works on
  a pipe, on a truncated file, and on a file with no index. It is the right mode for validation,
  conversion and archival scans.
- **Indexed.** Read the Footer, then the index, then only what you need. This is the right mode for
  playback and scrubbing.

A library SHOULD offer both, and SHOULD make the streamed one work when `summary_start == 0` —
writers that stream to a pipe cannot always write an index.

---

## Truncation and corruption

A file cut short mid-write is common (a crash, a killed job, an interrupted upload) and recoverable:
records are length-prefixed, so a streamed reader recovers every complete record before the
truncation point. A reader SHOULD offer to salvage that prefix rather than reject the file, and MUST
NOT interpret a partial record.

The Footer's `summary_crc` covers the index only. A mismatch means the index is untrustworthy, not
that the chunks are — falling back to a streamed read is the correct recovery, not failing.

---

## Decoding efficiently

The decode path is simple arithmetic over large arrays, so the wins come from not fighting the
language:

- **Decode into typed arrays** (`Float32Array`, `Uint32Array`, `array.array`, `NumPy`), not arrays
  of objects. Structure-of-arrays is how the data is stored and how consumers want it; materializing
  per-gaussian objects costs more than everything else combined.
- **Avoid copies at the boundary.** Where the language allows a view over the received buffer rather
  than a copy, take it. The byte-plane unshuffle and the zigzag pass are the only unavoidable full
  traversals.
- **Do it off the main thread.** Decoding a chunk is pure CPU on immutable input and returns
  transferable buffers, which makes it a natural fit for a worker. Interactive consumers SHOULD
  decode off whatever thread their event loop runs on.
- **Reuse buffers across chunks.** Chunk sizes cluster tightly; a small pool of typed arrays removes
  most allocation pressure during playback.

A decoder that does these four things is fast enough that the network is the bottleneck again, which
is where it belongs.

---

## Carriage in segmented-delivery systems

The chunk index is a map from time ranges to byte ranges, which is structurally what segmented
delivery formats want. Mapping a `.4dgs` onto a segmented-delivery manifest — one entry per chunk,
or per group of chunks — is therefore mostly mechanical, and is a plausible future direction for
anyone who needs to serve these through existing video infrastructure.

We deliberately did not build version 1 on top of an existing media container. It would have brought
a large amount of structure the format does not use and coupled every implementation to that
container's toolchain, in exchange for streaming properties that length-prefixed records and a
byte-range index already provide. The mapping stays available; the dependency does not.

## Writing

- **Order matters for streaming readers.** Header first, then the records a reader needs before it
  can interpret chunks — Quantization and Window Table — then chunks, then indexes, then the Footer.
- **Independent chunks are a contract, not an optimization.** A chunk that references another breaks
  seeking for everyone.
- **Declare bounds you have verified.** The Quantization record's `bounds` map is a claim about the
  file. Re-decode what you wrote and check it before you write the claim; a bound nobody verified is
  worse than no bound, because consumers will trust it.
- **Omit what is absent.** No empty audio record, no zero-length streams, no placeholder chunks.
  Absence is cheaper than emptiness and unambiguous to readers.
