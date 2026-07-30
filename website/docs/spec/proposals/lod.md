# Proposal: level-of-detail and progressive refinement

**Status: accepted design. Not yet normative, not yet implemented, and not to be emitted by any
writer.** Nothing in this document changes what a conforming file looks like today. It is the
approved design, written at wire precision, and it becomes a revision of
[the specification](../index.md) and a set of entries in [the registry](../registry.md) as the
implementation lands. Until it does, the specification is the format and this is a plan.

Every question this design left open has been decided; the decisions are recorded in §12 and folded
into the sections they affect, so no section contradicts a ruling.

This layer is **not a temporal model** and it does not change reconstruction. It is closest in kind
to the object layer: a set of optional additions that a reader may ignore entirely and still decode
every file correctly, plus one rule that fixes the meaning of a field the specification already
carries but currently leaves informational. Where the object layer added a transform, this layer
adds **nothing to the reconstructed scene at all** — it is a rule about which bytes a reader must
fetch to obtain a chosen part of a scene it could already obtain in full. That difference is the
whole of §5.

---

## 1. What is missing

The format seeks in one dimension. A reader displays instant `t` by reading the index and then the
byte ranges of the chunks whose interval contains `t` (spec §8). It has one dial for _how much of an
instant_ to fetch — spherical harmonic bands ride in their own records with their own byte ranges,
so a reader that wants fewer bands transfers fewer bytes (spec §5.7) — and no dial at all for _how
much of the scene_ to fetch. An instant is all of its gaussians or none of them.

Two capabilities are absent, and they are the two a consumer streaming a large scene over a network
asks for first:

- **Level of detail.** A distant scene, a preview, a low-power client, or the first paint of a scene
  a user is still approaching does not need every gaussian. It needs the _important_ ones — a subset
  that reads as the scene at lower fidelity — and it needs to fetch only that subset, not fetch the
  whole scene and discard most of it. The format has nowhere to say which gaussians are the
  important ones, and no way for a reader to fetch that subset by byte range.
- **Progressive refinement.** A reader that has fetched a coarse version and then has more time,
  more bandwidth, or a closer camera should be able to _add_ detail to what it already has, rather
  than re-fetching. Each step should leave a coherent scene on screen. The format streams a scene as
  one block per instant; it has no notion of a coarse-first, refine-later order, and no statement
  that stopping partway leaves a valid scene rather than a corrupt one.

The gap is worth stating precisely, because it is not "the format cannot represent a coarse scene".
It can: a coarse scene is just a scene with fewer gaussians, which the format represents natively.
It is not "the format cannot skip bytes": the band records already prove it can. The gap is that
nothing ties those two facts together — nothing marks a subset as _the coarse scene_, and nothing
lets the index hand a reader that subset's byte ranges without fetching the rest first.

The specification already left the ground for this. Every Chunk record (spec §5.5) and every Delta
Chunk (spec §5.18) carries a `level` field:

> `u32 level -- producer's hierarchy level; informational only`

and spec §10.1 reserves, for a future version, "spatial subdivision within a temporal chunk, for
level-of-detail by region." keyframe-delta §3.6 added the one constraint it needed from levels — a
delta's reference must share its `level` — and then said (§3.6, ruling §13.7) that everything else
about levels "belong[s] with the reserved spatial-subdivision work, which is where the
level-of-detail design track lives." **This proposal is that track.** It gives the `level` field a
meaning, gives the index a way to seek on it, and names the fetch order that makes refinement
coherent.

---

## 2. Scope

**Designed here:** the meaning of the `level` field — how a writer assigns gaussians to levels and
what "level ≤ N" reconstructs; the one appended index field that lets a reader fetch a level by byte
range alone (the seek-predicate extension); the fetch order for progressive refinement and the
property that every prefix of it is a valid scene; how level composes with the chunk index, with
both temporal models, and with the object layer; the sense in which a level carries an error bound
and the sense in which it cannot; forward compatibility; and the conformance corpus the layer needs.

**Not designed here**, deliberately:

- **A network manifest.** A separate resource that enumerates a scene's fetchable pieces as
  independent addressable segments — the shape an adaptive-streaming stack uses — is **not** part of
  this design, and §8 argues the file's own index makes it unnecessary rather than merely omitting
  it.
- **A new codec.** Levels ride ordinary Chunk and Delta Chunk records; bands ride the SH Band Stream
  records that already exist. Nothing here compresses anything in a new way, and no codec registry
  value is spent.
- **The importance metric.** How a writer decides which gaussians are important enough for level 0 —
  opacity mass, projected size, saliency, a perceptual model — is encoder policy, exactly as
  keyframe cadence and rate control are (keyframe-delta §2). The format defines what a level _means_
  and states its cost; it does not decide which gaussian lands in which level.
- **Spatial subdivision within a temporal chunk.** Spec §10.1 reserves it, and this design is the
  _between-chunk_ detail axis, not the _within-chunk_ one. §6 states exactly how the two relate and
  why this layer does not need the reserved one to be useful.
- **Per-gaussian SH degree.** Reserved by spec §10.1. The quality axis here is whole bands dropped
  uniformly, which the wire already supports; a per-gaussian degree is a different and larger
  change.

---

## 3. The model

Level of detail on this format is **two orthogonal additive axes**, and the design is mostly the
observation that the format already has both and that both are already additive:

- a **detail axis** — which gaussians are present — carried by the chunk `level` field;
- a **quality axis** — how much view-dependent colour each present gaussian carries — carried by the
  spherical harmonic bands.

"Additive" is the load-bearing word and it means the same thing on both axes: a finer setting **adds
to** a coarser one rather than **replacing** it. Bands are already additive — bands `1..b` give a
degree-`b` scene and bands `1..b+1` give a degree-`b+1` scene by adding one band's records, never by
restating the lower ones (spec §6.5). This design makes the detail axis additive in exactly the same
shape, and §5 shows that forward compatibility _forces_ that choice rather than merely favouring it.

### 3.1 Levels — cumulative, importance-ordered subsets

A **level** is a non-negative integer a chunk carries in its `level` field. The rule this proposal
adds is the meaning of the number:

> **A gaussian belongs to exactly one level — the level of the chunk that carries it — and the scene
> at level `N` is the union of every gaussian whose level is `≤ N`.**

So level `0` is the coarsest scene: the smallest, most important subset a producer is willing to
call a recognizable version of the whole. Each higher level is a **tranche of added detail** — the
gaussians that were not important enough for any lower level. Nothing at a higher level restates or
replaces anything at a lower one; a higher level only adds. This is the same relation bands have to
each other, one axis over.

Two consequences fall straight out of "union of `≤ N`", and they are what make the axis usable:

- **Monotone.** More levels is more gaussians, never fewer and never different ones. A reader that
  raises its level budget from `N` to `N+1` **keeps everything it has** and fetches only the
  level-` N+1` chunks. This is what makes refinement an append rather than a re-fetch (§3.4).
- **The full scene is level `≤ max`.** Fetching every chunk, at every level, is exactly the scene
  the format reconstructs today — because "every chunk" and "the union over all levels" are the same
  set of gaussians. A reader that ignores levels entirely and fetches everything gets the
  full-detail scene with no change to any arithmetic. §5 turns this sentence into the
  forward-compatibility argument.

**How a writer assigns levels.** The writer ranks its gaussians by whatever importance metric it
chooses (§2), partitions the ranked list into tranches — level 0 the top tranche, each subsequent
level the next — and emits each tranche as one or more chunks tagged with that level. A gaussian's
`object_id`, its window, its motion and every other attribute are unchanged by which level it lands
in; level is a property of the _chunk_, assigned by the writer's ranking, and it costs nothing
per-gaussian because the field already exists per-chunk. A single-level file — every chunk at level
`0` — is exactly a file as written today, and is what every existing writer produces.

### 3.2 The detail axis is exact per gaussian, lossy only by omission

This is the degradation contract, and it is the strongest statement the format can make about a
coarse level, reached the same way keyframe-delta and the object layer reach theirs — by finding the
place where the error does not compound:

> **Every gaussian present at level `≤ N` is bit-identical to that same gaussian in the full scene:
> the same bins, the same quantization, the same declared bounds. A level cut removes gaussians; it
> never approximates one. So the only difference between a level-`N` render and the full scene is
> the set of gaussians the cut omits — and each omitted gaussian's contribution is exactly its own,
> not an error smeared across its neighbours.**

There is no dequantization step for level, no grid, no per-level rescaling — a coarse level is not a
coarser _encoding_ of the scene, it is a _subset_ of the same encoding. Spec §5.3's bound holds
verbatim on every gaussian a level render contains, at every level, because the bytes those
gaussians are decoded from are the same bytes the full scene decodes them from.

What the format therefore **cannot** declare is a numeric bound on the difference between a coarse
level and the full scene, and it is worth being as candid about this as spec §8 is about seek cost:

> The deviation a level cut introduces is the sum of the omitted gaussians' contributions, and how
> large that is depends entirely on how important the omitted gaussians were — which is the
> encoder's importance metric, a judgement the format does not make and cannot bound. A level cut on
> a scene whose importance ranking is good loses almost nothing perceptible; the same cut on a scene
> ranked badly loses a great deal. The number is real but it is a property of the _content and the
> encoder_, not of the container, exactly as seek efficiency is (spec §8).

So the layer offers an **advisory, encoder-measured** quality figure per level rather than a
guaranteed one — the same standing the `bounds` map has (a producer's declaration, not an
instruction, spec §5.3) and the same standing the measured compression table has (numbers reported,
not asserted by the format). §4.4 gives it a home and §7 works the bound through both axes.

### 3.3 The quality axis — progressive spherical harmonics

The second axis needs no new rule, only a name and an order, because the wire already carries it. A
scene's spherical harmonics are stored one band per SH Band Stream record (spec §5.7), each band
with its own byte range in the Chunk Index (spec §5.8), and "a reader that has decided to evaluate
fewer bands never transfers the ones it will not use" (spec §5.7). Bands are whole and additive:
bands `1..b` are a degree-`b` scene (spec §6.5).

Progressive quality is therefore: **fetch band 0 (the DC term, carried in the chunk's `color`
stream) first, then band 1, then band 2, then band 3, in ascending order, each band's records added
to the scene already in hand.** At each step the scene is a valid lower-degree scene of exactly the
gaussians fetched so far. Dropping a band does not corrupt colour; it removes that band's
view-dependent variation, and the appearance falls back toward the lower-degree fit — which is a
real, defined scene (a degree-`b` reconstruction), not an artefact.

One reading has to be made explicit, because progressive refinement across many chunks reaches it
and single-shot decoding does not. The Header declares one `sh_degree` for the scene (spec §6.5),
but that is the **maximum available**, and a partially refined scene may hold some chunks at a
higher assembled degree than others — the near chunks refined to degree 3, the far ones still at
degree 0.

> A gaussian is evaluated at the degree for which its bands are present. `sh_degree` is the ceiling,
> and any per-gaussian evaluated degree at or below it is a valid scene. A scene of mixed per-chunk
> degree is a union of valid lower-degree gaussians and is itself valid.

This is the natural reading of the per-band byte ranges already in the index — they exist precisely
so a band can be fetched or not fetched per chunk — and it contradicts nothing in §6.5, which
forbids assembling a _partial band_, not evaluating _whole bands_ at a per-chunk count. A reader
still MUST NOT assemble a partial degree out of part of a band (spec §6.5); it MAY hold different
whole-band counts for different chunks.

### 3.4 Progressive refinement — the fetch order and the valid-at-every-prefix property

Refinement is a walk outward on both axes from the coarsest corner. The recommended order, for a
reader that wants a usable scene as early as possible and then improves it:

```
1. level 0, band 0            -- the coarsest scene: the most important gaussians, flat colour
2. level 0, bands 1..D        -- view-dependent colour on the coarse scene
3. levels 1..N, band 0        -- add detail gaussians, flat colour
4. levels 1..N, bands 1..D    -- view-dependent colour on the detail gaussians
```

The order between steps 2 and 3 — quality-first or detail-first — is a **reader policy**, not a
format rule, and a reader chooses it from what it is doing: a reader zooming in wants detail first,
a reader holding a wide shot wants quality first. The format's contribution is not the order; it is
the property that makes _every_ order safe:

> **Valid at every prefix.** After any prefix of the fetch — any set of levels `≤ N` crossed with
> any set of whole bands, in any order — what the reader holds is a complete, decodable 4dgs scene:
> a set of gaussians each carrying its full required attribute set, each reconstructed by spec §3
> with no missing field and no dangling reference. A reader that stops early, or is cut off early,
> has a coarse scene, never a corrupt one.

This holds because both axes are additive and each unit is self-contained. A level's chunks are
ordinary chunks — "independently decodable; nothing in a chunk references another chunk" (spec §5.5)
— so a level's gaussians need no other level to be reconstructed. A band's record is self-contained
for the same reason. The one place a chunk references another is a keyframe-delta chain, and that
chain is confined within a single level by keyframe-delta §3.6 (a delta's reference shares its
level), so a level's chains resolve using only that level's chunks. §3.5 states that composition
precisely; the point here is that it is what keeps a partial fetch coherent.

Nothing in this order requires the reader to have decided its final level or degree in advance. It
raises either budget at any time and fetches exactly the difference, because the difference is a set
of byte ranges the index names (§4.2) and the new gaussians and bands compose onto the held scene by
union.

### 3.5 Composition — level is orthogonal to time and to objects

A level is a partition of _gaussians_; a temporal model is a rule for reconstructing a gaussian's
state at an _instant_; an object is a _grouping_ of gaussians. The three are independent, and the
seek that combines them is a filter followed by the existing reconstruction.

**Level and `gaussian-birth`.** A `gaussian-birth` chunk carries its own `[t0, t1)` and its
gaussians are invisible outside it (spec §5.5); levels impose no tiling. The combined seek is:

```
chunks_for(t, N) = every Chunk Index entry whose [t0, t1) contains t AND whose level <= N
```

The reader fetches those chunks' byte ranges and reconstructs each gaussian by spec §3, exactly as
today. Level is one more predicate on the same index scan (§4.2); it adds no read and no arithmetic.

**Level and `keyframe-delta`.** keyframe-delta tiles the timeline with state chunks and reaches an
instant by walking a chain back to a keyframe (keyframe-delta §7). Because a delta's reference
shares its level (keyframe-delta §3.6), **each level's chunks form their own tiling and their own
chains** — a level is a self-contained keyframe-delta stream over the timeline. The combined seek is
one chain walk _per level_:

```
chunks_for(t, N) = for each level ell in 0..N that has chunks covering t:
                       the keyframe-delta chain for t within level ell   (keyframe-delta §7)
                   unioned over ell
```

This is exactly the generalization keyframe-delta §7 anticipated: "if spatial subdivision within a
temporal chunk is ever added, `current(t)` becomes a set rather than a single entry; the chain walk
is unaffected." Here the set is indexed by level rather than by region, and the chain walk within a
level is unchanged. A level that adds no detail over some interval simply has no chunk there, and
contributes nothing to the union at those instants — which is not an error (§9).

**Level and the object layer.** `object_id` is a per-gaussian attribute that rides in the chunk
(spec §6.6); an Object Track is front matter applied once after base reconstruction (spec §3,
§5.15.7). Level filtering changes _which gaussians are present_; it changes neither. A track read at
open applies to whichever of its object's gaussians a level render happens to have loaded, and
because a track is rigid and identical for all of an object's gaussians, an object that is split
across levels — coarse gaussians at level 0, fine detail at level 2 — refines correctly for free:
the same pose moves whatever subset is present. Object filtering (keep `object_id == k`) and level
filtering (keep `level ≤ N`) are two predicates on the loaded set and compose by intersection, in
either order, with no interaction.

So one seek carries all three filters at once:

```
fetch every Chunk Index entry with  level <= N  AND  [t0,t1) ∋ t    (temporal rule per §3.5)
then, per chunk, keep gaussians with the wanted object_id           (object layer, optional)
then reconstruct by spec §3 and apply any matching Object Track      (object layer, optional)
```

Level is the outermost filter, resolved from the index before any chunk is fetched; the temporal
rule selects within a level; object membership filters within a chunk. None of the three needs to
know about the others.

---

## 4. Wire mapping

The principle is the one both prior proposals used: **ride the existing machinery.** The detail axis
reuses a field that already exists on every chunk. The quality axis reuses records that already
exist. Exactly **one field is appended**, to one already-frozen record, so that the seek predicate
can filter on level without fetching chunks. Everything else is a registry addition or a reader
policy.

### 4.1 The `level` field gains a meaning, not a wire change

Chunk (`0x05`) and Delta Chunk (keyframe-delta `0x10`) already carry `u32 level`. No byte moves; the
field's _semantics_ change from "informational only" to §3.1's cumulative-subset rule. A file every
chunk of which is level `0` — every file written to date — is unaffected, because the union over the
single level `0` is the whole scene, which is what it always was.

### 4.2 Chunk Index (`0x08`) — one appended field, and the seek predicate

The seek predicate of §3.5 filters on `level`, and a reader must be able to evaluate it **from the
index alone**, without fetching a chunk to learn its level — that is the whole point of a seek
predicate. The Chunk record carries `level`, but the Chunk _Index_ (spec §5.8) does not. So the
index gains it:

```
... existing fields, unchanged, through the variable band array ...
u32  level    -- mirrors the level of the Chunk / Delta Chunk this entry describes
```

The Chunk Index is frozen (spec §4.4), and this is the append that a frozen record permits: a reader
that knows only the fields before it parses the band array and stops by `content_length` (spec
§4.2), and a reader that knows this field reads four more bytes. A reader MUST refuse a file where
an index entry's `level` disagrees with the `level` in the Chunk or Delta Chunk it points at, naming
both — the same cheap corruption check the keyframe-delta index fields make on what they duplicate
(spec §5.8), for the same reason: a seek predicate a reader trusts must not be able to disagree with
the record it selects.

With the field present, the seek is the one-line extension of spec §8 given in §3.5: the same index
scan, one more comparison per entry, no chunk fetched to evaluate it. **The layer costs a seeking
reader nothing beyond the comparison** — the index is read once at open, as it always is, and
`level` rides in it.

**The order of appended fields on this record is coordinated, and this is a real constraint, not a
formality.** keyframe-delta also appends to the Chunk Index — six fields, `chunk_kind`,
`delta_mode`, `reference_offset`, `keyframe_offset`, `depth` and `live_count` (spec §5.8), present
only under `temporal_model = "keyframe-delta"` — and appended fields are positional, so two
independent extensions appending to one frozen record must agree on an order or a reader cannot
locate either. §12.1 is the ruling. The normative layout of the appended region is fixed:

```
[ base Chunk Index, through the variable band array ]
[ keyframe-delta block: the six fields above, present iff temporal_model == "keyframe-delta" ]
[ level: u32, present iff content_length has room after the blocks above ]
```

`level` is the **last** appended field, the keyframe-delta block precedes it, and a reader locates
`level` as the four bytes after all other known blocks, present when `content_length` leaves room
for them. This is unambiguous for exactly these two appenders, and unambiguous **because one of them
is keyed to a Header field**: `temporal_model` decides whether the six-field block is there before a
reader reaches the appended region, and the single trailing `u32` is then decided by remaining
length. The order is recorded in the registry so it is decided once, and re-verified against the
merged record at implementation time, exactly as the object layer re-verifies its opcodes
(object-layer §12.6).

**This scheme does not generalize past two appenders, and the escalation is normative.** A third
_independent-optional_ append to the Chunk Index — one whose presence is not already decided by a
Header field the way the keyframe-delta block's is — would make "trailing bytes" ambiguous again,
because length alone cannot say which of two unkeyed optional blocks wrote them. **Any third
appender to the Chunk Index MUST therefore introduce a presence bitmask** — a small appended field,
itself read first, whose bits say which later appended blocks are present — rather than adding
another positional block. The bitmask is not built now, because two appenders with one
`temporal_model`-keyed are safe without it; it is the pinned next step, documented here so the
positional scheme cannot be extended silently into ambiguity (§12.1, §13).

### 4.3 Spherical harmonic bands — no wire change

The quality axis adds nothing to the wire. Bands are already one record each with their own index
byte range (spec §5.7, §5.8); the progressive fetch of §3.3 is a reader choosing the order in which
it reads ranges it can already address. No field, no opcode, no codec.

### 4.4 Registry additions

None changes the format version; each is the kind of addition spec §10 permits within version 1.

- **A `progressive` profile.** Promises that levels are used as §3.1 defines them and that **level 0
  alone covers the timeline** — i.e. a reader that fetches only level 0 gets a complete coarse scene
  at every instant, not a scene with holes in time. This is what lets a consumer that needs a cheap
  coarse pass reject a file that cannot give it one, up front, which is what a profile is for. A
  file without the profile may still use levels; the profile is the promise that level 0 is a usable
  standalone scene, which not every level assignment guarantees (§9).
- **Advisory metadata keys.** `lod_levels`, the number of levels (one more than the maximum
  `level`), so a consumer can size its ladder before fetching the index. `lod_quality`, an optional
  encoder-measured quality figure per level — the advisory number of §3.2, in the same spirit as the
  measured compression table: a producer's report, never a guarantee, and reconstruction reads none
  of it. Both are keys, not records, because a per-level _size_ is already derivable from the index
  (sum `chunk_length` over the entries of a level) and quality is the only datum that is not; §12.2
  rules on whether that ever justifies a dedicated record.
- **Reader-side, no registry entry:** the progressive fetch order (§3.3, §3.4) is a reader policy,
  and policies are not registry values.

### 4.5 The summary is untouched, and no manifest is added

`level` is appended to the Chunk Index, which is already a summary record (spec §4.5); no new record
class joins the summary, so the contiguous-summary rule and the streamed CRC it protects keep
working with no new case, exactly as keyframe-delta §4.5 preserved them. And no separate manifest
resource is introduced — §8 argues the index _is_ the manifest.

### 4.6 Forward compatibility — an old reader sees the full scene

This is the property that makes the layer additive, and it is stronger here than for the object
layer, which had a transform an old reader would miss. Here there is nothing to miss:

- The appended index `level` field is unknown bytes to an old reader, which steps over them by
  `content_length` (spec §4.2) — the mechanism §4.2 above relies on.
- The `level` field on chunks is one the current specification _already_ tells a reader to treat as
  informational, so an old reader already ignores it and already **loads every chunk regardless of
  level**.

Loading every chunk regardless of level is, by §3.1, exactly the full scene — the union over all
levels. So an old reader, ignoring this layer completely, reconstructs **the full-detail scene, byte
-identical to what it reconstructs today**, with no gate and no degraded view. There is nothing for
it to get wrong, because the layer adds no reconstruction step: it only lets a _new_ reader fetch
less. The degraded view an old reader might have shown — the object layer's honest caveat
(object-layer §4.6) — does not arise, because the old reader here does not take the coarse path; it
takes the full path, which is the only path it ever had. §5 is the whole argument that this needs no
version gate.

---

## 5. Versioning: additive within version 1, and why there is no gate

**The magic's version byte does not change. Existing files do not move. No frozen field changes.**
Every mechanism is one spec §10 already permits:

| what this adds                   | §10 rule that permits it                    |
| -------------------------------- | ------------------------------------------- |
| meaning for the `level` field    | registry/spec clarification, no wire change |
| `u32 level` on the Chunk Index   | existing records MAY gain appended fields   |
| `progressive` profile            | registry addition                           |
| `lod_levels`, `lod_quality` keys | registry addition                           |

There is **no gate on an old reader**, and the reason is the distinction the two prior proposals
drew between them:

> A temporal model changes what the base state _means_, so keyframe-delta gates on `temporal_model`
> and an old reader refuses (keyframe-delta §5). The object layer changes nothing about the base
> state but _adds a transform_, so an old reader that skips it sees a valid-but-static degraded
> scene (object-layer §4.6). This layer adds **neither a new meaning nor a transform** — it adds a
> subset relation over gaussians the reader was already loading in full. An old reader does not
> degrade; it loads everything, which is the full scene. So no gate, and not even a degraded view.

The one thing that would have broken this is the design choice §3.1 settled, and it is worth naming
as the reason that choice is not merely aesthetic. Had levels been **replacement** levels — each
level a complete representation of the scene at its own fidelity, the way a resolution pyramid
replaces rather than adds — then "load every chunk" would have loaded the same region several times
over, once per level, and an old reader would have rendered a scene several times too dense: a real,
silent, wrong scene of exactly the kind this format refuses everywhere. Replacement levels would
have _needed_ a gate, because the full union would no longer be the full scene. Additive levels need
none, because the union over all levels _is_ the full scene. Forward compatibility does not merely
favour the additive model; it is incompatible with the alternative.

---

## 6. Relationship to spatial subdivision (spec §10.1)

Spec §10.1 reserves "spatial subdivision within a temporal chunk, for level-of-detail by region."
That reserved item and this proposal are the two halves of level of detail, and they do not overlap:

- **This layer is the between-chunk axis.** A level is a subset of _whole chunks_, selected by the
  writer's importance ranking. It is coarse-grained — the unit is a chunk — and it needs no new wire
  form because a chunk already carries `level`.
- **The reserved item is the within-chunk axis.** Subdividing a single chunk spatially so a reader
  can fetch part of one chunk's gaussians by region is a finer axis, and it needs the wire form spec
  §10.1 reserves.

This layer is useful without the reserved one: a writer that wants finer detail control simply emits
smaller chunks and assigns them levels, paying one chunk header per subdivision. The reserved item
would let a reader subdivide _below_ the chunk granularity without that per-chunk cost, and when it
lands it composes with this layer cleanly — a spatially subdivided chunk still carries a `level`,
and the seek predicate of §3.5 still filters on it. keyframe-delta §7 already wrote the sentence
that covers both: `current(t)` becomes a set indexed by whatever partitions the timeline into pieces
— level, region, or both — and the chain walk within a piece is unchanged. This proposal fills in
"level"; the reserved item will fill in "region"; the seek predicate is written once and serves
both.

---

## 7. Error and quality bounds, per axis and combined

Spec §5.3's contract is a per-attribute maximum deviation, grid pitch twice the bound,
`|decoded - original| ≤ bound` by construction. A level-of-detail layer has to say what that bound
becomes under each axis, and the two axes give opposite kinds of answer — which is itself the useful
result.

**The detail axis carries no per-gaussian error and no format-level bound on the omission.** §3.2 is
the whole statement: every present gaussian is bit-identical to its full-scene self, so its bounds
are the declared ones verbatim, at every level; and the difference from the full scene is the
omitted gaussians' own contributions, which the format cannot bound because their magnitude is the
encoder's importance judgement. This is the same shape of candour as spec §8 on seek cost: a real
quantity, a property of content and encoder, reported as advisory (§4.4) and never guaranteed by the
container.

**The quality axis carries a real per-band bound, and it is already in the file.** Dropping bands
`b+1..D` reconstructs the degree-`b` scene, and each band's contribution is bounded by its own
declared SH bound (spec §5.3's `sh_band<b>` keys, spec §6.5). The coefficients that remain are exact
or bounded exactly as the file declares; the bands that are gone contribute their known,
declared-bounded energy and nothing unbounded. So a reader that stops at degree `b` can state its
colour error as the sum of the omitted bands' declared bounds — a number the file already carries,
unlike the detail axis's.

**Combined, the two do not interact, so the bounds compose trivially.** A gaussian present at level
`≤ N` and evaluated at degree `b` has its position and geometry at the declared full bound (the
level cut did not touch them) and its colour at the degree-`b` bound (the band cut did). The level
cut omits gaussians; the band cut lowers degree; neither amplifies the other, because one acts on
_which gaussians_ and the other on _each gaussian's colour_, and those are disjoint. There is no
cross term, no depth term, and nothing that grows with the number of levels or bands — the same
clean shape keyframe-delta §8 and object-layer §7 reach, reached here because the two axes are
literally independent partitions of independent data.

### Representability

Neither axis introduces an accumulator, a chain, or a composed value that could overflow or go
non-finite — a level is a subset and a band is a subset, and subsetting has no arithmetic. The only
new invalid state either axis can express is a structural one (a level whose chunks do not resolve,
a band range that overruns), and those are §9's refusals, checked the same way the format checks
every other declared count and offset.

---

## 8. Why no network manifest

The brief for this design asked whether level-of-detail streaming needs a separate manifest — a
resource that lists a scene's fetchable pieces as independent addressable segments, the way an
adaptive-streaming stack advertises its renditions and chunks — or whether the file's own byte-range
index suffices. **The index suffices, and a manifest would cost the format its first design goal.**

A manifest exists, in the stacks that use one, because their media containers are not seekable
without a sidecar and their segments are separate resources at separate URLs. Neither is true here.
The format's first two design goals are "one resource — one file, one URL, one cache entry" and
"seekable without a sidecar" (spec §1), and the Chunk Index already delivers what a manifest would
advertise:

- **What pieces exist and where.** Every chunk's `[t0, t1)`, its byte range, its band ranges, and —
  with §4.2 — its level. A client computes, for any target (a time window, a level budget, a band
  budget), the exact set of byte ranges it must fetch, _from the index alone, before fetching any
  gaussian data_. That is precisely a manifest's job.
- **In one round trip.** The index is at a known place: the 37-byte tail gives `summary_start` (spec
  §5.2), and one range read brings the whole index. A manifest would be a _second_ resource to fetch
  first, to describe a file that already describes itself.
- **Kept consistent by construction.** A manifest is a second representation of the index's facts,
  and a second representation is a second thing to keep consistent with the first — the exact
  argument keyframe-delta §4.5 made against a GOP-level index record, one level out. The index
  cannot disagree with itself; a manifest can disagree with the index.

The one thing a manifest offers that the index does not is _discovery before the index is fetched_ —
a client choosing a level given its bandwidth without reading the file at all. Two things answer
that. First, the advisory metadata of §4.4 (`lod_levels`, per-level quality, and per-level size
derivable from the index) is exactly the summary such a client wants, and it rides in the front
matter a client reads anyway. Second, and more to the point, adaptive selection — _which_ level to
fetch given measured bandwidth and a latency target — is a **client policy fed by the index**, not a
container feature, in exactly the division the format draws everywhere: the format carries the facts
that must survive interchange, the client makes the choice (spec §7.3 on spatialization,
keyframe-delta §2 on rate control). A manifest would not add a fact; it would relocate the client's
policy into a sidecar and break "one resource" to do it.

So: **no manifest. The byte-range index is the manifest, and adding a second one would trade a
design goal for nothing the index does not already give.** §12.3 records this as the ruling it is,
with the one condition under which it would be reopened.

---

## 9. Failure modes a reader refuses

Collected so a reader can check itself against a list. Each names the offending value. The list is
short because subsetting has little to get wrong; most of it is referential integrity between the
index and the chunks, which the format already polices.

| condition                                                                     | why it is not repairable                                                  |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| an index entry's `level` differs from its Chunk / Delta Chunk's               | the seek predicate would select on a value the record denies              |
| a `keyframe-delta` delta references a chunk of a different `level`            | keyframe-delta §3.6; a chain would cross levels                           |
| within a level, the `keyframe-delta` tiling/chain rules are violated          | keyframe-delta §3.1, §7, applied per level                                |
| a band byte range in the index overruns the file                              | the existing index-range rule (spec §5.8), unchanged                      |
| the `progressive` profile is declared but level 0 does not cover the timeline | the profile's promise is false, and a coarse-only reader would find holes |

Everything **not** on this list is valid and often intentional, and the layer is at pains not to
refuse a usable file:

- **A level that covers only part of the timeline** is valid — a higher level adds detail only where
  there is detail to add (§3.5). Only level 0 is expected to cover the whole timeline, and only when
  the `progressive` profile promises it; without the profile even that is not required.
- **Gaps between level numbers** — levels `0` and `2` present, `1` absent — are valid. "Union of
  `≤ N`" does not require the levels to be dense; a reader fetching level `≤ 1` simply gets level 0,
  and a reader fetching level `≤ 2` gets levels 0 and 2. A producer SHOULD keep them dense for a
  clean ladder, but a gap is not a refusal.
- **A single-level file** (every chunk level 0) is the ordinary file of today and carries no
  obligation from this layer at all.
- **`lod_quality` absent, or present for some levels only** — it is advisory (§4.4); its absence is
  not an error and reconstruction reads none of it.

A validator MAY note the unusual combinations; a reader refuses only the structural faults above.

---

## 10. Conformance plan

Nothing here is real until the suite proves it. This is what would be added to the corpus generator
and the canonical summary.

### 10.1 Canonical JSON

A variant that uses levels gains a per-level view of the scene, and the existing per-instant states
gain a level budget, so that the summary can assert "level ≤ N at time t is exactly this set of
gaussians".

```json
{
  "lod": {
    "levels": "3",
    "byLevel": [
      { "level": "0", "chunkCount": "4", "gaussianCount": "1024", "byteSize": "48210" },
      { "level": "1", "chunkCount": "8", "gaussianCount": "4096", "byteSize": "191044" }
    ]
  },
  "states": [
    {
      "t": 0.5,
      "level": "0",
      "liveCount": "1024",
      "sample": { "positions": [], "levels": [] },
      "aggregate": { "positionSum": [], "opacitySum": 0.0 }
    }
  ]
}
```

- `lod.byLevel` exists so that a field no expectation mentions is a field an implementation can
  decline to decode — the reason `chunks` is in keyframe-delta's summary. `byteSize` is derivable
  from the index and is included so a decoder that computes the level's byte footprint (the
  seek-cost a streaming client budgets) is checked against a known number.
- **`states` carries a level budget.** Each probe instant is summarized at one or more level
  budgets, and `sample.levels` is each sampled gaussian's level. This is the conformance teeth: a
  decoder that filters level wrongly — off-by-one on `≤`, or fetching a level's chunks when it
  should not — produces a different `liveCount` and a different gaussian set at that budget and
  fails on that row. A budget equal to the maximum level MUST reproduce the full-scene state a
  non-LOD decode produces, which is the §5 forward-compatibility claim made checkable.
- **The two read paths must agree**, as keyframe-delta §11.2 requires: a streamed decode that
  filters level as chunks pass and an indexed decode that seeks with the level predicate of §3.5
  MUST produce identical `states` at every budget.

### 10.2 Scenarios

New corpus variants, each crossable with `gaussian-birth` and `keyframe-delta`, since level is
orthogonal to the temporal model (§3.5):

| scenario              | shape                                                              | what it catches                                                                         |
| --------------------- | ------------------------------------------------------------------ | --------------------------------------------------------------------------------------- |
| `LodSingleLevel`      | every chunk level 0                                                | the degenerate file that is today's file; must be byte-identical to the non-LOD variant |
| `LodTwoLevels`        | level 0 coarse, level 1 detail, both spanning the clip             | the seek predicate; `states` at each budget; the union rule                             |
| `LodSparseLevels`     | level 0 spans the clip, level 1 present only over part of it       | a level that covers part of the timeline (§3.5, §9)                                     |
| `LodLevelGap`         | levels 0 and 2 present, 1 absent                                   | non-dense level numbers (§9)                                                            |
| `LodProgressiveBands` | one level, degree-3 SH, probed at degrees 0..3                     | the quality axis; mixed per-chunk degree validity (§3.3)                                |
| `LodFullEqualsUnion`  | multiple levels; a budget at max compared to a non-LOD full decode | the §5 claim: full union is byte-identical to loading all chunks                        |

Crossed with the existing flags `Quantized`, `SHDegree2`, `UseCrc`, `UseChunkIndex`, and one variant
with no index (a streamed reader filtering level without one). `LodProgressiveBands` is additionally
crossed with the per-band bit-depth ladders, since the quality axis and the bit-depth dial share the
band records.

### 10.3 Files a reader must refuse

§9's structural faults, as a small corpus of deliberately invalid files, each paired with the
identifier of the refusal it must produce — `level-index-mismatch`, `delta-crosses-level`,
`level-tiling-violated`, `progressive-level0-has-holes`. This reuses the refusal-expectation harness
contract keyframe-delta §11.5 introduces; if that contract has landed by the time this does, this
adds rows to it rather than a mechanism.

### 10.4 Feature matrix rows

Added as `No` or `Planned` for every SDK, moved only by a passing suite:

- Level seek — filtering the index by `level ≤ N`
- Progressive band fetch — mixed per-chunk degree
- Full-union equivalence — a max-budget decode equals a non-LOD decode
- Encode: importance-ordered levels

---

## 11. What this proposal costs

Stated together so a reviewer can weigh them without assembling them from the sections above.

1. **One appended field**, `u32 level` on the Chunk Index (§4.2) — four bytes per index entry, and
   only on a file that opts into carrying it. It is the sole wire change.
2. **A meaning for a field that was informational** (§4.1). This is a tightening of what a writer
   may emit under the `progressive` profile and a promotion of `level` from a hint to a normative
   subset key; it changes no existing file, because the single-level union is the whole scene either
   way.
3. **A coordination constraint on the Chunk Index's appended-field order** (§4.2, §12.1), shared
   with keyframe-delta — the one genuinely fiddly part, because two extensions append to one frozen
   record.
4. **A small new invariant class in readers** — §9's structural refusals, most of them the
   index/record consistency check the format already performs on other duplicated fields.
5. **A reader-side fetch policy** (§3.3, §3.4). It is optional: a reader that ignores it fetches
   everything and is correct (§5).

Against these, the layer buys level-of-detail seeking and coherent progressive refinement — the two
capabilities of §1 — with no new record, no new codec, no manifest, no version gate, and no change
to the reconstructed scene. That economy is the argument for its shape, and it is possible only
because the format already carried both axes: a per-chunk `level` field and per-band byte ranges,
waiting to be given a meaning and an order.

---

## 12. Disposition

The design was reviewed and **accepted**. Every question it left open was ruled on; each ruling is
recorded here and folded into the section it affects, so the document has no section that
contradicts a decision and no reader has to hold both a recommendation and its outcome in mind.

| #   | question                                           | ruling                                                                                                                                                       | folded into |
| --- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- |
| 1   | Chunk Index appended-field order vs keyframe-delta | `level` appends last; keyframe-delta block keyed to `temporal_model`; presence by `content_length`; **any third appender MUST switch to a presence bitmask** | §4.2        |
| 2   | Per-level quality: a dedicated record, or metadata | Metadata keys now; size is index-derivable; defer a record until evidence                                                                                    | §4.4, §3.2  |
| 3   | A network manifest                                 | Not added; the byte-range index suffices and a manifest breaks "one resource"                                                                                | §8          |
| 4   | Additive levels vs replacement levels              | Additive; forward compatibility is incompatible with replacement                                                                                             | §3.1, §5    |
| 5   | Must every level cover the whole timeline          | No; only level 0, and only under the `progressive` profile                                                                                                   | §3.5, §9    |

Rulings 3, 4 and 5 are the same judgement the existing specification makes everywhere — the format
takes on the smaller thing. Ruling 3 declines a second representation of facts the index already
carries, the keyframe-delta §4.5 argument reused. Ruling 4 declines the model that would have needed
a version gate, the object-layer §5-versus-keyframe-delta-§5 distinction reused. Ruling 5 declines
to force a coverage rule on levels that only add detail locally, so an honest sparse level is not
made a refusal. Rulings 1 and 2 carry the most implementation weight and are written up in full
below.

### 12.1 The Chunk Index appended-field order

This is the one genuinely load-bearing coordination in the design, and it matters because the
format's append-only extension model (spec §4.2) was built for a _single_ line of evolution, and
this is the first time two independent optional extensions append to the same frozen record.
keyframe-delta appends six fields to the Chunk Index — `chunk_kind`, `delta_mode`,
`reference_offset`, `keyframe_offset`, `depth`, `live_count` (spec §5.8) — present only under
`temporal_model = "keyframe-delta"`; this layer appends one, `level`. Appended fields are positional
and a reader sizes them from `content_length`, so a reader that meets a Chunk Index with trailing
bytes must know _which_ extension wrote them and _in what order_.

**Decided.** The layout of the appended region is fixed, in this order, and recorded in the registry
so it is decided once:

- **The keyframe-delta block comes first, and its presence is keyed to `temporal_model`.** It is
  present exactly when the model is `keyframe-delta`, which a reader has already read from the
  Header before it parses the index — so a reader knows, before it reaches the appended region,
  whether the six-field block is there.
- **`level` is last, and its presence is read from `content_length`.** After the band array and the
  conditional keyframe-delta block, four remaining bytes are `level`; none means the file does not
  carry it. A single trailing `u32` is unambiguous given the fixed order and a predecessor block
  whose presence a Header field already decided.
- **Re-verified against the merged record at implementation time**, exactly as the object layer
  re-verifies its opcode assignments against `main` (object-layer §12.6), because the append region
  is spent by more than one design at once and the only safe layout is one checked at landing.

**And the escalation is normative, so the scheme cannot grow into ambiguity.** The layout above is
unambiguous for _exactly these two_ appenders, and unambiguous only because one of them is keyed to
a Header field: length alone distinguishes "keyframe-delta block present" from "absent" only because
`temporal_model` has already answered that, leaving a single trailing scalar for length to resolve.
A third _independent-optional_ appender — one whose presence is not already settled by a Header
field — breaks this, because two unkeyed optional blocks make "trailing bytes" ambiguous again.

> **Any third appender to the Chunk Index MUST introduce a presence bitmask** — a small appended
> field, read first, whose bits declare which later appended blocks are present — rather than adding
> a third positional block.

The bitmask is not built now, and the reason is the object-layer §12 principle that a mechanism
built before the file that needs it is a mechanism nobody has tested: two appenders, one of them
`temporal_model`-keyed, are safe positionally, so the answer to "do even two appenders justify the
bitmask" is **no**. It is the pinned next step — documented here, built at appender three — so that
the positional scheme is safe today and cannot be extended silently past the point where it stays
safe.

### 12.2 Per-level quality: a metadata key, or a record?

§3.2 established that a level's deviation from the full scene is real but content-and-encoder
dependent, so the format can only report it as an advisory figure. §4.4 puts that report in a
`lod_quality` metadata key rather than a dedicated front-matter record.

The case for a key: a per-level _size_ is already derivable from the index (sum `chunk_length` over
a level's entries), so the only datum a record would add is quality, and one advisory scalar per
level is exactly what a metadata key is for. The case for a record, if the maintainer wants it
later: a record could carry a richer per-level descriptor — a measured PSNR against the full scene,
a coverage fraction, an anchor for a per-level thumbnail — the way the Object Table carries
per-object descriptors, and a record range-reads independently where a metadata blob does not.

**Decided: a metadata key now, a record deferred until a consumer demonstrates it needs more than
one advisory scalar per level.** This is the object-layer §12.3 judgement on embeddings reused —
store the cheap advisory form, and let the richer form be an append when evidence asks for it — and
the keyframe-delta judgement against a second index reused: do not add a record whose only content
is derivable or advisory until something cannot be served by the key. No `Level Table` opcode is
reserved now; the key covers every use this design can currently name, and reserving a number for a
shape no consumer has asked for is exactly the speculative reservation the format declines
elsewhere. If a consumer later needs a richer per-level descriptor, adding the record is a clean
append on the relighting block's principle — reserve the ground then, define it against the file
that wants it.

---

## 13. Deliberately deferred

Named so the boundary is a decision rather than an omission, in the shape spec §10.1 uses.

- **Spatial subdivision within a temporal chunk.** The within-chunk detail axis, reserved by spec
  §10.1 and left there by §6. This layer is the between-chunk axis and composes with the reserved
  one when it lands.
- **Per-gaussian SH degree.** Reserved by spec §10.1. The quality axis here drops whole bands
  uniformly; spending degree per gaussian is a larger change with its own evidence.
- **A presence bitmask for Chunk Index appended fields** (§12.1). Not built, because two appenders —
  one of them keyed to `temporal_model` — are safe positionally; it is normatively required of the
  _third_ appender, so the direction is pinned rather than merely noted.
- **A dedicated per-level descriptor record** (§12.2). Deferred to a metadata key until a consumer
  needs more than one advisory scalar per level.
- **A network manifest and client-side adaptive selection policy** (§8). The format carries the
  facts a selection policy needs; the policy itself is the client's, and a manifest is declined
  outright.
