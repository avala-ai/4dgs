# Decode in Python

Two read paths, both first-class: front to back, or index-first. See the
[feature matrix](../../reference/index.md) for what the conformance suite proves today.

```sh
pip install fourdgs
```

## The whole scene, front to back

```python
import fourdgs

scene = fourdgs.read("scene.4dgs")          # a path, bytes, or a file-like object
state = scene.gaussians.state_at(1.5, scene.header.cutoff)

state["indices"]   # which gaussians exist at t = 1.5
state["centers"]   # their positions, moved by their own velocity
state["opacity"]   # their alpha, faded by their own marginal
```

This is where decoding ends. `state_at` returns index arrays plus attributes so a caller can do what
it likes with them; what happens to those numbers afterwards is not the library's concern.

Pass the file's own `cutoff` rather than relying on the default whenever you have the `Scene` — the
threshold is the file's, and it is the same constant the encoder derived its velocity grid from.

A `Scene` carries more than its gaussians: `header`, `quantization` (the grids and the error bounds
the file declares), `audio`, `camera`, `metadata`, `attachments`, `statistics`, `chunk_index`,
`summary_offsets`, `summary_crc_ok`, `skipped_opcodes` and `truncated`. `audio` is `None` when the
scene has no soundtrack, which is the common case and not an error.

`read(..., recover_truncated=True)` is the default: a file cut short mid-write yields everything
complete before the cut, with `scene.truncated` set. Pass `max_sh_band` to stop short of the file's
full spherical-harmonic degree.

## An instant, without reading the file

The indexed path opens a file the way a seeking client does — the Footer, then the index, then only
the byte ranges the instant needs.

```python
from fourdgs.indexed_reader import open_indexed, read_chunk
from fourdgs.readable import FileReadable

scene = open_indexed(FileReadable("scene.4dgs"))

scene.header.gaussian_count, scene.header.duration_sec, len(scene.index)
scene.chunks_for_time(2.5)     # the entries covering an instant
scene.chunks_for_range(2.0, 4.0)
scene.bytes_for_time(2.5)      # what that seek transfers, before asking for it

for entry in scene.chunks_for_time(2.5):
    chunk = read_chunk(FileReadable("scene.4dgs"), scene, entry)
```

`read_camera`, `read_metadata`, `read_attachments` and `read_audio` fetch the front-matter records
the same way, each by its own byte range, so opening a scene with a large embedded audio track costs
nothing extra.

## Any transport

Both readers depend on `Readable` — something that can report its size and read a byte range — and
on nothing else:

```python
class Readable(Protocol):
    def size(self) -> int: ...
    def read(self, offset: int, length: int) -> bytes: ...
```

`FileReadable` and `BytesReadable` ship with the package. An HTTP range reader is a few lines and
belongs in the consumer.

A runnable version of the indexed path, which reports what each seek costs, is
[`python/examples/decode_summary.py`](https://github.com/avala-ai/4dgs/blob/main/python/examples/decode_summary.py),
which CI runs so it cannot rot.

## Errors

Failures are typed, and the distinction matters: `MalformedFile` means the bytes are wrong,
`UnsupportedVersion` and `UnsupportedCodec` mean the file is legal and this build cannot read it,
`TruncatedFile` means it was cut short, and `BoundViolation` means a declared error bound was not
met. All derive from `FourdgsError`.

## From the command line

```sh
4dgs info scene.4dgs       # summarize the file and what seeking it costs
4dgs validate scene.4dgs   # check it against the specification
4dgs decode scene.4dgs -t 2.5
```

The [specification](../../spec/index.md) is the normative reference, [concepts](../concepts.md) is
the vocabulary, and the [implementation notes](../../spec/notes.md) collect the decode-side lessons
that are easy to get wrong.
