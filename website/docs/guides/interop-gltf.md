# glTF interoperability

The industry's static gaussian-splat interchange is settling on `KHR_gaussian_splatting`, the glTF
extension. This page says exactly what crosses between it and `.4dgs`, what crosses with a stated
loss, and what does not cross at all.

It is written against the extension at **Release Candidate** status —
[`KhronosGroup/glTF`](https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_gaussian_splatting)
at commit `77b44be7bef26e01fb0b140e3d5bb1716421c5e9` (2026-07-17). Release Candidate means the
attribute set is settled but the text can still move, so re-read the extension rather than this page
if the two ever disagree, and check the status before relying on anything here.

The relationship is complementary, not competitive: that extension carries **one set of gaussians**,
this format carries **gaussians on a clock**. Decoding a `.4dgs` at an instant produces exactly the
attribute set the extension holds, which is why the bridge exists and why it is shaped the way it
is.

## The commands

```bash
# a static glTF or GLB -> a single-keyframe .4dgs
4dgs from-gltf scene.glb -o scene.4dgs

# the state at one instant -> a static glTF or GLB
4dgs to-gltf scene.4dgs -o frame.glb --time 1.25
```

Both are a few lines over `fourdgs.from_gltf` and `fourdgs.to_gltf`, so anything the commands can do
a caller can do. `to-gltf` writes GLB for a `.glb` path, and JSON plus a sibling `.bin` for a
`.gltf` one.

## What maps with no conversion

| quantity | the extension                               | `.4dgs`                      |
| -------- | ------------------------------------------- | ---------------------------- |
| position | `POSITION`, scene units                     | identical                    |
| rotation | `ROTATION`, unit quaternion in `x, y, z, w` | identical — spec §3 and §6.4 |
| scale    | `SCALE`, per-axis, linear, non-negative     | identical                    |
| opacity  | `OPACITY`, linear `0–1`, post-activation    | identical — spec §3          |

The quaternion component order was a free choice and this format made the same one, so nothing is
shuffled in either direction. Opacity is worth stating because it is commonly misread: **both store
the activated value, not a logit**, so there is no sigmoid on either side of the conversion. A
converter that applies one produces a scene that is uniformly too transparent and looks plausible.

## What maps with a stated transform

### The degree-0 term

The extension carries spherical harmonics uniformly and requires `SH_DEGREE_0_COEF_0`. This format
stores the **resolved colour** instead — linear RGB in `[0, 1]` with the degree-0 term already
evaluated — so that a decoder wanting only colour need not know what a spherical harmonic is. With
`k = 0.28209479177387814`:

```
to glTF:    coef0 = (rgb - 0.5) / k
from glTF:  rgb   = coef0 * k + 0.5
```

The `+ 0.5` is the same convention on both sides. This is **lossy in one direction only**: importing
clamps `rgb` to `[0, 1]`, so a degree-0 coefficient outside roughly `±1.77` — which a well-behaved
producer does not emit, since it means a colour outside the representable range — does not survive a
round trip. Everything inside that range does, to within the container's declared colour bound.

### Higher degrees

Degrees 1–3 are optional in both, and **both require whole degrees**: a file carries all of a
degree's coefficients or none of them. Coefficient order within a degree is lowest-`m` first in
both, and both use the Condon–Shortley phase, so the phase convention carries through unchanged.
This is a no-op only worth stating because getting it wrong is silent.

The lossy part is precision. The extension stores coefficients as **float**; this format stores them
as **unsigned bytes** (spec §6.5). The reference codec maps the byte onto the interval `[-4, +4]`,
so a coefficient round-trips to within one step of `8/255 ≈ 0.031`, and a coefficient outside that
interval is clamped.

:::caution The byte-to-coefficient mapping is a codec convention, not a format guarantee

The specification is deliberate that "the stored byte is the coefficient" and that `step_sh` is an
encode-side record a decoder does nothing with. It therefore does **not** pin the affine map from
byte to float, and the extension needs a float. This converter uses `[-4, +4]`, the same interval
the PLY importer uses, and both read it from one constant (`fourdgs.quantization.SH_QUANT_LO` /
`_HI`) so that a scene converted in through one path and out through the other keeps its appearance.
A producer using a different interval will see higher-degree colour shift on conversion; pinning
this belongs in the specification, and is tracked as such.

:::

### Colour space

The extension requires `colorSpace`; this format declares it in the `color_space` metadata key. The
two sets are the same two spaces spelled differently:

| `color_space` (registry) | `colorSpace` (extension) |
| ------------------------ | ------------------------ |
| `srgb-rec709-display`    | `srgb_rec709_display`    |
| `linear-rec709-display`  | `lin_rec709_display`     |

A `.4dgs` that declares neither is exported as `srgb-rec709-display`, which is what the registry
says such a file means in practice. Producers should declare it: the same numbers look visibly
different under the two, and a consumer cannot tell them apart by inspection.

### Kernel

The extension requires a `kernel` and defines one value, `"ellipse"`. This format has no kernel
property because it defines exactly one gaussian kernel and offers no choice, so the exporter emits
`"ellipse"` unconditionally and the importer refuses anything else rather than pretending.

## Coordinate systems

glTF is right-handed with **+Y up**, in metres. This format imposes no coordinate system and records
one in the `coordinate_system` metadata key, so the conversion is only defined for a file that says
what its axes mean.

- **Importing** always yields `coordinate_system = y-up-right-handed`, because a glTF asset's frame
  is glTF's frame. There is nothing to infer.
- **Exporting** requires the scene to declare a coordinate system this converter recognizes
  (`y-up-right-handed` or `z-up-right-handed`). A file declaring nothing, or something else, is
  **refused** — pass `--coordinate-system` to say which you mean. Guessing produces an asset that is
  merely rotated, which reads as a modelling mistake rather than a conversion bug and so tends to
  get found late.

A `z-up-right-handed` scene is exported with the axis change on the **glTF node**, not baked into
the attributes. That is where the extension puts a transform, it is exact, and it leaves the
harmonics alone — the extension already asks renderers to rotate spherical harmonics by the node's
rotation.

## Node transforms on import

A glTF node's transform participates in the covariance the extension defines, so an importer has to
account for it. This one bakes what it can carry exactly and refuses the rest:

| node transform                               | on import                                          |
| -------------------------------------------- | -------------------------------------------------- |
| translation, uniform scale                   | baked into position and scale                      |
| rotation, no harmonics above degree 0        | baked into position and the gaussians' quaternions |
| rotation, with harmonics above degree 0      | **refused** — needs Wigner-D rotation of the bands |
| non-uniform scale, shear, mirror, projective | **refused** — not expressible as scale + rotation  |

A non-uniform or sheared 3×3 changes a gaussian's covariance into something that is not another
gaussian's scale-and-rotation. Baking it would silently ship a differently-shaped scene, so it is
named instead. A mesh instanced by several nodes yields one copy of its gaussians per node, which is
what instancing means once a hierarchy is flattened into a single set.

## What does not map: time

**The extension has no temporal model.** Not deferred — absent. So:

- `4dgs to-gltf` writes a **snapshot**: the reconstructed state at one instant. Velocity, birth time
  (`mu_t`), temporal extent (`sigma_t`) and validity windows end there. The opacity written is the
  instant's opacity, faded by the temporal marginal, and the position written is the centre carried
  along its velocity to that instant — not the stored centre with the clock ignored.
- A scene is therefore **a sequence of snapshots** in glTF terms, with no representation of what
  happens between them. Exporting a whole `.4dgs` as glTF means exporting many files, which is
  precisely the thing this format exists to avoid.
- Audio and camera trajectories are dropped; the extension has nowhere to put them.
- `4dgs from-gltf` writes `duration_sec = 0` with every gaussian given an infinite `sigma_t` and a
  validity window of `[0, ∞)`. That is the degenerate temporal case, and it means the asset resolves
  to the same set of gaussians at whatever instant a reader asks for. The instant a snapshot came
  from is recorded in the glTF's `asset.extras`, so an exported file does not lose its provenance.

**Our position on closing this**, stated plainly because the ecosystem discussion needs one: the
temporal dimension belongs in an extension that _extends_ `KHR_gaussian_splatting` rather than
replacing it, exactly as the base extension already anticipates for compression. The per-gaussian
additions such an extension needs are the four this format stores — a velocity, a birth time, a
temporal extent, and a validity window — and they are additive: a renderer ignoring them draws the
scene at `t = 0` and is not wrong, merely still. We would rather contribute that than fork the
attribute set, and until it exists this bridge is honest about being a snapshot.

## Compression

There is **no companion compression extension in the Khronos registry** as of the pinned commit —
`KHR_draco_mesh_compression` and `EXT_meshopt_compression` are mesh extensions and do not apply to
splat attributes. The base extension reserves the ground for one: a compression extension SHOULD
extend it and SHOULD define how its data decodes back to the base format. When one lands, importing
an asset that requires it will need that codec; this converter **refuses** any asset whose
`extensionsRequired` names an extension it does not implement, rather than decoding a subset of it
and producing a different scene.

## Round-trip guarantees

Both directions are covered by tests that build their fixtures in-process; the repository commits no
binaries.

- **glTF → `.4dgs` → glTF** returns every attribute within the bounds the intermediate file declares
  in its own Quantization record — positions within `pos`, opacity within `alpha`, scale within the
  relative `scale_rel`, the degree-0 coefficient within `rgb / k`, and higher coefficients within
  one `8/255` step. Those bounds are not this bridge's claim: the encoder re-decodes what it wrote
  and verifies them before writing them.
- **`.4dgs` → glTF at `t` → `.4dgs`** returns the canonical state at `t` — the same set of
  gaussians, their centres and opacities within twice the declared bounds, having crossed two
  quantization passes.

Gaussian **order** is not preserved and is not part of either guarantee: the encoder sorts each
chunk by Morton code, so the two files agree on the set, not on the sequence.

## Limits worth knowing

- Sparse accessors are not read. They are legal glTF and rare in splat assets; an asset using one is
  refused by name.
- Buffer URIs are resolved relative to the document and may not climb out of its directory. Network
  URIs are not fetched.
- `--sh-degree` caps the degree exported, for a consumer that wants a smaller asset. It only ever
  drops whole degrees.
