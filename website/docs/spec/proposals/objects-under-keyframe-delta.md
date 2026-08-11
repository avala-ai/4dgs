# Proposal: the object layer under `keyframe-delta`

**Status: proposed, not normative, not implemented.** This document resolves
[#79](https://github.com/avala-ai/4dgs/issues/79). It states where object-track composition sits
relative to delta application, closes the two smaller holes that answer depends on, and names the
conformance variant that would pin it. Nothing here is in force until it is folded into
[the specification](../index.md).

The layer and the temporal model were designed a revision apart, each correctly, and neither says
what happens when a file carries both. Five implementations would each guess, and the guesses would
not agree — because, as §2.3 shows, the reference's current guess is already wrong in a way that
produces plausible output rather than an error.

---

## 1. What the format says today

### 1.1 The pieces are individually clear

**Composition is defined on the base state.** [§3](../index.md) reconstructs `base_center` and
`orientation` from the stored fields and then says:

> When a non-zero `object_id` has an Object Track (§5.15.7), the decoder then applies that track's
> pose `(R(t), T(t))` exactly once, after reconstructing the base state:
>
> ```
> center      = R(t) * base_center + T(t)
> orientation = R(t) ⊗ rotation
> ```

§6.6 restates it as an ordering: "first reconstruct the complete base state, including per-gaussian
motion, then apply the one matching rigid track to center and orientation."

**`object_id` is an ordinary optional attribute stream.** §6.1: "the required set for version 1 is
position, scale, rotation index, rotation, colour, opacity, motion, `mu_t`, `sigma_t`, flags and
window index. `source_group`, `source_index` and `object_id` are optional." §6.6 gives it attribute
id `14` and the exact two's-complement bridge.

**The provenance family is orthogonal to the temporal model.** §5.15: "Every record in the family is
**optional**." Nothing in §5.15.6 or §5.15.7 mentions `temporal_model`, and nothing in §11 excludes
the family. The object-layer changelog note in §13 says the layer "composes with either of the two
[temporal models]".

**`keyframe-delta` reconstruction ends in §3.** [§11.3](../index.md) is unusually explicit:

> The composed state `S` is a set of gaussians in exactly the state §3 describes — the same fields,
> the same types — and **§3's arithmetic then applies verbatim**. This model changes _where the
> state comes from_ and nothing about what the state means.

### 1.2 What that leaves open

Read together, §11.3 and §3 arguably already answer the composition question: the chain produces a
§3 state, §3 says a track is applied to a §3 state, therefore the track is applied after the chain.
That reading is right and this proposal adopts it — but "arguably already answers" is exactly the
condition that produces five different implementations, and §11.3's "§3's four lines" predates the
object layer, so it names four lines that no longer describe all of §3.

Two smaller questions have no reading at all, and the composition rule is unusable without them:

1. **Is `object_id` in a delta's update group a bin difference or an absolute value?**
   [§5.18](../index.md) says of the update group: "Every other stream present carries **bin
   differences** against the reference state." By the letter of that sentence a restated `object_id`
   is a difference of labels — object `12` minus object `7` is `5`, which is not an object. §11.5
   makes `rotation_index` and `rotation` absolute by exception, and forbids `sigma_t`, `flags` and
   `window_index` in an update group outright. `object_id` is in neither list.

2. **May `object_id` change within a GOP at all?** §11.5's invariant set is `sigma_t`, `flags`,
   `window_index`, `rotation_index`, each for a stated reason about derived grids. None of those
   reasons applies to a label. The specification neither permits nor forbids the change.

The [object-layer proposal](./object-layer.md) answered both, in its §3.4:

> `object_id` is an ordinary attribute stream, so it rides keyframe chunks (absolute) and MAY be
> restated in a delta's update group. When it is restated it is an **absolute value, not a bin
> difference** [...] It is therefore **not** in keyframe-delta §3.5's GOP-invariant set — an object
> _may_ be relabelled mid-GOP — but when it changes it is restated whole. The track that applies to
> a gaussian at time `t` is the one matching its `object_id` **at `t`**, composed after the delta
> chain has produced that id.

**That paragraph never reached the specification.** `object_id` appears in the normative text at
lines describing §3, §5.3, §5.15.6, §5.15.7, §6.1 and §6.6, and nowhere in §5.18 or §11. The design
decision exists; the normative statement does not. That gap is the real content of #79.

---

## 2. What breaks

### 2.1 Nothing composes the layer on this path

Verified in the reference. `python/fourdgs/fourdgs/keyframe_delta_file.py` contains no occurrence of
the string `object` at all. Its `_dequantize` (`:731-777`) reads attributes `0`–`10` and emits
positions, scales, rotations, colours, motions, `mu_t`, `sigma_t` and `window_index`; `object_id` is
not among them. Its `reconstruct_at` (`:780-828`) applies §3's closed form and the window test, and
never looks for a track. `decode_streamed` (`:563-626`) and `decode_indexed` (`:639-699`) dispatch
on `HEADER`, `QUANTIZATION`, `WINDOW_TABLE`, `CHUNK`, `DELTA_CHUNK` and `FOOTER`, and on nothing in
`0x20`–`0x2F`.

The same holds in `rust/fourdgs/src/keyframe_delta_file.rs`, `typescript/core/src/keyframeDelta.ts`
and `dart/fourdgs/lib/src/keyframe_delta.dart`, as #79 states.

### 2.2 The reference writer cannot produce such a file

This is stronger than #79 claims and it changes what the fix costs. `write_sequence`
(`keyframe_delta_file.py:252-265`) takes samples, duration, cadence options, profile, cutoff,
library, codec, level and three write flags. There is **no `objects` parameter and no provenance
parameter**, and `_keyframe_streams` (`:243-251`) emits exactly `gaussian_id` followed by
`_REQUIRED`, which is `opcode.REQUIRED_ATTRIBUTES` (`opcode.py:137-149`) — attributes `0`–`10`, with
no id `14`.

So the combination is legal by the specification and has never existed as bytes anywhere in this
repository. There is no file to decode wrongly today, which is why the corpus is green; and there is
no encoder to produce a variant with, which is why step 2 of #134's sequence costs a writer change
before it costs a decoder change.

### 2.3 The one place the reference would get it actively wrong

The chain machinery is attribute-generic, so `object_id` would survive it — `State.bins` is a plain
`dict[int, ndarray]` and `apply_delta` carries every attribute the reference state has forward
(`keyframe_delta.py:134-198`). That is the good news. The bad news is what happens when a delta
restates one:

```python
GOP_INVARIANT = frozenset({op.A_SIGMA_T, op.A_FLAGS, op.A_WINDOW_INDEX})  # keyframe_delta.py:57
ABSOLUTE_IN_UPDATE = frozenset({op.A_ROTATION_INDEX, op.A_ROTATION})  # keyframe_delta.py:60
```

`op.A_OBJECT_ID` is `14` (`opcode.py:135`) and is in neither set, so the update branch at
`keyframe_delta.py:163-166` falls through to `_add_checked` and **adds** the restated value to the
previous label. A gaussian that moves from object `7` to object `12` and whose producer follows
§5.18's letter by writing the difference `5` arrives at `12`; a producer that follows the
object-layer proposal and writes `12` absolutely arrives at `19`. Both files are accepted, neither
raises, and the gaussian ends up in an object that may well have a track — so the failure mode is a
gaussian transported by the wrong rigid body.

That is the shape this format refuses everywhere else: plausible, wrong, and silent. It is also
exactly what happens if the composition rule is written without the absoluteness rule beside it.

### 2.4 The corpus cannot see any of it

Four `keyframe/` variants, none carrying the object layer; four `gaussian-birth` files carrying it
(`object/SingleObject`, `object/MultiObject`, `object/ObjectTrackComposed` and the top-level
`LongLived-UseChunkIndex-UseCrc-WithObjects`). Note that the fourth is easy to miss — #79 and #134
both say "the three object-layer conformance variants", which undercounts by one; the top-level
`WithObjects` variant carries a table, a track and an `object_id` stream too.

The two canonical forms do not even overlap. A `keyframe-delta` file is summarized by
`keyframe_delta_file.states_json` rather than by `canonical.summarize`
(`python/conformance/decode_streamed.py:53-62`), and its JSON has six top-level keys — `chunks`,
`cutoff`, `durationSec`, `gaussianCount`, `states`, `temporalModel` — with no `objects` member and
no `objectIds` in its sample. So even if a file carried the layer, today's keyframe canonical would
not report it, and a decoder that dropped it entirely would still pass.

---

## 3. The options

The composition question has three answers, and only one of them is consistent with §11.3.

### (a) Compose after the chain, on the reconstructed state at `t` — `track ∘ (§3 ∘ compose)`

The chain produces a §3 state; §3 reconstructs `base_center` from `position + motion * (t - mu_t)`;
the track then transforms center and orientation once. Identical to the `gaussian-birth` path,
because the state is identical by §11.3's own claim.

- **Cost:** none beyond wiring. It adds no step to the model, and the arithmetic is code that
  already exists for `gaussian-birth`.
- **Property it keeps:** "a consumer's decode path still ends in §3" (§11.3). One decode path, two
  sources of state.

### (b) Compose per chunk, before delta application — store gaussians already transported

Apply each chunk's track pose while composing, so the state a delta references is already in world
position.

- **Fatal for the same reason §11.7 exists.** A delta is a difference of _bins_; the track's pose is
  an `f64` rotation and translation evaluated at an arbitrary `t`. Transporting a state before
  differencing means the reference state is no longer a set of bins, so the telescoping argument
  that makes error bounds depth-independent collapses at the first delta.
- It also breaks §11.5's rotation rule, since a composed orientation is not a smallest-three
  encoding of anything the file stored.

### (c) Forbid the combination — a `keyframe-delta` file MUST NOT carry the object layer

- **Cost:** it deletes a capability the format currently has, for the one temporal model where rigid
  objects are most useful. A vehicle that moves rigidly through a captured sequence is the
  motivating case for both features at once.
- It also contradicts §5.15's "every record in the family is optional" and the object-layer
  changelog's "composes with either of the two", so it would need those retracted.
- The only argument for it is that it is the cheapest thing to implement, and the format does not
  buy cheapness with capability.

The `object_id`-in-a-delta question has two answers, and the difference between them is §2.3.

### (i) Absolute in the update group

What the object-layer proposal specified. A label has no metric, so "difference of labels" is not a
smaller representation of the same thing — it is a different value that happens to be an integer.
Precedent: §11.5 already makes `rotation_index` and `rotation` absolute in an update group when a
difference would be meaningless.

### (ii) GOP-invariant — a delta MUST NOT carry `object_id` at all

- Cheaper to implement (one entry added to `GOP_INVARIANT`, one refusal) and strictly safer, since a
  file that cannot express the change cannot express it wrongly.
- **But it is a tightening that costs a real shape.** An object that a producer wants to split or
  merge mid-GOP — a person setting down a bag, two segmented instances resolving into one — must
  then emit a death and a birth for every affected gaussian, or a keyframe. §11.5 charges that price
  for three attributes because a bin-difference across them has no meaning; a label restated
  absolutely has a perfectly good meaning, so the same price buys nothing here.
- Relaxing a rule is an append and tightening one is not (§11.6's reasoning), which argues for
  choosing (ii) if the two were otherwise equal. They are not: (i) is what the accepted object-layer
  design already decided, and reversing it needs a reason stronger than "cheaper".

---

## 4. Recommendation

**Adopt (a) and (i): the track composes onto the state the chain reconstructs at `t`, exactly once,
after §3's arithmetic; and `object_id` in a delta's update group is an absolute restatement, not a
bin difference.**

Three reasons.

1. **(a) is not a new rule, it is §11.3 held to its word.** §11.3 promises that a composed state is
   a §3 state and that §3's arithmetic then applies verbatim. §3 includes track composition. If (a)
   were not the answer, §11.3's promise would already be false, and the model's central selling
   point — that no consumer forks for it — would go with it. The only defect is that §11.3 says
   "§3's four lines" and §3 now has six.

2. **(i) is the decision the object layer already made**, in the proposal this repository accepted
   and folded into §5.15.6/§5.15.7/§6.6. What was lost in the folding was the paragraph about
   deltas, because §11 did not exist yet in the same document. Restoring it is a correction, not a
   new design.

3. **The two rules are only safe together.** (a) says "the track matching the gaussian's
   `object_id`"; the chain is what determines that id at `t`; and §2.3 shows the reference currently
   computes that id by addition. Writing (a) without (i) would make the composition rule normative
   on top of an id that six implementations compute differently — which is the failure #79 exists to
   prevent, moved one level down.

No existing file becomes illegal. No conformance variant changes. The combination has never been
written, so this is a rule about files that do not exist yet — which is the cheapest moment to write
one.

---

## 5. The normative text

### 5.1 Into §11.3, replacing its final paragraph

> The composed state `S` is a set of gaussians in exactly the state §3 describes — the same fields,
> the same types — and **§3's arithmetic then applies verbatim**. This model changes _where the
> state comes from_ and nothing about what the state means: decoding still ends in the same
> reconstructed gaussian state at time `t` that §3 defines.
>
> **This includes the object layer.** When `S` carries `object_id` (§6.6) and the file carries an
> Object Track (§5.15.7) for a gaussian's id, the track composes onto `S` at time `t` exactly as §3
> defines it and in exactly one place: **after the whole chain has been composed and after §3 has
> reconstructed the base center and orientation at `t`**, never during composition and never once
> per delta. Written as an order:
>
> ```
> 1. chain    -- compose(K, D1, ..., Dd) for t, per this section
> 2. base     -- §3's closed form on the composed state:
>                base_center = position + motion * (t - mu_t)
>                orientation = rotation
> 3. track    -- §3's rigid transform, applied once, for each gaussian whose object_id at t
>                is non-zero and names a track:
>                center      = R(t) * base_center + T(t)
>                orientation = R(t) ⊗ rotation
> 4. shade    -- §3's window test, marginal and opacity, on the untransformed temporal fields
> ```
>
> **The `object_id` a track is selected by is the gaussian's `object_id` at `t`** — the value the
> chain produced, not the value its keyframe stated. A track is applied to a gaussian at most once
> at any instant, because a gaussian has one `object_id` at any instant and at most one track may
> name an id (§5.15.7).
>
> Composing during the chain instead is not an optimization of this order, it is a different model:
> a delta is a difference of **bins** (§11.7), and a state transported by a track's `f64` pose is no
> longer a set of bins, so the telescoping argument that keeps the declared bounds independent of
> depth would not survive the first delta. The transform is therefore applied to the reconstructed
> state and nowhere else.

### 5.2 Into §11.5, after the rotation paragraph

> **`object_id` in a delta's update group is an absolute restatement, not a bin difference.** The
> update carries the `object_id` values as written and they replace the previous ones outright. This
> is `rotation_index`'s treatment for a kindred reason: an id is a label (§6.6), a difference of
> labels is not a label, and a delta of `5` between object `7` and object `12` decodes silently into
> a gaussian that belongs to the wrong object and is therefore moved by the wrong track.
>
> `object_id` is **not** GOP-invariant: a gaussian MAY be relabelled within a group of pictures, and
> a producer that relabels one restates the whole value. A birth carries it absolutely like every
> other attribute the birth group states.
>
> The optional-stream rule in §6.6 applies to every composed state: when the reference state omits
> `object_id`, it logically carries an all-zero column, one zero for every live gaussian. An update
> MAY introduce the stream by restating non-zero ids for any subset; the composer materializes the
> zero column before applying those absolute replacements, and unmentioned gaussians remain zero.
> When a birth group first introduces `object_id`, the composer likewise materializes zeros for
> every surviving reference row before appending the births' absolute values; the resulting column
> has one value for every row in the composed population, not only for the births. Likewise, a birth
> group that omits `object_id` gives each birth id zero even when the surviving reference population
> already carries the column. Physical omission is therefore not an update-attribute mismatch and
> MUST NOT be refused as one.

### 5.3 Into §5.18, in the `updates` bullet

Replace:

> Every other stream present carries **bin differences** against the reference state, aligned
> element-for-element with the id stream.

with:

> Every other stream present carries **bin differences** against the reference state, aligned
> element-for-element with the id stream, except where §11.5 makes a stream absolute.

and extend the bullet's final sentence:

> `sigma_t`, `flags` and `window_index` MUST be absent (§11.5); `rotation_index`, `rotation` and
> `object_id`, when present, are absolute (§11.5).

### 5.4 Into §6.6, after the "independently optional" paragraph

> Under `keyframe-delta` (§11) `object_id` rides a keyframe chunk absolutely, like every other
> attribute, and MAY be restated absolutely in a delta's update group (§11.5). The track that
> applies to a gaussian at time `t` is the one naming the `object_id` the chain produced for it at
> `t`, and composition happens once, after reconstruction, per §11.3.
>
> Omitting the stream means the logical value zero for every gaussian, including a keyframe whose
> later update or birth group introduces non-zero ids, and a birth in a state where other gaussians
> already carry ids. §11.5 defines how that implicit zero column participates in composition.

### 5.5 Into §13's changelog table

| Change                                                                                                                    | Kind                      |
| ------------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| §11.3/§11.5/§5.18/§6.6 added: object tracks compose after the delta chain, and `object_id` in an update group is absolute | clarification, rule added |

with the accompanying note:

> The object-layer-under-`keyframe-delta` row changes no existing file. No file has ever carried
> both: the reference `keyframe-delta` writer emits `gaussian_id` plus the required attribute set
> and no object streams or records, and the four `keyframe/` variants carry none. What the row adds
> is the answer five implementations would otherwise each have guessed — and one of the two rules is
> a correction rather than a decision, since the reference's delta composer treats every non-exempt
> attribute as a difference, which for a label produces a plausible wrong object rather than an
> error.

---

## 6. The conformance variant that pins it

**`KeyframeDeltaObjects`**, in `data/keyframe/`. One variant, carrying every corner the rules above
decide.

- **Shape:** at least four state chunks so that a delta references a delta (depth ≥ 2), an Object
  Table naming two objects, and one Object Track for one of them with samples that put a
  non-identity pose at every probe. The keyframe deliberately omits `object_id`, so its population
  begins with implicit zero ids. The first delta's **birth group** introduces the stream with object
  id `7` while the surviving reference rows remain implicit zeros; that delta also assigns one
  implicit-zero survivor to id `7`. The next delta relabels the born gaussian from `7` to the
  separately tracked id `12`. A later birth omits the stream and must receive zero even though the
  composed state now carries non-zero ids. At least one gaussian carries per-gaussian `motion` so
  that `R * (position + motion * dt) + T` is distinguishable from `R * position + T`.
- **The first birth introduces `object_id`.** Its absolute birth row is appended to a materialized
  zero column for all survivors. This is the inverse transition to an omitted birth after the column
  exists, and catches a generic composer that appends an attribute array containing only the birth
  rows.
- **The deltas exercise introduction and true absolute replacement independently.** Moving the
  keyframe survivor from implicit zero to `7` proves that an omitted keyframe column is materialized
  instead of refused. Relabelling the born gaussian from non-zero id `7` to non-zero id `12` is what
  proves absolute replacement: the erroneous additive path produces `19`, whereas a zero-to-`12`
  transition would produce `12` under either algorithm. Under rule (i), id `12`'s track moves that
  gaussian at the following probe; the untouched gaussian and the later birth that omits the stream
  remain untracked.
- **What the canonical must report.** The `keyframe-delta` canonical
  (`keyframe_delta_file.states_json`) has no `objects` member and no `objectIds` today, so it must
  gain both, in the shape `canonical.summarize` already uses for `gaussian-birth`: an `objects`
  block with the table and the tracks' interpolated poses, and per-probe `states` whose sample
  carries post-track `positions`, `orientations` and `objectIds`. Without that the variant would
  prove only that the file parses.
- **Ordering:** the keyframe canonical orders by `gaussian_id`, which is unique within a state
  (§11.2), so it does not inherit the tie hazard [#95](https://github.com/avala-ai/4dgs/issues/95)
  describes for `canonical.py`'s `states`. That is worth keeping — it means this variant can be
  added without waiting on #95.
- **Refusal variants, in `data/invalid/`:** a delta whose update group carries `object_id` for a
  gaussian that is not live (already covered by the existing unknown-id refusal, so possibly
  redundant), and — if (ii) is chosen instead of (i) — a delta carrying `object_id` at all.

**Cost of the variant is a writer change first.** `write_sequence` must grow an `objects` parameter,
and sample quantization must carry an optional exact `object_id` column (attribute `14`) rather than
stopping at attributes `0`–`10`. `_keyframe_streams` then emits that column only when the keyframe
physically carries it. Delta generation must do more than index `reference_bins[14]`: when the
reference omits the column it materializes zeros for its live ids before classifying updates, and
when a birth first introduces the column it extends those survivor zeros with the births' absolute
values. Conversely, births that omit the column append zeros when the reference already carries it.
Only after those rules exist can the writer deliberately produce the omitted-keyframe transition
this variant requires. That is the honest sequencing note for #134: for #79, step 2 is not "add a
variant", it is "teach the reference encoder to write the combination, then add a variant".

---

## 7. Claims in #79 this proposal could not confirm as written

- **"A scene may legally carry both."** Confirmed as a matter of the specification. Not confirmed as
  a matter of practice: no encoder in this repository can produce such a scene (§2.2), so the
  sentence "such a scene decodes to its **uncomposed** state" describes a file that does not exist
  rather than one that has been observed decoding wrongly. The conclusion is unchanged and the
  urgency is lower.
- **"The keyframe-delta reconstruction path rebuilds base centres and scales from bins and never
  reads the object layer."** Confirmed, with one addition the issue does not make: the chain
  composer _would_ carry an `object_id` column forward if one existed (`keyframe_delta.py:134-198`
  is attribute-generic), and would compose it by **addition** (`:163-166`), which is a wrong answer
  rather than a missing one. That distinction is why §5.2's text is part of this proposal rather
  than a follow-up.
- **"The three object-layer conformance variants are all `gaussian-birth`."** There are four:
  `object/SingleObject`, `object/MultiObject`, `object/ObjectTrackComposed`, and the top-level
  `LongLived-UseChunkIndex-UseCrc-WithObjects`. All four are `gaussian-birth`, so the point stands.
- **"§5.15.7 composes a track onto the reference state (`center = R*c0 + T`)."** §5.15.7 states the
  composition in prose and refers to §3; the formula is written out in §3 and in §6.6, not in
  §5.15.7. A reader looking for the arithmetic at the cited section will not find it there.

**One thing found while writing §5.2 that #79 does not mention, and that whoever edits §11.5 should
fix in the same pass.** §11.5 opens "Four attributes are **GOP-invariant per gaussian**: a delta
MUST NOT carry them in its update group, and a reader MUST refuse a file where one appears there",
and its table's fourth row is `rotation_index` — but the paragraph four lines below says "The update
carries `rotation_index` and the three `rotation` bins as written". The section contradicts itself
about `rotation_index`. §5.18 resolves it correctly ("`sigma_t`, `flags` and `window_index` MUST be
absent; `rotation_index` and `rotation`, when present, are absolute") and so does the reference
(`GOP_INVARIANT` holds three ids, not four), so the wire is unambiguous and only §11.5's opening
sentence is wrong. It matters here because this proposal adds a sentence to that section, and a
reader arriving at it to learn `object_id`'s treatment reads the contradiction first.

---

## 8. Deliberately not decided here

- **Non-rigid per-object deformation.** A track carries the rigid part; whatever is left is the
  temporal model's business. That was the object layer's scope decision and this proposal does not
  reopen it.
- **Whether a track should be able to reference GOP boundaries.** A track is sampled on the scene
  clock and is entirely independent of where keyframes fall. Making the two interact — a per-GOP
  track, a track sample forced at each keyframe — would buy an encoder something and cost every
  reader a coupling between two independent records. Not proposed.
- **Whether `object_id` should be GOP-invariant after all.** Option (ii) in §3 above is a defensible
  answer and this proposal argues against it rather than pretending it is unavailable. If a
  maintainer prefers it, only §5.2 changes: `object_id` joins §11.5's forbidden list and the
  variant's relabel row becomes a refusal. Everything else in §5 stands unaltered.
