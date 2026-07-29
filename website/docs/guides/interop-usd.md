# OpenUSD interoperability

The industry's scene-graph interchange is OpenUSD, and as of **OpenUSD v26.03** it carries gaussian
splats natively: the [Alliance for OpenUSD](https://aousd.org/blog/openusd-v26-03/) added a
first-class `ParticleField3DGaussianSplat` prim through its Emerging Geometry Interest Group,
alongside a reference `hdParticleField` renderer. This page says exactly what crosses between that
schema and `.4dgs`, what crosses with a stated loss, and what does not cross at all.

It is written against the schema as published at **openusd.org** and implemented in
[`PixarAnimationStudios/OpenUSD`](https://github.com/PixarAnimationStudios/OpenUSD) at USD
**26.08**, cross-checked against the reference PLY-to-USD converter
`extras/imaging/examples/hdParticleField/py3dgsPlyToUsd.py`. The schema is settled but the runtime
moves, so re-read the schema rather than this page if the two ever disagree.

The relationship is the same one the [glTF bridge](./interop-gltf.md) has, with the same shape: the
schema carries **one set of gaussians**, this format carries **gaussians on a clock**. Decoding a
`.4dgs` at an instant produces exactly the attribute set the schema holds. USD is a richer target
than glTF in two ways this bridge uses, called out below.

## The commands

```bash
# a static ParticleField3DGaussianSplat USD -> a single-keyframe .4dgs
4dgs from-usd scene.usdc -o scene.4dgs

# the state at one instant -> a static ParticleField3DGaussianSplat USD
4dgs to-usd scene.4dgs -o frame.usda --time 1.25

# the whole scene as USD time samples, one file that plays
4dgs to-usd scene.4dgs -o scene.usda --animated --fps 30
```

Both are a few lines over `fourdgs.from_usd` and `fourdgs.to_usd`, so anything the commands can do a
caller can do. Import reads `.usd`, `.usda`, `.usdc` and `.usdz`; export writes `.usd`, `.usda` or
`.usdc` (packaging a `.usdz` is out of this bridge's scope).

## The dependency

Reading a binary `.usdc` crate or a `.usdz` package means running USD's own runtime; this bridge
uses [`usd-core`](https://pypi.org/project/usd-core/), the reference `pxr` build the OpenUSD project
publishes to PyPI, rather than hand-rolling a crate reader it could not keep correct. That runtime
is large, so it is an **optional extra**: the core `fourdgs` package stays lean, and the USD
commands gate on its presence.

```bash
pip install 'fourdgs[usd]'
```

Without it, `4dgs from-usd` / `to-usd` print one line naming the extra and exit non-zero; every
other command is unaffected.

## What maps with no conversion

| quantity | the schema                              | `.4dgs`                            |
| -------- | --------------------------------------- | ---------------------------------- |
| position | `positions` (`point3f[]`), stage units  | identical                          |
| rotation | `orientations` (`quatf[]`)              | identical — see below              |
| scale    | `scales` (`float3[]`), per-axis, linear | identical — activated, not log     |
| opacity  | `opacities` (`float[]`), linear `0–1`   | identical — activated, not a logit |

A USD `quatf` is `(real, i, j, k)`, and once read into an array its components land as `x, y, z, w`
— the same order this format stores, the same free choice made on both sides, so no component is
shuffled in either direction. **Scale and opacity are the activated values**: USD stores
`exp(scale)` and `sigmoid(opacity)`, exactly as this format does, so there is no activation on
either side of the conversion. A converter that applies one produces a scene that looks plausible
and is uniformly wrong.

## What maps with a stated transform

### The degree-0 term

The schema stores spherical harmonics as one flattened per-vertex list,
`radiance:sphericalHarmonicsCoefficients` (`float3[]`), with the degree-0 term as coefficient 0 and
`radiance:sphericalHarmonicsDegree` naming the highest whole degree. This format stores the
**resolved colour** instead — linear RGB in `[0, 1]` with the degree-0 term already evaluated — so a
decoder wanting only colour need not know what a spherical harmonic is. With
`k = 0.28209479177387814`:

```
to USD:    coef0 = (rgb - 0.5) / k
from USD:  rgb   = coef0 * k + 0.5
```

This is **lossy in one direction only**: importing clamps `rgb` to `[0, 1]`, so a degree-0
coefficient outside roughly `±1.77` — a colour outside the representable range, which a well-behaved
producer does not emit — does not survive a round trip. Everything inside that range does, to within
the container's declared colour bound.

### Higher degrees

Degrees 1–3 are optional. The schema stores `(degree + 1)²` coefficients per vertex — 4, 9 or 16 —
and this bridge reads a count that is not one of those as an error rather than guessing a partial
degree. Coefficient order matches: the schema's per-vertex order after the DC term is this format's
band order, so nothing is reshuffled.

The lossy part is precision. The schema stores each coefficient as **float**; this format stores
them as **unsigned bytes** on the interval `[-4, +4]` — a byte `b` is the coefficient
`-4 + b · 8/255` (spec §6.5). A coefficient round-trips to within one step of `8/255 ≈ 0.031`, and
one outside the interval is clamped. That mapping is the specification's, shared with the glTF
bridge and the PLY importer.

### Colour space

The USD schema's radiance is spherical-harmonic coefficients defined in **linear light**, and it
carries **no colour-space token**. So a plain USD asset is imported as `linear-rec709-display`, and
this bridge **does not convert** colours on export — converting would bake an assumption the schema
does not state. To keep a `.4dgs` that declares `srgb-rec709-display` from silently losing that on a
round trip, the exporter records the scene's `color_space` in the prim's `customData`
(`fourdgs:colorSpace`), which the importer reads back; USD has no native field for it.

## Coordinate systems and units

This is where USD earns something over glTF. glTF is fixed at **+Y up in metres**, so a Z-up scene
had to be rotated onto a node. **USD carries the up axis and the unit as stage metadata**, so this
bridge writes them there and rotates nothing:

- The `upAxis` stage metadata is `Y` or `Z`, mapped to `coordinate_system` `y-up-right-handed` or
  `z-up-right-handed`. USD is always right-handed, so handedness never varies.
- The `metersPerUnit` stage metadata is carried in and out as the `meters_per_unit` metadata key.
- Geometry is **untouched** — no axis flip, and therefore no Wigner-D rotation of the harmonics,
  which is a case the glTF bridge has to refuse. A Z-up scene with degree-3 harmonics round-trips
  through USD cleanly where glTF cannot carry it under a rotating node.

**Importing** always yields a known `coordinate_system`, because the stage says which axis is up.
**Exporting** requires the scene to declare one this bridge recognizes; a file declaring nothing, or
something other than the two right-handed systems, is **refused** — pass `--coordinate-system` to
say which you mean. Guessing produces an asset that is merely rotated, which reads as a modelling
mistake rather than a conversion bug and so gets found late.

## Prim transforms on import

A transform on the splat prim participates in the covariance the schema defines, so an importer has
to account for it. This one bakes what it can carry exactly and refuses the rest — the same table as
the glTF bridge, because it is the same problem:

| prim transform                               | on import                                          |
| -------------------------------------------- | -------------------------------------------------- |
| translation, uniform scale                   | baked into position and scale                      |
| rotation, no harmonics above degree 0        | baked into position and the gaussians' quaternions |
| rotation, with harmonics above degree 0      | **refused** — needs Wigner-D rotation of the bands |
| non-uniform scale, shear, mirror, projective | **refused** — not expressible as scale + rotation  |

A prim instanced several times over — a USD point-instancer or repeated references — yields one copy
of its gaussians per placement once the hierarchy is flattened into a single set.

## Time: what USD carries that glTF cannot

**glTF has no temporal model, so its export is a single snapshot.** USD attributes can be
**time-sampled**, so this bridge offers two export modes:

- `4dgs to-usd … --time t` writes a **snapshot**: the reconstructed state at one instant, as static
  attribute values. Velocity, birth time (`mu_t`), temporal extent (`sigma_t`) and validity windows
  end there. The opacity written is faded by the temporal marginal and the position is the centre
  carried along its velocity to that instant — not the stored centre with the clock ignored. The
  instant is recorded in the prim's `customData` (`fourdgs:timeSec`) so the snapshot keeps its
  provenance.
- `4dgs to-usd … --animated --fps F` writes the scene resolved at each frame over its duration as
  USD **time samples** — **one file that plays**. This is the genuine advantage: a whole `.4dgs`
  becomes a single USD asset a DCC can scrub, rather than the many files glTF would need.

Two honest caveats on `--animated`. Each frame is an **independent reconstruction**, so per-frame
gaussian counts vary; USD time samples permit that, and a viewer holds each frame until the next
rather than interpolating between differently-sized sets — a flipbook, not a tween. And what USD's
static schema carries is those discrete frames, **not** this format's continuous per-gaussian
temporal model, which is resolved away into them exactly as any renderer sampling the scene would
see it.

**Our position on closing this**, stated plainly: the per-gaussian temporal additions — a velocity,
a birth time, a temporal extent, a validity window — belong in a USD applied API schema that
_extends_ `ParticleField3DGaussianSplat`, so a renderer ignoring it draws the scene at `t = 0` and
is merely still rather than wrong. That is the same additive position the glTF guide takes, and
until such a schema exists this bridge is honest about writing frames.

## Round-trip guarantees

Both directions are covered by tests that build their USD fixtures in-process; the repository
commits no binaries.

- **USD → `.4dgs` → USD** returns every attribute within the bounds the intermediate file declares
  in its own Quantization record — positions within `pos`, opacity within `alpha`, scale within the
  relative `scale_rel`, the degree-0 coefficient within `rgb / k`, and higher coefficients within
  one `8/255` step. Those bounds are the encoder's verified claim, not this bridge's.
- **`.4dgs` → USD at `t` → `.4dgs`** returns the canonical state at `t` — the same set of gaussians,
  their centres and opacities within twice the declared bounds, having crossed two quantization
  passes.

Gaussian **order** is not preserved and is not part of either guarantee: the encoder sorts each
chunk by Morton code, so the two files agree on the set, not on the sequence, and the tests match
gaussians by nearest centre.

## Limits worth knowing

- Half-precision attribute variants (`positionsh`, `scalesh`, …) are read if a prim authors them
  instead of the float ones, but export always writes the float attributes.
- `--sh-degree` caps the degree exported, for a consumer that wants a smaller asset. It only ever
  drops whole degrees.
- Export writes text or binary USD (`.usda` / `.usdc`); it does not package a `.usdz`. Import reads
  all four, `.usdz` included.
