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

**A cut between a chunk and its spherical harmonic bands.** Each band is its own record after the
chunk it belongs to, so a cut can land between them and leave the last chunk carrying fewer bands
than the rest of the file. That is not corruption and a reader should not refuse the file over it:
bands are whole (§6.5), so the chunk cannot be given the band it never received, and zero-filling it
would fabricate appearance. Dropping the trailing chunks whose band sets are short — keeping the
longest prefix that arrived intact — is the recovery that preserves both rules at once. A reader
that treats "this chunk has fewer bands than the file" as malformed will refuse a large fraction of
all possible cut points on any file with spherical harmonics, which is a lot of recoverable files.

**Verifying the summary CRC without buffering the file.** A front-to-back reader does not learn
where the CRC's range starts until it reads the Footer, which is the last record — by which point a
reader that kept nothing has nothing to check. Buffering the whole file to solve this gives up the
property the format exists to provide, so the bounded answer is to retain the trailing run of
records that may legally sit inside a summary and check it against the Footer at the end. Per §4's
layout that run is Chunk Index, Statistics, Attachment, Attachment Index and Summary Offset records;
any other opcode means the summary has not started yet, and the run resets. The cost is the index,
which an indexed reader would have loaded anyway.

When the retained run cannot be shown to be exactly the range the Footer names, the honest report is
**"not verified"** — which is a third state, distinct from "did not match". A reader that collapses
them tells its caller a file is corrupt when all it did was decline to buffer. Readers that hold the
whole file, as the Python reference does, sidestep this entirely and can always answer verified or
failed; that is a property of how that reader was built and not a requirement on any other.

---

## Constant streams are a repeat, not a payload

A stream in `mode = 2` stores exactly `channels` symbols and an `element_count` that says how many
times to repeat them. That count owes **nothing** to the size of the payload: forty compressed bytes
can legally declare four billion elements, and every field involved is one a reader takes on trust
from the file.

So a decoder should represent a constant stream **lazily** — keep the one row and answer every index
from it — rather than materializing the repeat into an array. Materializing it allocates whatever a
crafted file asks for, from a file small enough that nothing else about it looks suspicious. The
lazy form is also simply faster, since the repeat is exactly the information the stream was
compressed to avoid stating.

The same reasoning applies one level up: check a stream's `element_count` against the count its
chunk declares **before** sizing anything from it. That turns "allocate, then notice the mismatch"
into "refuse", which is the difference between a decoder that survives a hostile file and one that
merely reports it afterwards.

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

## glTF interoperability

Non-normative, and a moving target: the glTF gaussian-splatting extension (`KHR_gaussian_splatting`)
was at **Release Candidate** status when this was written (2026-07). Check its current status before
relying on any of the below, and re-read the extension rather than this summary if the two ever
disagree.

**The relationship is complementary, not competitive.** That extension describes a static set of
gaussians. It has no temporal model — not deferred, simply absent. This format is a temporal
container whose decoded state _at one instant_ is exactly the attribute set that extension carries,
so a `.4dgs` decoded at time `t` maps onto it mechanically, and a producer of static splats loses
nothing by treating this as the time dimension on top.

### What matches with no conversion

| quantity | glTF extension                                | 4dgs                             |
| -------- | --------------------------------------------- | -------------------------------- |
| rotation | quaternion, `x, y, z, w`, pre-normalized unit | identical — see spec §3 and §6.4 |
| opacity  | linear `0–1`, post-activation                 | identical — spec §3              |
| position | scene units                                   | identical                        |
| scale    | per-axis, linear                              | identical                        |

The quaternion order was a free choice and this format already made the same one, so no component
shuffle is needed in either direction. Opacity is worth calling out because it is commonly
misstated: both store the **activated** value, not a logit, so there is no sigmoid on either side of
the conversion.

### What needs a stated transform

**The degree-0 term.** That extension carries spherical harmonics uniformly, with the degree-0
coefficient required. This format stores the resolved colour instead — linear RGB in `[0, 1]`, with
the degree-0 term already evaluated — because a decoder that only wants colour should not have to
know what a spherical harmonic is. The conversion is one line each way, with
`k = 0.28209479177387814`:

```
to glTF:    coef0 = (rgb - 0.5) / k
from glTF:  rgb   = coef0 * k + 0.5
```

That `+ 0.5` is the same convention on both sides: reconstruction sums the harmonic contributions
and adds one half.

**Higher bands.** Degrees 1–3 are optional in both, and both require whole degrees — a file carries
all of a degree's coefficients or none of them. This format stores each band as its own byte range
so a reader can decline the higher ones (spec §5.7); declining a band yields a _lower degree_, never
a partial one, so the rule is preserved rather than bent. Coefficient order within a band is
lowest-`m` first in both.

Producers converting either way should carry the phase convention through unchanged; both use the
Condon–Shortley phase, so this is a no-op that is only worth stating because getting it wrong is
silent.

### Properties that have no 4dgs equivalent

That extension requires a `kernel` (`"ellipse"`) and a `colorSpace`. This format has no kernel
property because it defines exactly one gaussian kernel and does not offer a choice; a converter
emits `"ellipse"` unconditionally. Colour space maps onto the `color_space` metadata key (see the
registry), whose two values correspond to the two the extension defines. A 4dgs file that declares
no colour space leaves a converter to pick, which is a good reason for producers to declare one.

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
