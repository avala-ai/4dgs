# Proposal: the object layer — per-gaussian objects, labels and rigid tracks

**Status: adopted.** The normative wire and reconstruction rules are now in
[the specification](../index.md), the assigned values are in [the registry](../registry.md), and the
Python reference plus conformance corpus implement them. This document remains the design rationale
and records the decisions behind those shorter normative sections; where wording differs, the
specification is authoritative.

Every question this design left open has been decided; the decisions are recorded in §12 and folded
into the normative text. The Rust production codec follows the normative Python reference, and
feature-matrix rows move only when the public suite proves them.

Unlike keyframe-delta, this layer is **not a temporal model**. It composes with either of the two
that exist — `gaussian-birth` today, `keyframe-delta` once it lands — and adds nothing to the
`temporal_model` field. It is an additive layer in the sense §5.15.1 gives the provenance family: a
file that omits all of it is byte-identical to the file it would otherwise have been, and a reader
that does not implement it decodes every such file correctly by skipping what it does not recognize.

---

## 1. What is missing

The format reconstructs, for any instant, a set of gaussians with position, appearance and motion
(spec §3). What it cannot express is that a **subset of those gaussians is one thing** — a vehicle,
a person, a prop — that a consumer wants to name, isolate, move, or find. Three capabilities are
absent and they are absent together:

- **Editability.** Rendering one object, hiding another, or applying an extra transform to a chosen
  object all require knowing which gaussians belong to it. Nothing in the format carries that
  grouping.
- **Semantic labelling.** A consumer that wants "the gaussians that make up the red car" — from a
  label, or from a natural-language query — has no field to read. The scene is an undifferentiated
  cloud.
- **Rigid-motion compression.** An object that moves rigidly — translating and rotating without
  deforming — is, under `gaussian-birth`, `N` per-gaussian linear velocities that all encode the
  same rigid motion badly, and under `keyframe-delta`, a restated position for every gaussian at
  every keyframe. The motion of a rigid body is six numbers per instant, not `N` trajectories, and
  the format has nowhere to put the six.

The specification already anticipated where this work lands. Spec §5.15.6, closing out the
provenance family's reserved opcodes, reserves exactly this ground:

> **Semantic and instance labels** — per-gaussian class or instance identifiers. **Static and
> dynamic segmentation** — which gaussians belong to the fixed scene and which to moving content
> [...]
>
> The last two are grouped for a reason that decides their eventual shape: both are
> **per-gaussian**, and per-gaussian data in this format travels in attribute streams inside a chunk
> (§5.6, §6.1), not in a front-matter record. Their design is therefore an attribute-id question —
> how a label id is quantized, whether a scene-wide label table lives in front matter, what a reader
> does with a stream it cannot name [...]. The reserved attribute ids in the registry's `13`–`63`
> range are where that work will land.

This proposal is that work. It follows §5.15.6's ruling to the letter: the per-gaussian grouping is
an **attribute stream**, not a front-matter record; the "scene-wide label table" §5.15.6 floats
**does** live in front matter, as a record; and the rigid-motion piece §5.15.6 did not foresee — one
rigid track per object, replacing `N` per-gaussian trajectories — is a second front-matter record.

Three pieces, then:

1. **`object_id`** — a per-gaussian `u32` attribute stream. `0` is background / unassigned. This is
   the grouping, and it is the only per-gaussian cost.
2. **Object Table** — one front-matter record. Per object: a label, an optional text-aligned
   embedding vector stored once per object, a representative anchor point, and optional coarse
   dynamics. Everything in it is advisory.
3. **SE(3) Track** — one front-matter record per object: the object's rigid pose sampled over the
   scene clock. This is the only part of the layer that changes reconstructed geometry.

---

## 2. Scope

**Designed here:** the `object_id` attribute and its exact-integer encoding; the Object Table and
SE(3) Track records at wire precision; the composition rule that layers a track onto the base
gaussian state and onto both temporal models; how the declared error bounds survive a pose
transform; the seek and forward-compatibility consequences; and the conformance corpus the layer
needs.

**Not designed here**, deliberately:

- **Non-rigid per-object deformation.** An object that bends, not just moves, is the province of the
  temporal model — `keyframe-delta`'s per-gaussian residual, or the reserved `deformation-field`. A
  track carries the rigid part; whatever is left is non-rigid and belongs to the temporal model, not
  here. §3.4 states exactly how the two layer.
- **Object hierarchy and articulation.** Parenting objects, skeletons, joint constraints — a flat
  `object_id` cannot express them and this proposal does not try. §12 notes where a future revision
  would extend.
- **How embeddings are produced.** The vector is stored; the model that produced it and the model
  that embeds a query against it are consumer-side, exactly as a renderer is. The format defines the
  bytes and the comparison, not the network.
- **Per-object appearance editing.** Recolouring or relighting an object touches spherical harmonics
  and colour, which this layer does not carry. Deferred.
- **Embedding compression.** Vectors are stored as raw `f32`. Whether they want a quantized or
  reduced-dimension form is a rate-distortion question with its own evidence, answerable later by an
  append.

---

## 3. The model

### 3.1 `object_id` — a per-gaussian attribute, exact and optional

`object_id` is a `u32` carried in an Attribute Stream (spec §5.6), attribute id `14` from the
reserved `13`–`63` range. It rides the existing per-chunk machinery exactly as `position` or
`window_index` does: one stream per chunk, `element_count` equal to the chunk's `count`, structure
of arrays, delta-coded and codec-compressed like any other stream.

- **`0` is background / unassigned.** A gaussian with `object_id = 0` belongs to no object. This is
  the default a stream's absence implies, and it is the value the whole scene carries in a file that
  has no objects.
- **The stream is optional.** A chunk may omit it, exactly as it may omit `source_index` (id 12). A
  chunk with no `object_id` stream is read as though every gaussian carried `0`. This is the "omit
  what is absent" rule (implementation notes, "Writing") applied to one more attribute.
- **`object_id` is exact — it does not quantize.** This is the one thing about it that must be
  stated outright, because every other numeric attribute in the format is quantized and a reader
  could reasonably expect a step for this one too. There is none, and there must be none:

  > Quantization recovers a **metric** value to within a declared bound: `step_pos` exists because a
  > position 1 mm from another is nearly the same position, and rounding between them loses almost
  > nothing. An id has no metric. Object `4293` is not "closer to" object `4300` than to object `7`;
  > the numbers are labels, and a label rounded to a neighbouring grid point is a **different
  > object**, not an approximation of the same one. There is no bound to declare because there is no
  > deviation that is small.

  So `object_id` is stored and read exactly, travelling through the stream's lossless integer
  pipeline — byte-plane unshuffle, zigzag, `mode` (spec §5.6) — with **no dequantization step
  applied**. The Quantization record (§5.3) carries no step for it and the `bounds` map carries no
  key for it, precisely as it carries none for `rotation_index` (id 2) or `window_index` (id 10),
  which are exact indices for the same reason. A reader that multiplies `object_id` by anything has
  misread this section.

  Attribute Stream symbols are signed 32-bit values after zigzag, while `object_id` owns the full
  unsigned 32-bit domain. The exact bridge is the two's-complement bit view: a writer maps the `u32`
  label to the `i32` with the same 32 bits before stream encoding, and a reader maps that signed
  code back to the `u32` with the same bits after stream decoding. Thus `0x7FFF_FFFF` maps to
  `2147483647`, `0x8000_0000` maps to `-2147483648`, and `0xFFFF_FFFF` maps to `-1`. This is a
  representation, not quantization: it is bijective, changes no label and gives every `u32` one
  legal four-byte stream code. An encoder MAY delta-code those signed codes only when every
  resulting delta still fits the stream's 32-bit symbol width; raw mode is always available.

This is `object_id` in full for a `gaussian-birth` file. Its behaviour under `keyframe-delta` is one
paragraph and it is in §3.4.

### 3.2 Object Table — opcode `0x24`, front matter

The scene-wide table §5.15.6 anticipated. One record for the whole file, listing every object the
producer wants to say something about. It takes opcode `0x24` — the next free number in the
provenance family (`0x20`–`0x23` are defined, `0x24`–`0x2F` reserved by §5.15.6), which is where
this work was reserved to land, so it lands there rather than spending a number elsewhere.

```
u32     object_count
u16     embedding_dim         -- dimensionality of every embedding in this file; 0 = no embeddings
        object_count × {
  u32     object_id           -- the object this entry describes; matches the object_id attribute
  string  label               -- human-readable; "" is a legal empty label
  f32[3]  anchor              -- a representative point in the file's coordinate frame (advisory)
  u8      dynamics_present     -- 0 or 1
  [ f32[3] velocity           -- present iff dynamics_present == 1
    f32[3] angular_velocity    -- radians/second about the anchor
    f32[3] acceleration ]
  u8      has_embedding        -- present iff embedding_dim > 0; absent entirely when embedding_dim == 0
  [ embedding_dim × f32 embedding ]  -- present iff embedding_dim > 0 AND has_embedding == 1
}
```

**Everything in this record is advisory.** Not one field changes a reconstructed gaussian. The
record names objects, describes them, and points a consumer at them; the geometry is untouched by
it. That is the organizing principle of the whole layer and it is worth stating before the fields:
**the only thing in the object layer that transforms geometry is the SE(3) track of §3.3.** The
Object Table is labels, search and summary; `object_id` is grouping; the track is motion. Keeping
the geometry-changing part to exactly one record is what makes the composition rule in §3.4 short.

Field by field:

- **`object_id`** ties the entry to the gaussians carrying that id. Entries MUST have distinct
  `object_id` values; **a reader MUST refuse a table with two entries for the same object**, naming
  it, for the reason §5.15.2 refuses two frames of one name — an object is referred to by id and
  nothing else, and a duplicate makes every reference ambiguous. An entry for `object_id = 0` is
  legal (a producer may label the background) but never required.
- **`label`** is free-form UTF-8 and may be empty. It is for a human and for display; a consumer
  routes on `object_id`, never on the label text.
- **`anchor`** is a single representative point — a centroid, a chosen pivot — for placing a label
  or focusing a camera. It is **not** the transform pivot (§3.3 folds the pivot into the track's
  translation), and a reader computes no geometry from it.
- **`velocity`, `angular_velocity`, `acceleration`** are an optional coarse motion summary: a
  constant-acceleration model of the object's gross movement, for a consumer that wants "roughly how
  is this object moving" — a physics estimate, a motion prior, a filter — without reading a track.
  They are a summary in the sense Statistics (§5.12) is a summary: **advisory, and never a
  substitute for the track.** When a Track (§3.3) exists for the same object, the track is
  authoritative and these numbers are its précis; when no track exists, these numbers are all a
  consumer has and it uses them at its own discretion. Normative reconstruction (§3.4) reads
  **none** of them.
- **`embedding`** is a text-aligned vector — a point in a space shared with a text encoder, so that
  a natural-language query embedded into the same space can be compared to it. It is stored **once
  per object**, never per gaussian, which is the whole economy of putting it here: an object of a
  million gaussians carries one vector. `embedding_dim` is declared once for the file (every vector
  has the same dimension) and each object states whether it carries one. The comparison is cosine
  similarity; the format stores the vector and defines the comparison, and leaves the encoder that
  produced it and the encoder that embeds the query to the consumer. See §8.

**Finiteness and count discipline.** Every `f32` in this record — anchor, dynamics, every embedding
component — MUST be finite; a reader MUST refuse a non-finite value, naming the object, for §5.3's
reason about non-finite parameters. A `NaN` in an embedding is not a small error, it poisons every
cosine similarity computed against it. And `object_count`, `embedding_dim` and the variable blocks
are the constant-stream lesson (implementation notes) one record further out: a reader MUST size the
walk from the record's own `content_length` and check each declared count against the bytes that
remain **before** allocating from it. An `object_count` of four billion in a forty-byte record is a
refusal, not an allocation.

### 3.3 SE(3) Track — opcode `0x25`, front matter

One record per object, carrying that object's rigid pose sampled over the scene clock. It is the Rig
Trajectory record (§5.15.4) pointed at a scene object instead of the capture platform, and it
borrows that record's discipline wholesale. It takes opcode `0x25`, the next free provenance-family
number after the Object Table.

```
u32     object_id          -- the object this track moves; matches the object_id attribute
u8      interpolation      -- see registry; 0 linear, 1 step
u32     sample_count
        sample_count × { f64 time; f64[4] rotation; f64[3] translation }
```

`rotation` is a unit quaternion in `xyzw` order — the same order and convention as spec §3, §6.4 and
every pose in §5.15, so no component shuffle is ever needed. A reader SHOULD renormalize it and MUST
refuse one whose norm is zero or non-finite (§5.15.3's rule). `time` is on the **scene clock** —
`f64` seconds from 0, exactly as §2 and §5.15.4 define it, and when the file carries audio §7's
clock rule applies here too.

The record inherits §5.15.4's rules verbatim, because the failures they prevent are identical:

- **`time` MUST be strictly increasing.** A reader MUST refuse a track whose times are not, naming
  the sample index: a repeated or reversed timestamp makes the interval a query lands in ambiguous.
- **Outside the sample range the pose is clamped, never extrapolated.** Before the first sample it
  is the first; at or after the last it is the last. Extrapolating a pose invents motion the object
  never had.
- **Interpolation** between samples `i` and `i+1` with `u = (t - time[i]) / (time[i+1] - time[i])`:
  `linear` lerps the translation and takes the **shortest-arc** slerp of the rotation (negating the
  second quaternion when the dot product is negative); `step` holds both at sample `i`. This is
  §5.15.4's interpolation, and the registry entry is shared.
- **`sample_count == 0`** carries no pose and is read as though the record were absent; a producer
  SHOULD omit it. **One sample** is a static placement — every query returns it, which is the
  clamping rule with nothing to interpolate.

Two rules are new, and they are what makes the track an **object** track rather than a rig
trajectory:

- **A track's `object_id` MUST NOT be `0`.** `0` is "no object", and a track needs an object to
  move. A reader MUST refuse a track naming `0`.
- **At most one track per object.** A reader MUST refuse a file with two tracks for the same
  `object_id`, naming it — the duplicate-name rule again, on the object this time. A track for an
  `object_id` that no gaussian carries, or that the Object Table does not list, is **not** an error:
  the object may exist at another level of detail, or be tracked before it is labelled. The layer's
  three pieces are independently optional, exactly as the provenance family's four are (§5.15.1).

**The pose is relative to the object's stored (rest) configuration, and this is load-bearing.** The
track does not place gaussians into the world from some object-local origin; it transforms the state
they are **already stored in**. A gaussian's stored position is where the object rests in the scene,
and the track's pose is the rigid displacement away from rest at time `t`. §3.4 gives the
arithmetic. The reason it must be relative rather than absolute is the whole of §4.6: an absolute
track would require the base gaussians to be stored in an object-local frame, so a reader that
ignored the track would see every object collapsed onto the origin — a meaningless scene — instead
of every object at rest, which is a real one. Relative-to-rest is what keeps the degraded view
valid.

### 3.4 Composition — the load-bearing rule

This is the part the rest of the proposal exists to get right: how `object_id`, a track, the base
gaussian state, and the temporal model layer into one reconstructed instant without ambiguity. The
answer is a fixed four-step order, and every step is a pure function of the one before it.

For scene time `t`:

```
1. base    -- reconstruct the per-gaussian state S(t) using the file's temporal_model:
              gaussian-birth  -> spec §3's closed form
              keyframe-delta  -> compose the chain (keyframe-delta §3.3)
           -- S(t) carries every §3 field per gaussian, object_id among them.

2. center  -- for each gaussian, the base world state, spec §3 verbatim:
              c0 = position + motion * (t - mu_t)      -- base center
              r0 = rotation                            -- base orientation

3. track   -- for each gaussian g with object_id = k:
              if k != 0 and a Track names k, with pose (R_k(t), T_k(t)) by §3.3:
                  center(t)      = R_k(t) * c0 + T_k(t)
                  orientation(t) = R_k(t) ⊗ r0
              otherwise:
                  center(t) = c0,  orientation(t) = r0     -- identity

4. shade   -- spec §3's visibility and opacity, unchanged and on the untransformed temporal fields:
              visible  = win_lo <= t < win_hi  AND  marginal >= cutoff
              marginal = sigma_t == +inf ? 1 : exp(-0.5 * ((t - mu_t) / sigma_t)^2)
              opacity  = color.a * marginal
```

Read the layering off the order:

- **The temporal model produces the base state; the track transforms it.** `keyframe-delta` and
  `gaussian-birth` are step 1 — they decide _where the base state comes from_, exactly as
  keyframe-delta's §3.3 already frames itself. The track is step 3 and never touches step 1. So the
  two compose by function application, `track ∘ base`, in that order and only that order.
- **A track is rigid; it moves `center` and `orientation` and nothing else.** Scale, colour, the
  temporal fields (`mu_t`, `sigma_t`, the window) and therefore `marginal`, `visible` and `opacity`
  are untouched. That is why step 4 runs on the base temporal fields: a rigid transform does not
  change _when_ a gaussian exists or how opaque it is, only _where_ it is and _how it is oriented_.
- **The transform is applied exactly once, after the base state is fully reconstructed.** There is
  no interleaving with the temporal model and no second application.

**The question this order answers — a gaussian with per-gaussian motion that also belongs to a
moving track.** The brief for this design named it as the load-bearing case, and the order decides
it cleanly: it is **neither forbidden nor track-wins. It composes.** The per-gaussian `motion` (or,
under `keyframe-delta`, the per-gaussian residual) moves the gaussian _within the object's own
frame_ in step 2; the track then rigidly transports the whole object in step 3. A wheel that spins
(per-gaussian motion) on a car that drives (track) is the spin composed under the drive:
`R_drive(t) * (spin at t) + T_drive(t)`. This is the intended decomposition and it is exactly what
the brief describes — the track supplies the object's **rigid** motion, `keyframe-delta` supplies
the **non-rigid residual**, `gaussian-birth` supplies **per-gaussian** motion — and they layer as
base first, track second, with no additive velocity term and no precedence rule, because function
composition needs neither.

- **`object_id` under `keyframe-delta`.** `object_id` is an ordinary attribute stream, so it rides
  keyframe chunks (absolute) and MAY be restated in a delta's update group. When it is restated it
  is an **absolute value, not a bin difference** — the same treatment `keyframe-delta` §3.5 gives
  `rotation_index`, and for a kindred reason: an id is a label, a "difference of labels" is
  meaningless, and absolute restatement costs the same few bytes on an attribute that rarely
  changes. It is therefore **not** in keyframe-delta §3.5's GOP-invariant set — an object _may_ be
  relabelled mid-GOP — but when it changes it is restated whole. The track that applies to a
  gaussian at time `t` is the one matching its `object_id` **at `t`**, composed after the delta
  chain has produced that id.

### 3.5 What a file MUST NOT do

Collected so the composition has no undefined corner:

- A gaussian MUST NOT be moved by two tracks. Enforced upstream by "at most one track per
  `object_id`" (§3.3), since a gaussian has one `object_id` at any instant.
- A track MUST NOT name `object_id = 0` (§3.3).
- A track's pose MUST NOT be applied to the temporal fields, only to `center` and `orientation`
  (§3.4). A file cannot request otherwise; there is no field for it. This is stated because a reader
  _implementing_ the layer could get it wrong, and a rigidly time-shifted gaussian is a plausible
  wrong answer.
- `object_id` MUST NOT be quantized or carry a `bounds` entry (§3.1).

None of these needs a new flag or a new field. They are properties of the records as defined, and §9
lists the refusals a reader raises when a file violates one.

---

## 4. Wire mapping

The principle is keyframe-delta's: **ride the existing machinery.** `object_id` is an attribute
stream with nothing added. The Object Table and the SE(3) Track are front-matter records in the
shape the provenance family already established. Two opcodes are spent, both from the range §5.15.6
reserved for exactly this; one attribute id is spent, from the range §5.15.6 named for exactly this.
Nothing else is new.

### 4.1 `object_id` — attribute id `14`

An Attribute Stream (§5.6) with `attribute_id = 14`. `symbol_width`, `mode`, `codec` and `channels`
are the stream's own, chosen by the encoder as for any attribute; `channels` is 1. The stream
decodes by §5.6's pipeline and the resulting integers are the object ids, used as read. No step, no
bound, no dequantization (§3.1).

`13` is spoken for by the keyframe-delta proposal's `gaussian_id`; this proposal takes `14`. The two
are designed against each other on purpose (§4.4), and a file may carry both — a `keyframe-delta`
scene with objects has `gaussian_id` (13) tying deltas to gaussians and `object_id` (14) tying
gaussians to objects, and the two ids answer different questions.

### 4.2 Object Table — opcode `0x24`

The record of §3.2. A single top-level record in the front matter, ahead of the chunks, alongside
the provenance records it is a sibling of. **It is not a summary record** (§4.5): it carries
content, and its content — an embedding per object — is unbounded in the same way a Rig Trajectory's
samples are, so it belongs with the other content records ahead of the chunks, for the reason
§5.15.1 gives. A writer emits at most one Object Table; a reader that finds two MUST refuse the file
(there is one table for one scene, and merging two is the ambiguity §5.15.2 refuses for frames).

### 4.3 SE(3) Track — opcode `0x25`

The record of §3.3. One per object, each independently range-readable, in the front matter with the
Object Table and the provenance records. **Not a summary record**, for §4.2's reason. A file with
`M` tracked objects carries `M` of these, exactly as a file with five sensors carries five Sensor
Calibration records (§5.15.3).

### 4.4 Registry additions

None of these changes the format version; each is the kind of registry addition spec §10 already
permits within version 1.

- **Attribute ids:** `14` becomes `object_id`, `u32`, exact (not dequantized), optional, `0` =
  background / unassigned. The registry's `13`–`63` row narrows by one, as keyframe-delta's addition
  of `13` narrows it by another.
- **Opcodes:** `0x24` Object Table, `0x25` SE(3) Track, both in the provenance family. §5.15's
  family table gains two `defined` rows and §5.15.6's reserved range shrinks to `0x26`–`0x2F`.
- **Object track interpolation:** a registry row that **reuses the Rig Trajectory interpolation
  values** — `0` linear (translation lerp, rotation shortest-arc slerp), `1` step. §12.1 argues why
  a distinct enum, and in particular a naive quaternion-lerp or a spline, is deliberately not
  offered, which is the same judgement §5.15.4 already made for measured poses.
- **Metadata keys** (advisory): `object_track_role`, with values `enhancement` (the default — base
  positions are already world-correct and a track is an editing convenience) and `authoritative`
  (the base is the object at a rest pose and the track carries its world motion, so a consumer that
  cannot apply tracks sees a static object). §4.6 explains why the distinction matters to a degraded
  reader and why the key is advisory rather than a refusal. `object_count` MAY also be published as
  an advisory metadata key for a consumer choosing a file before downloading it.
- **Profiles** (optional): an `objects` profile promising an `object_id` stream in every chunk and
  an Object Table present, so a consumer that requires objects can reject a file that lacks them up
  front — which is what a profile is for.

### 4.5 Seeking is unaffected

The Object Table and the tracks are front matter — small, read once at open, exactly as the
provenance records are (§5.15.1). They add no index record, and §4.5's summary — Chunk Index,
Statistics, Summary Offset, contiguous before the Footer — is untouched, so the streamed CRC
verification that rule exists to protect keeps working with no new case.

`object_id` rides in the chunks, which a reader seeking to `t` has already fetched — applying a
track at `t` needs each gaussian's `object_id`, and that id arrived with the chunk. So the layer
costs a seeking reader **nothing beyond the front-matter walk it already does**: the tracks are read
once and held (there are `M` of them, one per object, not one per gaussian), and the transform is
arithmetic on state already in hand. The seek predicate of spec §8, and of keyframe-delta §7, is
unchanged.

### 4.6 Forward compatibility — what an old reader sees

A reader that predates this layer skips all three pieces by the mechanisms the format already has,
and this is the property that makes the layer additive:

- The **Object Table (`0x24`)** and each **Track (`0x25`)** are unknown top-level records; a reader
  steps over them by `content_length` (§4.2). They are in the provenance opcode range, which such a
  reader already skips.
- The **`object_id` stream (id 14)** is an unknown attribute. A reader walks a chunk's `records`
  block by each stream's header and `payload_length` (§5.6), so it steps over an id it does not
  implement exactly as it already steps over `source_index` (12) when it does not want it. The
  required set is fixed at ids `0`–`10` for all of version 1, so any id above `10` is one a
  conforming reader skips rather than refuses.

So an old reader sees **the base scene with no object transforms applied** — every gaussian at its
stored position, doing its per-gaussian (or keyframe-delta) motion, with the rigid tracks absent.
The question §5.15.1 and keyframe-delta §5 both force is whether that degraded view is a **valid**
result or a **refusal**, and the answer here is _valid_, on the provenance precedent rather than the
temporal-model one:

> A temporal model changes what the base state **means** — keyframe-delta made ignoring the deltas a
> wrong scene, so it gates on `temporal_model` and an old reader refuses (keyframe-delta §5). The
> object layer changes nothing about the base state; it is additive metadata in the §5.15.1 sense.
> Every gaussian still has a real, correct stored position, and the base scene is complete and
> decodable without a single byte of this layer. So the layer degrades rather than refusing, exactly
> as a file without a georeference is a complete file rather than an incomplete one.

The one honest caveat is the case §3.3's relative-pose rule is built around. A producer _may_ use a
track as the sole carrier of an object's motion — storing the object at a rest pose and letting the
track move it — which is the rigid-compression win. For such a file the degraded view is
geometrically valid but shows the object frozen at rest, which is not what the producer intended.
That is what `object_track_role = authoritative` declares (§4.4): a hint to a degraded consumer that
the base is a rest pose and the motion is in the tracks it cannot read. It is advisory, not a
refusal, because refusing would deny a capable reader a file it can render perfectly — the same
reasoning §8 of the spec uses to make a badly-seeking file a metadata note rather than an error. A
producer who wants **no** degradation keeps `object_track_role` at its `enhancement` default and
stores world-correct base positions, so that dropping the track loses editability but not
correctness.

---

## 5. Versioning: additive within version 1

**The magic's version byte does not change. Existing files do not move. No frozen field changes.**
Every mechanism is one spec §10 already permits:

| what this adds                   | §10 rule that permits it                  |
| -------------------------------- | ----------------------------------------- |
| Object Table, opcode `0x24`      | new opcodes MAY be added in `0x01`–`0x7F` |
| SE(3) Track, opcode `0x25`       | new opcodes MAY be added in `0x01`–`0x7F` |
| `object_id`, attribute id `14`   | registry addition                         |
| object-track interpolation reuse | registry addition                         |
| `object_track_role` metadata key | registry addition                         |
| `objects` profile                | registry addition                         |

A version-1 file that carries none of this is valid, byte for byte, and every existing
implementation reads it unchanged. Unlike keyframe-delta, there is **no gate**: an old reader does
not refuse a file with objects, because the layer is additive and the base scene is complete without
it (§4.6). That is the difference between changing _where the state comes from_, which needs a gate,
and _adding a transform and some labels on top of it_, which does not. `temporal_model` is
untouched, and this layer composes with whatever value it holds.

---

## 6. Lessons this design inherits

The specification's discipline came from real failures; each has an analogue here.

- **Refuse, do not clamp (spec §5.4).** A duplicate `object_id` in the table, two tracks for one
  object, a track naming `0`, a non-increasing track time — all refusals that name the offending
  value, never repairs. Picking one of two tracks silently is the coin toss §5.15.5 refuses for two
  anchors.
- **Non-finite parameters (spec §5.3).** Every float in an anchor, a pose, a dynamics triple or an
  embedding MUST be finite. A non-finite pose is not a coarse pose and a `NaN` embedding is not a
  weak match; both are refusals a validator names.
- **Prove the count before you allocate (implementation notes).** `object_count`, `embedding_dim`
  and `sample_count` are checked against the bytes the record actually holds before anything is
  sized from them. This is the constant-stream lesson: a crafted count in a small record is a
  refusal, not an allocation.
- **The direction of a transform is stated because the opposite is equally plausible (spec
  §5.15.3).** §3.4 fixes `center = R * c0 + T`, pose relative to rest, applied after the base state
  — and states it because a reader that composed in the other order, or treated the pose as
  absolute, would produce a plausible wrong scene rather than an error.
- **An implementation written from the document alone (spec §5.5/§5.6, the `aabb`).** Before any of
  this is frozen, one reader should be built from this proposal and nothing else, by someone who has
  not read an encoder — which is the only way the class of error that made `aabb` read `f32[6]` for
  a `f64[6]` field is ever caught.

---

## 7. Error bounds under a pose transform

Spec §5.3's contract is that each attribute declares a maximum deviation, the grid pitch is twice
it, and `|decoded - original| <= bound` holds by construction. A layer that transforms the decoded
state has to say what becomes of that bound after the transform, and the answer here is the strong
one, for a reason as short as keyframe-delta's telescoping argument:

> **A track pose is an isometry, and it is exact. So the world-space error is the base error, moved
> but not amplified.**

### The arithmetic

Take a gaussian's base center `c0`, decoded from bins with the declared per-component bound
`|c0_decoded - c0_true| <= ε` on each axis (`ε = bounds.pos`, spec §5.3). The world center is
`c(t) = R(t) * c0 + T(t)`, with `R(t)` a rotation and `T(t)` a translation from the track.

`R(t)` and `T(t)` are stored as `f64` and interpolated in `f64` — a shortest-arc slerp and a lerp —
so within the precision the format uses everywhere for the scene clock and poses they are **exact**:
the track contributes no quantization of its own. `R(t)` is orthonormal, so it preserves Euclidean
length:

```
|| c_decoded(t) - c_true(t) ||  =  || R(t) * (c0_decoded - c0_true) ||  =  || c0_decoded - c0_true ||
```

The error vector is **rotated, not grown**. Its Euclidean norm is exactly the base error's norm,
which the per-axis bounds cap at `sqrt(3) * ε` (a box of half-width `ε` on each axis has that
circumradius). So:

```
|| c_decoded(t) - c_true(t) ||  <=  sqrt(3) * bounds.pos,   at every instant, for every track pose.
```

Two things are worth being precise about. First, the bound is stated as a **Euclidean norm**, not
per-axis, because a rotation turns a per-axis error into a mixed one — an `x` error can rotate into
`y` — so the per-axis form of §5.3's bound does not survive an arbitrary rotation, while the norm
does, exactly. A reader or validator reporting a track-composed bound MUST report the norm form;
reporting a per-axis number after a rotation would claim a bound the transform does not keep.
Second, there is **no term in `t` and no term in the track's depth or sample count**: because the
pose is exact and an isometry, the world bound is the base bound however the object moves and
however long the track is. This is the same shape of result keyframe-delta §8 reaches for its deltas
— the bound is on the reconstructed absolute state, unchanged — reached by a different mechanism:
there, integer telescoping; here, an exact isometry.

**Orientation.** The gaussian's orientation is `R(t) ⊗ r0`, and `r0` carries §6.4's
post-reconstruction angular bound `δ`. Quaternion multiplication by a unit quaternion is an isometry
on the rotation group, so the angular error is rotated, not amplified: the world orientation bound
is §6.4's `δ`, unchanged, at every instant. **Scale, colour and the temporal fields are not
transformed at all**, so their bounds are the base bounds verbatim.

### Representability

The one new failure mode is a track pose that is not a pose. A quaternion of zero or non-finite
norm, a non-finite translation, a non-increasing time — each is a refusal that names the object and
the sample (§3.3, §9), the same shape as spec §5.15.3's rule for a sensor extrinsic. There is no
accumulator to overflow the way keyframe-delta §8's composed bins can, because a track is a set of
absolute `f64` poses, not a chain of integer differences — which is one more reason the bound is
clean.

---

## 8. Editability — the capability, by mechanics only

Stated as operations on the records above, so a reviewer can see that the three capabilities of §1
fall out of the design rather than needing anything further.

- **Isolation — render one object, or hide one.** Filter gaussians by `object_id`. A consumer keeps
  the gaussians whose `object_id` equals the target (or drops them, to hide), reading the value from
  the attribute stream the chunk already carries. No extra data and no per-frame cost beyond a
  comparison. "Static versus dynamic" — the third item §5.15.6 reserved — falls out of the same
  field with no new machinery: a gaussian is dynamic exactly when its object has a track or it
  carries per-gaussian motion, and static otherwise, so the segmentation §5.15.6 anticipated is
  _derivable_ rather than a fourth thing to store.
- **Transform — move or pose an object.** Apply an **extra** SE(3) on top of the object's state,
  i.e. compose a chosen `(R_edit, T_edit)` with the track's pose in step 3 of §3.4:
  `center = R_edit * (R_k(t) * c0 + T_k(t)) + T_edit`. An editor dragging an object is choosing
  `(R_edit, T_edit)`; a producer baking an edit is folding it into the track's samples. Either way
  the arithmetic is the one composition rule, applied once more.
- **Text query — find an object by description.** Embed a natural-language query into the same space
  the object embeddings live in, compute cosine similarity against each object's vector, and rank.
  The top object's `object_id` then feeds isolation or transform above. The format's part is the
  stored vector and the stated comparison (cosine similarity over the file's one
  `embedding_dim`-dimensional `f32` space); the query encoder is the consumer's, exactly as the
  renderer is.

None of these is normative on a reader — a reader MAY implement none of them and still decode every
file correctly (§4.6). They are what the layer is _for_, described so the wire design can be checked
against them.

---

## 9. Failure modes a reader refuses

One place, so a reader can check itself against a list. Each names the offending value.

| condition                                                    | why it is not repairable                              |
| ------------------------------------------------------------ | ----------------------------------------------------- |
| two Object Table entries share an `object_id`                | every reference to that object is ambiguous           |
| two Object Table records in one file                         | there is one table for one scene                      |
| two SE(3) Track records name the same `object_id`            | a gaussian would be moved by two poses                |
| a Track names `object_id = 0`                                | `0` is "no object"; a track needs an object           |
| a Track's `time` values are not strictly increasing          | the interval a query lands in is ambiguous            |
| a Track quaternion has zero or non-finite norm               | it is not a rotation                                  |
| a non-finite anchor, pose, dynamics value or embedding entry | not a coarse value — a value only corruption produces |
| a declared count exceeds the bytes its record holds          | sizing from it allocates whatever a crafted file asks |
| an `object_id` stream carries a quantization step or bound   | `object_id` is exact and has neither (§3.1)           |

Everything **not** on this list is valid and often intentional: an `object_id` with no Object Table
(grouping without labels), a Track with no table entry (tracked before labelled), a table entry
whose `object_id` no gaussian carries (an object at another level of detail), an object with an
embedding and no track, or a track and no embedding. The three pieces are independently optional
(§3.3), and a validator MAY note the unusual combinations without a reader refusing them.

---

## 10. Conformance plan

Nothing here is real until the suite proves it. This is what would be added to the corpus generator
and the canonical summary.

### 10.1 Canonical JSON

For a variant carrying objects, the summary gains an `objects` block and the per-instant states of
keyframe-delta §11.2 gain post-transform centers, and every existing key keeps its meaning.

```json
{
  "objects": {
    "embeddingDim": 512,
    "table": [
      {
        "objectId": "7",
        "label": "vehicle",
        "anchor": [1.5, 0.0, -3.2],
        "hasDynamics": true,
        "hasEmbedding": true,
        "embeddingCrc": "…"
      }
    ],
    "tracks": [{ "objectId": "7", "interpolation": "linear", "sampleCount": "24" }]
  },
  "states": [
    {
      "t": 0.5,
      "liveCount": "256",
      "sample": { "positions": [], "objectIds": [] },
      "aggregate": { "positionSum": [], "opacitySum": 0.0 }
    }
  ]
}
```

- `objects.table` and `objects.tracks` exist so that a field no expectation mentions is a field an
  implementation can decline to decode — the reason `chunks` is in keyframe-delta's summary. An
  embedding is summarized by a CRC of its bytes, not spelled out, exactly as spherical harmonics
  are.
- **`states` carries post-transform centers.** Each state's `sample.positions` is the composed
  world-space center **after** the track transform of §3.4, and `sample.objectIds` is each sampled
  gaussian's `object_id`. This is the conformance teeth: a decoder that skips the track, or composes
  in the wrong order, produces different `positions` for a tracked gaussian and fails on that
  instant's row specifically. A `gaussian-birth` variant with a moving object cannot pass by
  decoding the base scene alone.
- The two read paths must agree, as keyframe-delta §11.2 requires: a streamed decode that applies
  the front-matter tracks to each chunk as it passes, and an indexed decode that seeks and applies
  the same tracks, MUST produce identical `states`.

### 10.2 Scenarios

New corpus variants, each crossable with `gaussian-birth` and (once it lands) `keyframe-delta`,
since the layer is orthogonal to the temporal model:

| scenario                 | shape                                                           | what it catches                                                 |
| ------------------------ | --------------------------------------------------------------- | --------------------------------------------------------------- |
| `ObjectIdsNoTable`       | an `object_id` stream, no Object Table, no tracks               | grouping stands alone; the valid-degraded ruling (§4.6)         |
| `ObjectTableStatic`      | labels, anchors, embeddings; no tracks                          | the table record; embeddings surfaced; no geometry change       |
| `ObjectMovingRigid`      | one object with a Track, translating and rotating               | the composition of §3.4; post-transform `states`                |
| `ObjectMotionUnderTrack` | a tracked object whose gaussians also carry per-gaussian motion | base-then-track order; the load-bearing case of §3.4            |
| `ObjectTrackClamped`     | a Track whose samples do not span the clip                      | clamp-not-extrapolate at both ends (§3.3)                       |
| `ObjectEmbeddingsAbsent` | a table with `embedding_dim = 0`                                | the absent-embedding path; per-object `has_embedding` machinery |
| `ObjectRelabelMidGop`    | (keyframe-delta only) `object_id` restated in a delta update    | absolute restatement of an id, not a bin difference (§3.4)      |

Crossed with the existing flags `Quantized` (the §7 bound argument is only interesting on a coarse
grid), `SHDegree2`, `UseCrc`, `UseChunkIndex`, and one variant with no index (a streamed reader
composing tracks without one).

### 10.3 Files a reader must refuse

§9's table is a second, small corpus of deliberately invalid files, each paired with the identifier
of the refusal it must produce — `duplicate-object-id`, `two-object-tables`, `duplicate-track`,
`track-names-background`, `non-increasing-track-time`, `non-unit-track-quaternion`,
`non-finite-object-value`, `count-exceeds-record`, `object-id-quantized`. This reuses the refusal-
expectation contract keyframe-delta §11.5 introduces ("an expectation may be a named refusal"); if
that contract has landed by the time this does, this proposal adds rows to it rather than a
mechanism.

### 10.4 Feature matrix rows

Added as `No` or `Planned` for every SDK, moved only by a passing suite:

- `object_id` attribute — decode
- Object Table — decode, labels and anchors surfaced
- Object embeddings — surfaced with the file's `embedding_dim`
- SE(3) Track composition — the row that proves §3.4's arithmetic
- Object isolation — filtering by `object_id`
- Encode: objects and tracks

---

## 11. What this proposal costs

Stated together so a reviewer can weigh them without assembling them from the sections above.

1. **Two opcodes**, `0x24` and `0x25`, from the provenance family's reserved range — spent where
   §5.15.6 reserved them for this, not from the general range.
2. **One attribute id**, `14`, from the range §5.15.6 named for this.
3. **Four bytes per gaussian**, and only when a file carries objects — the `object_id` stream,
   optional and absent from every file that wants no objects (§3.1).
4. **A new invariant class in readers** — §9's nine refusal conditions, most about referential
   integrity between the tracks, the table and the `object_id` stream. Real implementation surface
   in five SDKs, though smaller than keyframe-delta's fourteen because the layer adds no chain to
   walk.
5. **A composition step in the decode path** — one rigid transform per tracked gaussian per frame
   (§3.4). It is arithmetic on state already in hand, off the temporal-model path, and it is
   skippable by a reader that does not implement the layer (§4.6).
6. **A larger front matter** for a file with many objects — one embedding vector per object. Bounded
   by object count, not gaussian count, and paid once at open, not per seek (§4.5).

Against these, the layer buys the three capabilities of §1 without a second temporal model, without
a gate on old readers, and without touching the seek path — which is the argument for its shape.

---

## 12. Disposition

The design was reviewed and **accepted**. Every question it left open was ruled on; each ruling is
recorded here and folded into the section it affects, so the document has no section that
contradicts a decision and no reader has to hold both a recommendation and its outcome in mind.
Every ruling matched the design as written, which is why the sections above needed no change to
agree with them.

| #   | question                                          | ruling                                                      | folded into |
| --- | ------------------------------------------------- | ----------------------------------------------------------- | ----------- |
| 1   | Object-track interpolation enum                   | Reuse §5.15.4's registry; no naive lerp, no spline          | §3.3, §4.4  |
| 2   | `object_id` GOP-invariance under keyframe-delta   | Allow relabelling; absolute restatement, not invariant      | §3.4        |
| 3   | Embedding type and dimensionality                 | `f32`, file-level dimension, per-object presence; one space | §3.2, §4.4  |
| 4   | The `object_track_role` degraded-view hint        | Adopt it, advisory, default `enhancement`; no hard flag     | §4.4, §4.6  |
| 5   | `object_id` without an Object Table               | Valid, not refused                                          | §4.6, §9    |
| 6   | Number coordination with keyframe-delta and audio | `0x24`/`0x25`/id `14` stand; re-verify against main at impl | §4.4        |

Three of these are the same judgement applied more than once, and it is the judgement the existing
specification makes everywhere: the format takes on the smaller thing. Ruling 1 declines a spline
and a naive quaternion-lerp because a measured pose does not want invented intermediates — §5.15.4's
argument, reused. Ruling 4 declines a hard refusal flag because a capable reader should not be
denied a file it renders perfectly — keyframe-delta §5's argument, reused. Ruling 5 declines to
couple two independently-optional pieces, which is the §5.15.1 discipline the provenance family is
built on. In each case the alternative would have been decided by implementation rather than by
design.

### 12.1 Object-track interpolation: reuse the trajectory enum, or a distinct one?

The brief names `step / linear / slerp` as the interpolation modes. The Rig Trajectory record
(§5.15.4) already faced this and offers exactly two: `step`, and `linear` — where `linear` means the
translation is lerped and the rotation is a **shortest-arc slerp**. So `slerp` is not a third mode;
it is the rotation half of `linear`, and a "linear" that lerped quaternion components naively would
take the long way round between nearby poses, which §5.15.4 spells out as the bug the shortest-arc
negation exists to prevent.

**Decided: reuse §5.15.4's interpolation registry unchanged** — `0` linear (lerp + shortest-arc
slerp), `1` step — and offer neither a naive quaternion-lerp nor a `spline`. §5.15.4 declines
`spline` for measured poses because it invents intermediate poses the platform never occupied; an
object track is the same kind of measurement and the same argument applies. This maps the brief's
three names onto two modes with no loss: `step`, and `linear` with `slerp` as its rotation. If the
maintainer wants a genuine spline for _authored_ (non-measured) object motion, that is a distinct
registry value with its own argument, and adding it later is an append.

### 12.2 Is `object_id` GOP-invariant under keyframe-delta?

`object_id` is exact, so unlike `sigma_t` it _can_ be delta-composed without a bound problem, and an
object relabel mid-GOP is representable. §3.4 recommends allowing it, **restated absolutely** (like
`rotation_index`), rather than adding it to keyframe-delta §3.5's invariant set.

**Decided: allow relabelling, absolute restatement.** It costs nothing to permit, an id difference
is meaningless so absolute is the only sensible form, and forbidding it would be a rule with no
failure behind it — "a rule with no failure behind it" is exactly the reason not to add one. The
stricter alternative, had it been chosen, was "`object_id` MUST NOT appear in an update group"
folded into keyframe-delta §3.5's table as a fifth row; it was not.

### 12.3 Embedding type and dimensionality

The design stores one `embedding_dim`-dimensional `f32` vector per object, dimension declared once
for the file. **Decided: `f32`, file-level dimension, per-object presence flag** — the vector is
per-object and therefore cheap, so precision is the safe default and `f16` or a quantized form is a
later append if the object counts ever make it matter. Two adjacent questions were pinned the same
way: a file carries **one** embedding space, not more (a second is an append); and `embedding_dim`
has **no hard cap**, because the count-before-alloc rule of §3.2 already makes an absurd one a
refusal rather than an allocation.

### 12.4 The `object_track_role` degraded-view hint

§4.6 recommends an advisory metadata key so a reader that cannot apply tracks knows whether the base
positions are world-correct (`enhancement`) or a rest pose the track moves (`authoritative`).
**Decided: adopt the key, advisory, default `enhancement`.** The alternative — a hard flag that
makes an old reader refuse an `authoritative` file — was considered and rejected for keyframe-delta
§5's reason: a well-formed file a capable reader renders perfectly should not be refused by a reader
that merely lacks a feature. The key carries no weight in reconstruction, which reads none of it, so
it stays purely a hint to a degraded consumer.

### 12.5 Should `object_id` without an Object Table be a refusal?

The brief floats it. §4.6 and §9 answer **no**: the grouping stands alone, isolation and transform
work from the id and the tracks without a single label, and the table only adds names and search.
**Decided: valid, not refused** — an unlabelled grouping is a real and useful file, and refusing it
would couple two independently-optional pieces the way §5.15.1 is at pains not to.

### 12.6 Opcode and attribute-id coordination

This layer spends opcodes `0x24`/`0x25` from the provenance family and attribute id `14`.
keyframe-delta, now merged, spends opcode `0x10` (Delta Chunk) and attribute id `13`. None of these
overlap, and a single file may carry all of them (§4.1) — a `keyframe-delta` scene with objects has
`gaussian_id` (13) tying deltas to gaussians and `object_id` (14) tying gaussians to objects.

**Decided: `0x24`/`0x25` and id `14` stand, and the opcode table is re-verified against `main` at
implementation time.** The verification is not a formality. While this design was under review a
separate change claimed opcode `0x10` for an Audio Source record — the number keyframe-delta's Delta
Chunk already holds on `main` — so there is now a live opcode collision in the tree, and it is being
resolved separately. It does not touch this layer's numbers, which are in a different range
entirely, but it is the reason the ruling is "re-verify" rather than "land in either order": the
opcode space is being spent by more than one design at once, and the only safe assignment is one
checked against the merged table at the moment of landing, not one assumed free from when it was
written. The one shared surface with keyframe-delta remains the refusal-expectation harness contract
(§10.3), which keyframe-delta §11.5 introduced and this reuses.

---

## 13. Deliberately deferred

Named so the boundary is a decision rather than an omission, in the shape spec §10.1 uses:

- **Object hierarchy and articulation.** A flat `object_id` cannot express a parent-child relation,
  a skeleton, or a joint. It is the obvious next capability and it is out of scope here; a future
  revision would add a relation record referencing `object_id` values, and the flat layer is a
  subset of it.
- **Non-rigid per-object motion beyond the temporal model.** The track is rigid by construction; an
  object that deforms is carried by `keyframe-delta`'s residual or the reserved `deformation-field`,
  which is why §3.4 layers them rather than duplicating them.
- **Per-object appearance editing.** Recolouring or relighting an object needs to reach colour and
  spherical harmonics, which this layer does not touch. Deferred with per-gaussian SH editing (spec
  §10.1).
- **Embedding compression and multiple embedding spaces.** One `f32` space per file, stored raw
  (§12.3). Both are appends when the evidence asks for them.
- **Source timing.** The third item §5.15.6 reserved — per-gaussian acquisition timestamps — is
  untouched here and stays reserved; it is unrelated to objects.

## 14. Implementation sequence

The sequence is now an audit trail:

1. `0x24`, `0x25` and attribute id `14` were re-verified free against `main`.
2. The normative specification, changelog and registry entries landed together.
3. The Python reference implements streamed and indexed decode, encode, and reconstruction.
4. The public corpus carries membership, a table, an embedding, a moving track, and post-transform
   states on both read paths.
5. Python and Rust are marked `Yes` only after both of their runners pass the same public variant.
