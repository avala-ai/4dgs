# Encode a scene in Python

The Python package is the reference implementation — the one the conformance corpus is generated
from, optimized for being obviously correct. See the [feature matrix](../../reference/index.md) for
what is implemented today.

```sh
pip install fourdgs
```

## A scene is a `GaussianSet` and a duration

Gaussians are held structure-of-arrays, one NumPy array per attribute. Every array is `float32` and
`n` rows long; `rotations` are `xyzw`, `colors` are red, green, blue and alpha, and `motions` are
units per second.

```python
import fourdgs

gaussians = fourdgs.GaussianSet(
    positions=positions,  # (n, 3)
    scales=scales,  # (n, 3), linear
    rotations=rotations,  # (n, 4), xyzw, normalized
    colors=colors,  # (n, 4), red, green, blue, alpha
    motions=motions,  # (n, 3), units per second
    mu_t=mu_t,  # (n,) birth time
    sigma_t=sigma_t,  # (n,) temporal extent; inf means "never fades"
    win_lo=win_lo,  # (n,) validity window start
    win_hi=win_hi,  # (n,) validity window end
)

fourdgs.write("scene.4dgs", gaussians, 8.0)
```

`sigma_t` may hold `inf`, meaning the gaussian never fades inside its window. That is a value rather
than a sentinel: it survives encode and decode as infinity, and readers expose it as such.

`write` takes a path or any file-like object and returns the number of bytes written. Audio sources
and a `CameraTrajectory` are optional; a scene without them carries nothing for them.

```python
source = fourdgs.AudioSource(
    source_id=7,
    name="speaker",
    codec="opus",
    channel_layout="mono",
    data=encoded_opus,
    duration_sec=8.0,
    position=(1.5, 0.75, -0.5),
    keyframes=[
        fourdgs.AudioSourceKeyframe(0.0, (1.5, 0.75, -0.5), (0, 0, 0, 1)),
        fourdgs.AudioSourceKeyframe(8.0, (-1.5, 1.0, 0.5), (0, 1, 0, 0)),
    ],
)
fourdgs.write("scene.4dgs", gaussians, 8.0, audio_sources=[source])
```

Positions interpolate linearly and rotations use shortest-path quaternion SLERP. `AudioTrack`
remains accepted as a legacy non-spatial writer input.

A complete, runnable version of the above — including generating the arrays — is
[`python/examples/encode_synthetic.py`](https://github.com/avala-ai/4dgs/blob/main/python/examples/encode_synthetic.py),
which CI runs so it cannot rot into a snippet that no longer works.

## Options

`WriteOptions` carries the encoder's decisions. The defaults produce an indexed, CRC-checked,
deflate-compressed file at the `default` quantization profile.

```python
options = fourdgs.WriteOptions(
    profile="default",  # "fine" | "default" | "coarse"
    min_chunk_gaussians=2048,  # chunk granularity, together with max_depth
    write_index=True,  # the chunk index; without it a reader must stream
    write_crc=True,
    sh_bands=3,
)
fourdgs.write("scene.4dgs", gaussians, 8.0, options=options)
```

Two of these are worth understanding rather than accepting.

**`cutoff`** is the Header's marginal visibility threshold, and it is not only metadata: it sets the
support constant the per-gaussian velocity grid is derived from, so encoder and decoder must agree
on it — and they do, by reading it from the file.

**`verify`** is on by default. The encoder decodes back what it just wrote and refuses to return a
file whose measured deviation exceeds the bounds that file is about to declare. A declared bound
nobody checked is worse than no bound, because consumers will trust it.

## From a PLY sequence

A directory of per-frame gaussian splat PLY files, in name order, converts directly:

```sh
4dgs convert frames/ -o scene.4dgs --fps 30 --profile default
```

The same conversion is available as `fourdgs.convert.convert_ply_sequence(directory, fps=30.0)`,
which returns the `GaussianSet` and the duration for you to write yourself.

## Checking the result

```sh
4dgs info scene.4dgs       # summarize the file and what seeking it costs
4dgs validate scene.4dgs   # check it against the specification
4dgs decode scene.4dgs -t 2.5
```

The [specification](../../spec/index.md) is the normative reference for everything above, and
[concepts](../concepts.md) is the one-page vocabulary.
