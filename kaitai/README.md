# Kaitai Struct grammar

`fourdgs.ksy` is a machine-readable description of a `.4dgs` file's **structure**: the magic, the
record framing, and the field layout of each record the
[specification](../website/docs/spec/index.md) defines. It exists so that tooling which has no
reason to link an SDK can still see inside a file — a hex viewer that labels the bytes, a one-off
script in a language none of the SDKs cover, the [Kaitai Web IDE](https://ide.kaitai.io/) when
someone needs to look at a file and explain what they are seeing.

It is also a second reader of the specification, in the same sense as the implementations: a grammar
cannot be vague, so writing one down surfaces every place the prose left a choice. That is how the
`aabb` field's type was found to be wrong in the text but right in every file
([spec §12](../website/docs/spec/index.md#12-changelog)), and it is the reason to keep this file
current rather than treat it as documentation.

One thing it says that the specification does not say plainly: the streams inside a Chunk are **not
framed as records**. §5.5 calls the block "concatenated Attribute Stream records" and §5.6 gives
Attribute Stream an opcode of `0x06`, but what is on the wire is a bare run of the §5.6 field layout
with no opcode byte and no length in front of it — the first byte of each stream is its
`attribute_id`, and `0x06` never appears as a top-level opcode in any file. The grammar models what
the files contain, which is why `attribute_stream` is reachable only from inside a Chunk and from an
SH Band Stream record.

```
kaitai-struct-compiler --target python --outdir /tmp kaitai/fourdgs.ksy
python3 kaitai/parse_corpus.py            # compile it and check the whole corpus
python3 kaitai/parse_corpus.py FILE.4dgs  # check one file
```

`ksv fourdgs.ksy FILE.4dgs` will also dump a file's structure if you have the Kaitai visualizer.

## What it does not do

**It is not a conformance implementation, and the feature matrix does not gain a column for it.**
The matrix records what the [conformance suite](../tests/conformance/) proves, and this grammar is
not eligible: a decoder claims a feature by producing the same values as every other decoder, and a
grammar produces structure. Specifically, it does not:

- **decompress anything.** A chunk's attribute streams are compressed (deflate or zstd) and stay as
  `payload` bytes here. Everything a decoder does after decompression — the byte-plane unshuffle,
  zigzag, delta and constant modes, dequantization by the grids in the Quantization record, the
  per-gaussian velocity and birth-time steps of §6.3 — is arithmetic, and Kaitai is not where
  arithmetic belongs. Neither does it decode audio payloads, which the format carries verbatim by
  design; it does expose source descriptors and moving-pose keyframes.
- **validate semantics.** It will happily parse a file whose window index points past the end of the
  Window Table, whose Chunk Index disagrees with the chunks, or whose Header claims a gaussian count
  no chunk supports. Those are all _refusals_ a conforming reader owes (§5.4, §5.5) and none of them
  is a structural property.
- **enforce ordering.** The Header first and the Footer last are structural and the grammar does
  rely on them; that the summary is one contiguous run before the Footer (§4.5) is not something a
  sequence of records can express.

Some of that is checked anyway, by `parse_corpus.py` rather than by the grammar — see below.

## What the CI job checks

The `kaitai` job in [conformance.yml](../.github/workflows/conformance.yml) compiles the grammar and
runs `parse_corpus.py` over every variant the corpus generator produces.

Parsing without an exception is deliberately **not** the whole check. A record's content is a
fixed-size substream, so a grammar that read half of a record's fields and stopped would parse every
file in the corpus and report nothing — which is the same leniency that lets a reader step over
fields appended by a later minor revision (§4.2), so it cannot simply be turned off. Instead, every
value the grammar reads is diffed against that variant's committed `.json` expectation, which is the
reference decoder's own view of the same bytes. A misplaced field shifts everything after it, and
the diff names which one.

Three structural rules are asserted on top, because they are what a _seeking_ reader depends on and
no decoder test states them directly:

- every offset/length pair in a Chunk Index frames a whole record, opcode byte included (§5.8);
- the Footer's `summary_start` points at the first Chunk Index record, and its CRC covers the run
  from there to the Footer (§4.5, §5.2);
- the Header's `flags` bit 0 agrees with whether legacy Audio or Audio Source/Data records are
  present (§7), every source id has one matching payload id, and the legacy and spatial
  representations are not mixed.

## Naming

The grammar's identifier is `fourdgs`, not `4dgs`, because a Kaitai type id becomes an identifier in
every target language and may not begin with a digit. That is the same constraint that names the
crate, the PyPI package and the Swift module; see the naming table in
[RELEASING.md](../RELEASING.md#naming). The format, the file extension and the prose are `4dgs`
everywhere, as always.
