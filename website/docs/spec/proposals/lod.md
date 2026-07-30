# Proposal: level-of-detail and progressive refinement

**Status: accepted design. Not yet normative, not yet implemented, and not to be emitted by any
writer.** Nothing in this document changes what a conforming file looks like today. It is the
approved design, written at wire precision, and it becomes a revision of
[the specification](../index.md) and a set of entries in [the registry](../registry.md) as the
implementation lands. Until it does, the specification is the format and this is a plan.

Every question this design left open has been decided; the decisions are recorded in §12 and folded
into the sections they affect, so no section contradicts a ruling.

This layer is **not a temporal model** and it does not change reconstruction. It is closest in kind
to the object layer: a set of optional additions that a reader may ignore and either reconstruct the
same full scene or, for a `keyframe-delta` layout that violates the old global tiling rule, refuse
cleanly. One rule fixes the declared meaning of a field the specification already carries but
currently leaves informational. Where the object layer added a transform, this layer adds **nothing
to reconstructed gaussian state at all** — it is a rule about which bytes a reader must fetch to
obtain a chosen part of a scene it could already obtain in full. That difference is the whole of §5.

---

## 1. What is missing

The format seeks in one dimension. A reader displays instant `t` by reading the index and then the
byte ranges of the chunks whose interval contains `t` (spec §8). It has one dial for _how much of an
instant_ to fetch — spherical harmonic bands ride in their own records with their own byte ranges,
so a reader that wants fewer bands transfers fewer bytes (spec §5.7) — and no dial at all for _how
much of the scene_ to fetch. An instant is all of its gaussians or none of them.

Two capabilities are absent, and they are the two a consumer streaming a large scene over a network
asks for first:

- **Level of detail.** A preview, a thumbnail, or a first pass over a large scene does not need
  every gaussian; it needs the _important_ ones — a subset that reads as the scene at lower fidelity
  — and it needs to fetch only that subset, not fetch the whole scene and discard most of it. The
  format has nowhere to say which gaussians are the important ones, and no way for a reader to fetch
  that subset by byte range.
- **Progressive refinement.** A reader that has fetched a coarse version and then has more time or
  more bandwidth should be able to _add_ detail to what it already has, rather than re-fetching.
  Each deliberately selected, complete refinement unit should leave a coherent scene, not a
  half-updated one. The format transfers a scene as one block per instant; it has no notion of a
  coarse-first, refine-later order, and no statement that stopping a read plan between complete
  units leaves a valid scene rather than a corrupt one. Physical EOF recovery remains a separate
  contract (§3.3).

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
declared meaning, gives the index a way to seek on it, and states the property that makes
incremental refinement coherent.

---

## 2. Scope

**Designed here:** the declared meaning of the `level` field — how a writer assigns gaussians to
levels, what "level ≤ N" reconstructs, and the opt-in key that authorizes a reader to filter on
`level` at all; the one appended index field that lets a reader fetch a level by byte range alone
(the seek-predicate extension); the valid-at-every-prefix property that makes any incremental fetch
of levels and contiguous SH bands decode to a coherent scene; how level composes with the chunk
index, with both temporal models, and with the object layer; the sense in which a level carries an
error bound and the sense in which it cannot; forward compatibility; and the conformance corpus the
layer needs.

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
- **Per-gaussian stored SH degree.** Reserved by spec §10.1. The quality axis here selects whole
  contiguous band ranges during a read while every chunk retains the scene-wide stored degree; a
  per-gaussian encoded degree is a different and larger change.

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
  raises its requested level from `N` to `N+1` **keeps everything it has** and fetches only the
  level-`N+1` chunks. This is what makes refinement an append rather than a re-fetch (§3.4).
- **The full scene is reached at any request at least as high as every present level.** In
  particular, requesting `lod_levels - 1`, the greatest level authorized by the Header's exclusive
  upper bound (§4.4), includes every present chunk even when the bound is deliberately larger than
  the greatest level present. Fetching every chunk and taking that union are therefore the same
  operation. A reader that ignores levels entirely gets the full-detail scene with no change to any
  arithmetic. §5 turns this sentence into the forward-compatibility argument.

**How a writer assigns levels.** The writer ranks its gaussians by whatever importance metric it
chooses (§2), partitions the ranked list into tranches — level 0 the top tranche, each subsequent
level the next — and emits each tranche as one or more chunks tagged with that level. A gaussian's
`object_id`, its window, its motion and every other attribute are unchanged by which level it lands
in; level is a property of the _chunk_, assigned by the writer's ranking, and it costs nothing
per-gaussian because the field already exists per-chunk.

**One-level ownership is an encoder requirement under both temporal models.** A writer partitions
logical gaussians; it does not clone one into multiple tranches. `gaussian-birth` has no wire
identity attribute, so a reader cannot distinguish an intentional pair of similar gaussians from one
logical source gaussian restated at two levels. That ownership rule is therefore tested only by
source-aware encoder conformance: compare every requested state and the full union to the known
source state (§10). It is not a `gaussian-birth` reader refusal. `keyframe-delta` does carry
`gaussian_id`, so one-level ownership is structurally enforceable there by an encoder or full-file
validator: the first occurrence of an id fixes its level for the whole file, and every later
keyframe restatement, update, birth or death for that id MUST remain at that level. Its scene-wide
live-uniqueness and no-reuse rules remain separately enforceable after active level chains are
united and across their full identity history (§3.5, §9). Level never creates a second identity
namespace and an id never migrates between levels. An ordinary range seek validates the identity
evidence it fetches; it does not scan the rest of the file to prove this whole-history invariant
(§3.5).

**This meaning is opt-in, and that is load-bearing — the `level` field is not being retroactively
reinterpreted.** Spec §5.5 defines `level` as "producer's hierarchy level; informational only", and
a file's `level` values may already mean something that is not importance: the reference writers,
for one, tag a chunk with its depth in the temporal partition tree, so a file in the wild can carry
`level > 0` that has nothing to do with detail. The cumulative-subset rule above therefore applies
**only to a file that declares it uses LOD levels** — specifically by carrying `lod_levels` in
`Header.attributes` (§4.4). A value found anywhere else does not make the declaration. Absent that
Header declaration, `level` keeps its §5.5 informational meaning untouched, so §4.4's freeze on
existing field meanings holds: this proposal does not change what `level` means in any file already
written; it gives a _new, declared_ meaning to files that opt in. §4.1 and §4.2 make the reader
consequence exact: **a reader MUST NOT filter on `level` unless `Header.attributes` declares LOD**,
and one that does not filter loads every chunk and gets the full scene regardless of what `level`
meant.

### 3.2 The detail axis is exact per gaussian, lossy only by omission

This is the degradation contract, and it is the strongest statement the format can make about a
coarse level, reached the same way keyframe-delta and the object layer reach theirs — by finding the
place where the error does not compound:

> **Every gaussian present at level `≤ N` is bit-identical to that same gaussian in the full scene:
> the same bins, the same quantization, the same declared bounds. A level cut removes gaussians; it
> never approximates one. The reconstructed gaussian state at level `N` is therefore an exact subset
> of the full reconstructed gaussian state.**

There is no dequantization step for level, no grid, no per-level rescaling — a coarse level is not a
coarser _encoding_ of the scene, it is a _subset_ of the same encoding. Spec §5.3's bound holds
verbatim on every gaussian a level decode contains, at every level, because the bytes those
gaussians are decoded from are the same bytes the full scene decodes them from.

What the format therefore **cannot** declare is a numeric bound on the difference between a coarse
level and the full scene, and it is worth being as candid about this as spec §8 is about seek cost:

> A level cut omits complete gaussian rows. The format defines neither a metric over the missing
> rows nor a numeric bound comparing that subset with the full reconstructed state. Which rows are
> placed in each tranche is the encoder's importance policy, not a container guarantee.

This proposal therefore defines **no per-level quality scalar**. A number without a common metric,
units, scale, direction and sparse encoding grammar would not be interoperable; calling it advisory
would not repair that. §12.2 records the decision to defer both a metadata key and a richer
descriptor until a concrete metric and consumer can define them together. §7 works the bound through
both axes without inventing one.

### 3.3 The quality axis — progressive spherical harmonics

The second axis needs no new rule, only a name and an order, because the wire already carries it. A
scene's spherical harmonics are stored one band per SH Band Stream record (spec §5.7), each band
with its own byte range in the Chunk Index (spec §5.8), and "a reader that has decided to evaluate
fewer bands never transfers the ones it will not use" (spec §5.7). Bands are whole and additive:
bands `1..b` are a degree-`b` scene (spec §6.5).

Progressive quality is therefore: **fetch band 0 (the DC term, carried in the chunk's `color`
stream) first, then band 1, then band 2, then band 3, in ascending order, each band's records added
to the scene already in hand.** At each step the scene is a valid lower-degree scene of exactly the
gaussians fetched so far. Dropping the top bands does not corrupt colour; it removes their
view-dependent variation, and the appearance falls back toward the lower-degree fit — which is a
real, defined scene (a degree-`b` reconstruction), not an artefact.

**Bands refine as a contiguous prefix, and this is a MUST, not a convention.** A degree is the
contiguous set of bands `1..D` (spec §6.5); bands `0..b` are a valid degree-`b` scene, but band 2
_without_ band 1 is not a valid degree-anything — it is an incomplete degree, and evaluating it is
the "partial degree" spec §6.5 forbids. So a reader evaluates a gaussian at the **highest contiguous
prefix** of bands it holds: if bands arrive out of order — band 2 fetched before band 1 — the reader
MUST hold band 2 and keep evaluating at degree 0 until band 1 arrives, rather than evaluate a
degree-2 colour from a gap. The valid-at-every-prefix property of §3.4 is stated on _contiguous_
band prefixes for exactly this reason; it is the one place the two axes differ (§3.4).

One reading has to be made explicit, because progressive refinement across many chunks reaches it
and single-shot decoding does not. The Header declares one `sh_degree` for the scene (spec §6.5),
and **every chunk stores that same complete band set**. This proposal does not change the scene-wide
stored degree or permit a writer to omit a declared band from selected chunks: current readers
correctly treat such a file as malformed under spec §6.5. Progressive transfer changes only which of
those uniformly stored ranges a particular read has fetched. A partially transferred scene may
therefore hold some chunks at a higher fetched degree than others — one chunk fetched through degree
3, another still holding only its base colour — while the file itself remains a uniform degree-3
file.

> A gaussian is evaluated at the highest contiguous degree whose ranges this read has fetched.
> `sh_degree` is both the stored scene-wide degree and the per-read ceiling. Different chunks MAY
> have different **transfer caps** in one partial read, but every chunk in the file MUST store all
> bands `1..sh_degree`.

This is the natural reading of the per-band byte ranges already in the index — they exist precisely
so a read can fetch a band or leave its range untouched per chunk — and it preserves §6.5's
scene-wide storage invariant for existing full decoders. A reader still MUST NOT assemble a partial
degree out of part of a band (spec §6.5); it MAY hold different contiguous fetched-band counts for
different chunks. An old reader fetches every stored band as before and sees the one declared
scene-wide degree.

**A transfer cap is deliberate read input, never an inference from EOF.** Before selecting ranges,
an indexed reader MAY name a contiguous cap for each selected chunk; an explicitly configured
streamed read MAY likewise discard complete higher-band records according to caps it already knows.
In both cases the reader chose the lower degree independently of which bytes happened to arrive. A
streamed reader with no such read plan expects every retained chunk to carry all bands through the
Header's `sh_degree`. If that stream ends before the final chunk's expected band set is complete,
the truncation contract in [notes §“Truncation and corruption”](../notes.md) applies unchanged: drop
that chunk and any later short trailing chunks, retaining the longest chunk prefix whose stored band
sets are intact. Accidental EOF MUST NOT be reinterpreted as a mixed per-chunk transfer cap.

### 3.4 The valid-at-every-prefix property

The format's contribution to progressive refinement is one property, and it is a decode property —
about what a partial set of fetched bytes reconstructs to, not about downstream consumption or when
more bytes should be requested:

> **Valid at every deliberate refinement prefix.** Take any set of levels the file authorizes
> filtering on (§4.1), crossed with an explicitly selected, per-chunk **contiguous** band prefix
> `0..b`. What the reader holds is a complete, decodable scene: a set of gaussians each carrying its
> full required attribute set, each reconstructed by spec §3 with no missing field and no dangling
> reference. A reader that intentionally fetches only that selection decodes a coarse scene, never a
> corrupt one.

“Prefix” here describes the additive units selected by a read plan, not an arbitrary byte prefix of
a file. A physical stream cut still recovers by the existing record and band-integrity rules: no
partial record is interpreted, and a trailing chunk missing any Header-declared band is dropped
rather than assigned a lower transfer cap (§3.3). The distinction keeps deliberate indexed selection
and streamed truncation from producing two meanings for the same missing bytes.

Two axes, and they differ in one way worth stating because a reader must not treat them alike:

- **Levels compose by free union.** Any subset of the authorized levels is a valid set of gaussians
  — gaps included (levels 0 and 2 without 1 is fine, §9) — because a level's chunks are ordinary
  chunks ("independently decodable; nothing in a chunk references another chunk", spec §5.5) and any
  set of complete gaussians is a scene. So the level part of a prefix has no ordering or contiguity
  rule.
- **Bands compose only as a contiguous prefix.** A band is _not_ self-contained the way a level's
  chunk is: bands `0..b` form a degree, but a gap does not (§3.3). So the band part of a prefix is
  `0..b`, and out-of-order bands are held, not evaluated.

The one place a chunk references another is a keyframe-delta chain, and that chain is confined
within a single level by keyframe-delta §3.6 (a delta's reference shares its level), so a level's
chains resolve using only that level's chunks. §3.5 states the composition precisely; the point here
is that self-contained levels and contiguous band prefixes are what keep a partial fetch coherent.

Because the additive axes let a later fetch _add_ to an earlier one rather than replace it (§3.1,
monotone), a consumer that fetches incrementally never re-fetches: raising the level filter or the
band prefix fetches exactly the difference, a set of byte ranges the index names (§4.2), and the new
gaussians and bands compose onto the held scene by union. The format guarantees the coherence of the
result; it does not prescribe the increments, which are the consumer's.

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
For `gaussian-birth`, Header `lod_level0_complete = "true"` means the **interval union** of all
level-0 chunks covers `[0, duration_sec)` without a gap. Level-0 chunks MAY overlap, exactly as
ordinary `gaussian-birth` chunks may; the promise is coverage, not tiling.

**Level and `keyframe-delta`, and the one place LOD changes a normative rule.** keyframe-delta tiles
the timeline with state chunks and reaches an instant by walking a chain back to a keyframe (spec
§11). Its tiling rule is **global and normative**: sorted by `t0`, each state chunk's `t1` equals
the next chunk's `t0`, and a reader MUST refuse a file whose state chunks overlap (spec §11.1),
precisely so that `current(t)` — the unique index entry containing `t` — is unique (spec §11.8). A
multi-level LOD scene breaks that global rule head-on: level 0 and level 1 both carry a chunk
covering the same instant, so their chunks **overlap in time**, which the global rule reads as a
malformed file.

So under `keyframe-delta`, LOD does not merely add a filter; it **generalizes the global tiling rule
to sparse, independent level runs**:

> Within one level, state chunks MUST NOT overlap. Sorted by `t0`, chunks that touch belong to one
> contiguous **run**; a gap ends that run and a later chunk begins another. The first chunk of every
> run MUST be a keyframe, and every delta in the run MUST resolve, through same-level backward
> references, to a keyframe in that same run. A level need not start at `0`, end at `duration_sec`,
> or cover its gaps. `current(t, ell)` is therefore either the unique entry at level `ell` whose
> interval contains `t`, or absent.

This retains the two load-bearing parts of spec §11.1 — no overlapping state at one level, and a
unique current state wherever that level has coverage — without importing its full-clip coverage
requirement. Importing that requirement would contradict sparse enhancement levels: a level that
adds detail only for one part of the clip is valid (§9). A gap cannot be crossed by a delta chain;
requiring the next run to start with a keyframe makes each covered interval independently decodable.
For `keyframe-delta`, Header `lod_level0_complete = "true"` means level 0 has exactly one
non-overlapping run whose first `t0` is `0`, whose adjacent intervals touch, and whose final `t1` is
`duration_sec`. No other level is required to cover the full clip.

```
chunks_for(t, N) = for each present level ell <= N where current(t, ell) exists:
                       the keyframe-delta chain for current(t, ell), contained in its run
                   unioned over ell
```

**`gaussian_id` remains scene-wide across that union and its history; a level or run is not an
identity namespace.** The first state-bearing occurrence of an id — in a keyframe state or a birth —
establishes one immutable `id -> level` assignment for the whole file. Every later keyframe
restatement, update, birth or death naming that id MUST occur at the same level. An id that appears
in a level-0 sparse run and later appears in a non-overlapping level-1 run has migrated and is
invalid even when the first run contains no explicit death: ending a run or leaving a coverage gap
does not implicitly end an identity's scene-wide history.

Spec §11.2's uniqueness rule also applies after the active level states are united: at every
requested `t` and `N`, each live `gaussian_id` MUST occur at most once across all `current(t, ell)`
chains for `ell ≤ N`. Its no-reuse-after-death rule applies to one global lifecycle history across
every level and every separated run. An id that dies cannot later birth as a different gaussian,
even at its original level and even if the two lifetimes never overlap and each run is internally
valid.

**Validation scope preserves range seeking.** `gaussian_id` lives inside state-chunk payloads, not
in the Chunk Index. This proposal does not duplicate a potentially scene-sized `id -> level` map
into the summary, and an ordinary indexed seek MUST NOT fetch unrelated chunks merely to reconstruct
the file's complete ownership or death history. It validates every identity fact in the chains it
actually fetches for that seek, using scratch state bounded by the selected chains' validated
decoded sizes. It MUST NOT retain a cumulative scene-wide identity map across seeks. A source-aware
encoder conformance run and a full-file validator scan all state-bearing payloads and therefore MUST
prove immutable ownership and no reuse exhaustively, but that validator MUST remain bounded too. A
conforming validator either makes repeated passes over numeric `u32` id ranges whose width is chosen
so the worst-case identity slots fit its memory budget, or emits fixed-size
`(id, level, interval, operation, chunk offset)` events through a memory-capped external sort by
`(id, time, record order)` and then checks one id's ordered history at a time. It MUST NOT build a
scene-sized in-memory map. Both strategies stream one chunk at a time; the trade is extra passes or
spill I/O, never memory that grows with cumulative identities. Consequently a direct seek may not
discover a migration that exists only in a run it did not fetch, or across two disjoint seeks; that
is the stated limit of partial validation, not permission for the file to violate the invariant.

The exhaustive validator's **identity-memory budget** covers every validator-owned identity key,
lifecycle entry, partition table and in-memory external-sort working or staging buffer, plus any
identity-bearing decoded chunk storage retained after the validator advances to another chunk. Its
reported `identityRetainedBytesHighWater` is the maximum total of those allocations. An on-disk
spill file is not memory, but every buffer used to produce or consume it counts. The counter
excludes only the input and decoded arrays for the one current chunk while that chunk is being
consumed; those are independently bounded by the chunk's already-validated decoded sizes (§5.6).
Before the next chunk is fetched, identity events needed later MUST have been reduced into the
budgeted partition state or emitted to the budgeted external sort, and the previous chunk's decoded
identity-bearing arrays MUST be released or counted. The runner instruments allocations at this
boundary, so retaining an earlier keyframe as an unreported identity map violates the budget.

A reader always has the complete active union for its requested `t` and `N`, so if it finds the same
live id in two fetched levels it MUST refuse, naming the id, `t`, both levels and the chunks that
supplied it; silently overwriting one level in an id-keyed state map would produce a plausible wrong
scene. A full-file validator that finds an id associated with two levels without such a live
collision MUST refuse the cross-level migration, naming the id, both levels and the first offending
chunks. If it finds reuse after death it MUST separately refuse, naming the id, the earlier level,
run and chunk in its lifecycle, the death, and the later run and birth chunk. A partial reader that
observes either history in its fetched chains issues the same refusal. These are distinct failures:
the first violates uniqueness in one reconstructed union, the second violates immutable level
ownership without requiring overlapping lifetimes, and the third violates the scene-wide identity
history after an explicit death.

This is exactly the generalization keyframe-delta §7 anticipated in writing — "if spatial
subdivision within a temporal chunk is ever added, `current(t)` becomes a set rather than a single
entry; the chain walk is unaffected" — with the set indexed by level rather than by region.

**Because it changes a normative refusal rule, this generalization is gated: it is legal only when
`Header.attributes` carries `lod_levels` (§4.1), and a reader applies the level-run rules only
there.** The consequence for an old reader is the honest one, and it is the single exception to §5's
backward-decode story: a reader that does not implement LOD still enforces the global tiling rule,
so it **refuses** when populated levels overlap or when the only populated level leaves a gap (spec
§11.1), rather than loading the LOD union. That refusal is clean — a stated rule naming the
overlapping or gapped intervals, not silent corruption — but it is a refusal. §5 scopes the
forward-compatibility claim precisely around this: it holds unconditionally for `gaussian-birth`
(which has no tiling rule — chunks may overlap freely, spec §8) at any number of levels, and for a
single-level `keyframe-delta` file whose sole level still satisfies spec §11.1. Any `keyframe-delta`
layout that needs the sparse level-run rule requires an LOD-aware reader. A level that adds no
detail over some interval simply has no run there and contributes nothing to the union at those
instants — which is not an error (§9).

**Level and the object layer.** `object_id` is a per-gaussian attribute that rides in the chunk
(spec §6.6); an Object Track is front matter applied once after base reconstruction (spec §3,
§5.15.7). Level filtering changes _which gaussians are present_; it changes neither. A track read at
open applies to whichever of its object's gaussians a level decode happens to include, and because a
track is rigid and identical for all of an object's gaussians, an object that is split across levels
— coarse gaussians at level 0, fine detail at level 2 — refines correctly for free: the same pose
moves whatever subset is present. Object filtering (keep `object_id == k`) and level filtering (keep
`level ≤ N`) are two predicates on the loaded set and compose by intersection, in either order, with
no interaction.

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

### 4.1 The `level` field gains a _declared_ meaning, not a wire change

Chunk (`0x05`) and Delta Chunk (spec `0x10`) already carry `u32 level`. No byte moves. What changes
is that a file MAY now _declare_ that its `level` values carry cumulative LOD importance (§3.1), by
carrying the `lod_levels` key specifically in `Header.attributes` (§4.4); and the seek and
reconstruction rules of this layer apply to such a file and to no other. A `lod_levels` string found
only in a Metadata record is not this declaration.

This is deliberately an opt-in, and it is what keeps the change inside spec §4.4's freeze on
existing field meanings:

- **A file that declares LOD** (`Header.attributes["lod_levels"]` present) uses `level` as §3.1's
  cumulative subset key, and a LOD-aware reader MAY filter on it (§4.2).
- **A file that does not** keeps `level` at its spec §5.5 meaning — "producer's hierarchy level;
  informational only" — verbatim. Its `level` values may mean temporal-tree depth, or nothing, or
  anything a producer put there; the reference writers already emit `level > 0` for temporal
  partition depth, so this case is not hypothetical. **A reader MUST NOT filter on `level` in a file
  whose Header does not declare LOD**, and one that does not filter loads every chunk — the full
  scene — regardless of what `level` meant.

So no file already written changes meaning, and no reader can mistake a temporal-depth `level` for
an importance level: the importance reading exists only where a producer asked for it. This is the
`visibility_profile` precedent (spec §3.1) — a field the format decodes the same either way, with a
metadata key stating which intent applies — made load-bearing, because here the key gates a _seek_,
not only a label. §5 argues why this needs no version gate even so.

### 4.2 Chunk Index (`0x08`) — one appended field, and the seek predicate

The seek predicate of §3.5 filters on `level`, and a reader must be able to evaluate it **from the
index alone**, without fetching a chunk to learn its level — that is the whole point of a seek
predicate. The Chunk record carries `level`, but the Chunk _Index_ (spec §5.8) does not. So the
index gains it:

```
... existing fields, unchanged, through the variable band array ...
u32  level    -- mirrors the level of the Chunk / Delta Chunk this entry describes
```

The Chunk Index is frozen (spec §4.4), and this is the append that a frozen record permits: an older
reader parses the fields it knows and skips the remainder to `content_length` (spec §4.2), while a
LOD-aware reader uses the Header gate to locate four more bytes.

> **In a conforming indexed file, the appended `level` is semantically and physically present on
> every Chunk Index entry if and only if `Header.attributes["lod_levels"]` is present and valid.**

The reader validates the Header before parsing the index. With the gate set, one entry too short to
contain `level` would force a seeking reader to fetch that chunk merely to decide whether to fetch
it, breaking the range-seekable contract; the reader MUST refuse before selecting chunks and name
the short entry. It MUST also refuse when an index `level` disagrees with the Chunk or Delta Chunk
it points at, naming both — the same corruption check the keyframe-delta index fields make on
duplicated facts (spec §5.8). Without the valid gate, the current schema contains no index `level`:
a conforming producer MUST NOT emit that field, and a reader MUST NOT interpret any trailing bytes
as it. A malformed `lod_levels` value is refused as a malformed gate (§9), not used to guess the
field's presence. A streamed file with no Chunk Index still filters on each Chunk or Delta Chunk's
existing `level` as records arrive.

With the gate present, the seek is the one-line extension of spec §8 given in §3.5: the same index
scan, one more comparison per entry, no chunk fetched to evaluate it. **The layer costs a seeking
reader nothing beyond the comparison** — the index is read once at open, as it always is, and
`level` rides in it. Without the gate, there is no level predicate and no index field to decode.

**The order of appended fields on this record is coordinated, and this is a real constraint, not a
formality.** keyframe-delta also appends to the Chunk Index — six fields, `chunk_kind`,
`delta_mode`, `reference_offset`, `keyframe_offset`, `depth` and `live_count` (spec §5.8), present
only under `temporal_model = "keyframe-delta"` — and appended fields are positional, so two
independent extensions appending to one frozen record must agree on an order or a reader cannot
locate either. §12.1 is the ruling. The normative layout of the appended region is fixed:

```
[ base Chunk Index, through the variable band array ]
[ keyframe-delta block: the six fields above, present iff temporal_model == "keyframe-delta" ]
[ level: u32, present iff Header.attributes["lod_levels"] is present and valid ]
[ future extension suffix, if any ]
```

`level` follows the keyframe-delta block. Both blocks have Header-visible presence gates:
`temporal_model` locates the six-field block and a valid `lod_levels` locates the four-byte `level`.
A reader evaluates those gates in order, so it knows the cursor immediately after all current fields
without assigning meaning from record length. `content_length` is the record boundary and the check
that every gated block fits; it is **not** a discriminator for either block. If bytes remain after
the blocks this reader knows, they are an opaque future append-only suffix. The reader skips them to
`content_length`; in particular, a non-LOD reader never treats the first four unknown bytes as
`level`.

**The next appended extension must make the future suffix self-describing.** Any third appender to
the Chunk Index MUST place a presence map at the first byte after the two existing Header-gated
blocks, with bits declaring the later blocks in that suffix. A future reader locates the map by
evaluating the same two Header gates first; a current reader skips the unrecognized map and its
blocks by `content_length`. This preserves append-only behavior while preventing several
independently optional positional blocks from making the suffix ambiguous. The map is not built now:
the two existing blocks are already located without it, and §12.1 pins the deterministic location
and escalation rule for the extension that first needs it.

### 4.3 Spherical harmonic bands — no wire change

The quality axis adds nothing to the wire. Bands are already one record each with their own index
byte range (spec §5.7, §5.8); the progressive fetch of §3.3 is a reader reading a contiguous prefix
of ranges it can already address. No field, no opcode, no codec.

### 4.4 Registry additions

None changes the format version; each is the kind of addition spec §10 permits within version 1.
They are **metadata keys, not a profile**: the Header's `profile` field is a single string, so a
`progressive` _profile_ could not coexist with `objects`, `capture` or `baked`, and this layer's own
§3.5 claim is that levels compose orthogonally with the object and temporal layers. A promise that
cannot be declared alongside the others would contradict that. Metadata keys are orthogonal by
construction — a file carries as many as it likes — so LOD support is declared with keys and
composes with any profile.

- **`lod_levels`** — a canonical **exclusive upper bound** on level numbers, encoded as
  `[1-9][0-9]*` in the numeric range `1..4294967296`, inclusive. Every present chunk and index
  `level` MUST be strictly lower than the bound. Equality to the greatest present level plus one is
  neither required nor implied: over-declaration is valid. A reader parses the value with checked
  arithmetic wide enough to represent the upper endpoint. **Its presence in `Header.attributes` is
  the opt-in gate of §4.1**: that exact Header entry declares the file's `level` values are
  cumulative LOD levels, authorizes filtering, and physically gates the Chunk Index append (§4.2). A
  file whose Header lacks it is not an LOD file, whatever its chunk `level` values or later Metadata
  records contain.

  The value is an upper bound for validation and requested-level comparison, **not an allocation
  count**. A valid requested level lies in `0..lod_levels - 1`; requesting `lod_levels - 1` includes
  every present level and therefore reconstructs the full union even when no chunk carries that
  number. Gaps and unused values below the bound are legal (§9). A reader MUST represent observed
  levels sparsely — for an indexed read, by distinct values in validated entries — and MUST bound
  level bookkeeping by the number of entries it has validated, never by `lod_levels`. A streamed
  reader likewise compares each scalar as it arrives and does not preallocate a ladder. A recovered
  truncated stream naturally may observe fewer levels than the Header permits; that does not make
  the bound false or require the reader to synthesize missing levels. Thus a small file with levels
  `0` and `2` may validly declare `lod_levels = "8"`, while levels `0` and `4294967295` require the
  upper endpoint `lod_levels = "4294967296"`; both stay small to decode.

  **This key MUST live in `Header.attributes`, not in a trailing Metadata record**, and the reason
  is the format's range-seekability (AGENTS §2). A registry metadata key may in general appear
  either in the Header's `attributes` map (spec §5.1) or in a Metadata record (spec §5.11); a
  Metadata record is not part of the summary and nothing orders it before the chunks, so an indexed
  reader that opens from the Header, the Footer and the Chunk Index would not discover a gate placed
  there without scanning record framing through the file — and would then silently not filter,
  returning the full scene where the producer meant to authorize a coarse one. The gate authorizes a
  _seek_, so it must be visible to a seeking reader at open. The Header is the first record and
  always read at open, so requiring the key there makes the gate first-class for both read modes.
  **A reader MUST NOT treat a file as LOD on the strength of a `lod_levels` found only in a Metadata
  record; the gate is the Header key or it is absent.** A Metadata-only occurrence is legal but
  inert under this layer.

- **Header `lod_level0_complete`** — `"true"` when level 0 alone covers the timeline, so a reader
  that fetches only level 0 gets a complete coarse scene at every instant rather than one with holes
  in time (§3.5, §9). This is the promise the earlier draft attached to a `progressive` profile; as
  a key it composes, and a consumer needing a cheap coarse standalone pass can require it while
  still requiring, say, `objects`. Under `gaussian-birth`, the level-0 chunk intervals' union MUST
  cover `[0, duration_sec)` without a gap and MAY contain overlaps. Under `keyframe-delta`, level 0
  MUST be one non-overlapping run from `0` through `duration_sec`. An absent Header key or Header
  value `"false"` means level 0 is not guaranteed to be standalone. When present in the Header, the
  value grammar is exactly the lowercase ASCII string `"true"` or `"false"`, with no whitespace;
  every other value, including `"TRUE"` and `"1"`, MUST be refused as
  `lod-level0-complete-malformed`. It is a range-relevant promise like the gate, so only the
  `Header.attributes` occurrence has format semantics. Within the Header it is valid only alongside
  a valid Header `lod_levels`; an orphaned key cannot authorize LOD semantics or locate an index
  `level`, so a reader MUST refuse it as `lod-level0-without-gate` rather than advertise a coarse
  pass it cannot select. A same-named key found only in a Metadata record is legal but inert: it
  does not activate the promise, its value is not parsed by this layer, and it cannot override a
  Header value.

These two keys add no record. A level's transfer size at a chosen contiguous SH prefix is already
derivable from the index: sum `chunk_length` **plus the lengths of every selected SH Band Stream
range** over the level's entries. No per-level quality key is reserved: §3.2 shows the container has
no omission bound, and §12.2 defers a metric until its grammar and semantics can be specified for
interoperability. No new **profile** value is spent, and none is needed: a consumer requiring LOD
tests for `Header.attributes["lod_levels"]`, and one requiring a standalone coarse pass tests
`Header.attributes["lod_level0_complete"] == "true"`, either alongside whatever profile the file
already carries.

### 4.5 The summary is untouched, and no manifest is added

`level` is appended to the Chunk Index, which is already a summary record (spec §4.5); no new record
class joins the summary, so the contiguous-summary rule and the streamed CRC it protects keep
working with no new case, exactly as keyframe-delta §4.5 preserved them. And no separate manifest
resource is introduced — §8 argues the index _is_ the manifest.

### 4.6 Forward compatibility — an old reader sees the full scene, with one scoped exception

This is the property that makes the layer additive, and for the primary case it is stronger than the
object layer's, which had a transform an old reader would miss. The mechanism:

- The appended index `level` field is unknown bytes to an old reader, which steps over them by
  `content_length` (spec §4.2) — the mechanism §4.2 above relies on.
- The `level` field on chunks is one the current specification _already_ tells a reader to treat as
  informational, so an old reader already ignores it and already **loads every chunk regardless of
  level**.
- Every chunk still stores the Header's one complete `sh_degree` band set (§3.3), so an old reader's
  scene-wide band validation and full-band fetch are unchanged.

Loading every chunk regardless of level is the full scene, whatever `level` meant — for an LOD file
it is the union over all levels (§3.1); for any other file it is simply every chunk, as always. So
an old reader, ignoring this layer completely, reconstructs **the same full-detail decoded state it
reconstructs today** — with the compatibility boundaries that §3.5 established and §5 scopes
precisely:

- **`gaussian-birth`, any number of levels — fully forward-compatible.** It has no tiling rule;
  chunks may overlap freely (spec §8), so an old reader loads every chunk and gets the full union
  with no version gate and no degraded view.
- **Single-level `keyframe-delta` with full coverage — fully forward-compatible.** When its one
  level starts at `0`, ends at `duration_sec`, and has no gaps, it tiles the timeline exactly as
  spec §11.1 requires, so an old reader reads it unchanged.
- **Any `keyframe-delta` layout that needs the LOD level-run rule — not forward-compatible, and
  cleanly so.** Multiple populated levels normally overlap in time; a sparse sole level may leave a
  gap. The global tiling rule (spec §11.1) reads either shape as malformed, so an old
  `keyframe-delta` reader **refuses** it — naming the overlapping or gapped intervals, a stated rule
  rather than silent corruption. Such a layout requires an LOD-aware reader, and the Header's
  `lod_levels` gate is what keys the sparse, per-level chain validation.

For the forward-compatible cases there is nothing for an old reader to get wrong, because the layer
adds no reconstruction step it must run; it only lets a new, LOD-aware reader fetch less, and only
when the Header opts in (§4.1). The other `keyframe-delta` layouts produce a clean refusal, not a
wrong scene. §5 is the whole argument that this needs no _version_ gate even so.

---

## 5. Versioning: additive within version 1, and why there is no version gate

**The magic's version byte does not change. Existing files do not move. No frozen field changes.**
Every mechanism is one spec §10 already permits:

| what this adds                                             | §10 rule that permits it                    |
| ---------------------------------------------------------- | ------------------------------------------- |
| declared meaning for `level`, gated by Header `lod_levels` | registry/spec clarification, no wire change |
| `u32 level` on the Chunk Index                             | existing records MAY gain appended fields   |
| `lod_levels`, `lod_level0_complete`                        | registry addition                           |

There is **no _version_ gate** — no magic-byte bump and no `temporal_model` change. Header
`lod_levels` declares the cumulative meaning, gates the matching Chunk Index field, and authorizes a
new reader to apply the optional seek predicate; in the primary forward-compatible layouts it does
not make an old reader refuse:

> A temporal model changes what the base state _means_, so keyframe-delta gates on `temporal_model`
> and an old reader refuses (keyframe-delta §5). The object layer changes nothing about the base
> state but _adds a transform_, so an old reader that skips it sees a valid-but-static degraded
> scene (object-layer §4.6). This layer adds **neither a reconstruction step an old reader must run
> nor a transform it would miss** — its one new reading of `level` is opt-in (§4.1) and acted on
> only by a new reader that chose to filter; it does not change the gaussians an old reader loads.
> For `gaussian-birth` at any number of levels, and for a single-level `keyframe-delta` layout that
> still tiles the full clip, an old reader does not degrade; it loads everything, which is the full
> scene. So no version gate and not even a degraded view.

The exception is the one §3.5 and §4.6 name: **a `keyframe-delta` layout that relies on sparse level
runs rather than the global full-clip tiling**. Multiple populated levels normally overlap in time,
and a sparse sole level may leave gaps; the normative global tiling rule (spec §11.1) makes an old
`keyframe-delta` reader refuse either shape — cleanly, naming the overlap or gap. That is a
compatibility boundary, but it is not a _version_ gate and it is not silent: it falls out of a rule
the format already has, and the refusal is a stated one. So the design's claim is precise rather
than absolute: **additive and backward-decodable for `gaussian-birth` and full-clip single-level
`keyframe-delta`; a clean, rule-based refusal for an old reader on a `keyframe-delta` file that
needs the LOD level-run rule; never a silent wrong scene.**

The one thing that would have broken this is the design choice §3.1 settled, and it is worth naming
as the reason that choice is not merely aesthetic. Had levels been **replacement** levels — each
level a complete representation of the scene at its own fidelity, the way a resolution pyramid
replaces rather than adds — then "load every chunk" would have loaded the same region several times
over, once per level, and an old reader would have reconstructed an unintended union containing
multiple representations of the same region: a silent wrong state of exactly the kind this format
refuses everywhere. Replacement levels would have _needed_ a gate, because the full union would no
longer be the full scene. Additive levels need none, because the union over all levels _is_ the full
scene. Forward compatibility does not merely favour the additive model; it is incompatible with the
alternative.

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
becomes under each axis, and the answer, on both axes, is the same shape: **exact for what is
present, and no format-level bound on what is omitted.** That symmetry is worth stating because it
is easy to get the second half wrong.

**The detail axis: exact per gaussian, no bound on the omission.** §3.2 is the whole statement:
every present gaussian is bit-identical to its full-scene self, so its declared bounds hold verbatim
at every level. A lower level is an exact subset of the reconstructed gaussian rows, but the format
defines no metric or numeric error bound over the rows that are absent (§3.2).

**The quality axis: the same, and the tempting shortcut is wrong.** For the bands a reader keeps,
their declared SH bounds (`sh_band<b>`, spec §5.3, §6.5) hold verbatim — the coefficients present
are reconstructed exactly as the file declares. For the bands a reader omits, **the file provides no
bound, and it is important not to claim one from the wrong field.** `sh_band<b>` is the
_quantization_ error between the stored and original coefficient — how far the byte moved the
coefficient — not the coefficient's magnitude. An 8-bit band has `sh_band<b> = 0` (lossless
quantization) while its stored coefficients may still be nonzero within `[-4, +4]` (spec §6.5), so
that zero cannot be reused as a bound on omitted coefficient state. This proposal declares no
aggregate omission metric for a band.

**Combined, retained state keeps its existing bounds.** At level `≤ N` and contiguous degree `b`,
every retained gaussian attribute and every retained SH coefficient has exactly the bound the base
format declares. The selection omits whole gaussian rows and top-band coefficient rows; it does not
modify retained values. The container declares no combined error bound comparing that selected state
with the full state. This is distinct from keyframe-delta §8 and object-layer §7, which transform
reconstructed state and retain a bound over their whole output.

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
  with §4.2 — its level. A client computes, for any target (a time window, a maximum level, a
  contiguous band prefix), the exact set of byte ranges it must fetch, _from the index alone, before
  fetching any gaussian data_. That is precisely a manifest's job.
- **In one round trip.** The index is at a known place: the 37-byte tail gives `summary_start` (spec
  §5.2), and one range read brings the whole index. A manifest would be a _second_ resource to fetch
  first, to describe a file that already describes itself.
- **Kept consistent by construction.** A manifest is a second representation of the index's facts,
  and a second representation is a second thing to keep consistent with the first — the exact
  argument keyframe-delta §4.5 made against a GOP-level index record, one level out. The index
  cannot disagree with itself; a manifest can disagree with the index.

The one thing a manifest offers that the index does not is _discovery before the index is fetched_ —
a client choosing a level without reading the file at all. Two things answer that. First, the
range-readable Header declaration of §4.4 gives the level-number bound, while the index gives the
sparse set of actual levels and their exact transfer footprints. For a chosen contiguous SH prefix,
a footprint is the selected entries' `chunk_length` values plus the lengths of every selected SH
range; base-chunk bytes alone are not the transfer cost. Per-level perceptual quality is
deliberately not claimed (§3.2). Second, and more to the point, adaptive selection is a **client
policy fed by the index**, not a container feature, in exactly the division the format draws
everywhere: the format carries the facts that must survive interchange, the client makes the choice
(spec §7.3 on spatialization, keyframe-delta §2 on rate control). A manifest would not add a fact;
it would relocate the client's policy into a sidecar and break "one resource" to do it.

So: **no manifest. The byte-range index is the manifest, and adding a second one would trade a
design goal for nothing the index does not already give.** §12's ruling 3 records this, with the one
condition under which it would be reopened — a hard requirement for discovery before the index is
fetched at all.

---

## 9. Failure modes a conforming implementation refuses

Collected so a decoder or full-file validator can check itself against a list. Each names the
offending value. The list is short because subsetting has little to get wrong; most of it is
referential integrity between the index and the chunks, which the format already polices.

| condition                                                                                  | why it is not repairable                                                  |
| ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| Header `lod_levels` is not a canonical exclusive bound in `1..4294967296`                  | the gate is unreadable or outside the `u32 level` domain                  |
| Header `lod_level0_complete` is present but not exactly `"true"` or `"false"`              | SDKs would disagree on whether the completeness promise is active         |
| Header `lod_level0_complete` is present without a valid Header `lod_levels`                | the promise has no authorized level semantics or seek predicate           |
| a chunk or index `level` is `>= lod_levels` (or the two disagree)                          | the declared range omits the chunk; the full union would silently lose it |
| an indexed declared-LOD entry omits its appended `level`                                   | the seek predicate cannot be answered from the index                      |
| an index entry's `level` differs from its Chunk / Delta Chunk's                            | the seek predicate would select on a value the record denies              |
| a `keyframe-delta` delta references a chunk of a different `level`                         | spec §11 / keyframe-delta §3.6; a chain would cross levels                |
| a `keyframe-delta` `gaussian_id` is observed at more than one level                        | a wire-identifiable gaussian has migrated between ownership tranches      |
| duplicate live `gaussian_id` values across active `keyframe-delta` level states            | level union never creates a separate live-identity namespace              |
| a dead `keyframe-delta` `gaussian_id` is later reused in any level or separated run        | level and run boundaries never restart the scene-wide identity history    |
| same-level `keyframe-delta` chunks overlap                                                 | `current(t, ell)` would not be unique                                     |
| a same-level run starts with a delta or a chain crosses a gap                              | the covered interval has no independently decodable base state            |
| a band byte range in the index overruns the file                                           | the existing index-range rule (spec §5.8), unchanged                      |
| `gaussian-birth` promises complete level 0 but its level-0 interval union has a gap        | overlap is legal, but an uncovered instant contradicts the promise        |
| `keyframe-delta` promises complete level 0 but level 0 is not one full non-overlapping run | the promised standalone state is overlapping, gapped or incomplete        |

The range and index-presence rows are load-bearing. `lod_levels` is an exclusive bound (§4.4), so a
chunk whose `level` is at or above it sits outside the advertised range. A reader requesting the
greatest authorized value, `lod_levels - 1`, would omit that chunk and silently break the full-union
guarantee (§5); a reader MUST therefore refuse the file, naming the offending `level` and declared
bound. Likewise, an indexed LOD entry without its Header-gated `level` makes the predicate
unknowable without fetching the payload. Both checks are the referential integrity that §4.1's
Header gate needs before a reader may trust it.

The upper endpoint `4294967296` is valid because it permits the greatest stored `u32 level`,
`4294967295`; it is not a request to allocate that many slots. A reader parses the bound with
checked arithmetic and keeps actual levels in storage bounded by validated index entries (§4.4).

The three identity rows are `keyframe-delta` conformance faults with two validation scopes. Every
range seek reconstructs its complete active union, so the live-uniqueness check is local and
mandatory on that seek. Immutable ownership and no reuse are whole-history checks: a full-file
validator processes each id's complete ordered event history through the bounded partitioned-pass or
external-sort strategy of §3.5, while a partial reader applies the same checks only to history
present in the current seek's fetched chains, MUST NOT scan unrelated payloads solely to complete
them, and MUST NOT retain that history across seeks. Thus two individually valid active chains that
carry the same live `gaussian_id` are a live duplicate; an id seen in disjoint level runs without a
death is a migration; and an id that dies then births again is reuse. If one malformed history
satisfies more than one predicate in the current selected chains, the more specific live-duplicate
or reuse identifier takes precedence over the migration identifier so conformance diagnostics remain
deterministic (§10.3). Per-seek identity scratch is discarded or logically cleared after the result;
only a bounded validator partition or one externally sorted id history survives a chunk boundary
during exhaustive validation.

`gaussian-birth` has no `gaussian_id` attribute (registry §“Attribute ids”), so a file reader has no
structural observation that can prove one logical source gaussian was restated in two tranches.
§3.1's one-level ownership remains an encoder/source-state conformance requirement for that model,
not a reader refusal and not an entry in the invalid-file corpus.

Everything **not** on this list is valid and often intentional, and the layer is at pains not to
refuse a usable file:

- **A level that covers only part of the timeline** is valid — a higher level adds detail only where
  there is detail to add (§3.5). Under `keyframe-delta`, each separated covered run starts with its
  own keyframe and its chains stay inside that run; the gaps themselves are valid. Only level 0 is
  expected to cover the whole timeline, and only when Header `lod_level0_complete` promises it;
  without that key even level 0 need not be standalone.
- **Gaps between level numbers** — levels `0` and `2` present, `1` absent — are valid. "Union of
  `≤ N`" does not require the levels to be dense; a reader fetching level `≤ 1` simply gets level 0,
  and a reader fetching level `≤ 2` gets levels 0 and 2. A producer SHOULD keep them dense for a
  clean ladder, but a gap is not a refusal.
- **An exclusive bound above every level actually present** is valid. A file with levels `0` and `2`
  may declare `lod_levels = "8"`; requests for absent levels add nothing, and the request at `7`
  still includes the full union. A recovered truncated stream may observe only a prefix of the
  levels the Header permits. Neither case is a missing-data error inferred from the bound.
- **A file that does not declare LOD** (Header `lod_levels` absent) carries no obligation from this
  layer at all, whatever its `level` values are (§4.1); a reader simply does not filter on `level`.
  Its Chunk Index has no LOD `level` append; Metadata-only `lod_levels` and `lod_level0_complete`
  keys are legal but inert and do not change that. The one recognized malformed exception is an
  orphaned Header `lod_level0_complete`, which §4.4 and the table above refuse because it names
  completeness semantics for a level the Header has not authorized. Unknown trailing index bytes
  belong to append-only extensions and MUST NOT be guessed to be `level` (§4.2).
- **Deliberate per-chunk SH transfer caps** are valid when they are read-plan inputs (§3.3).
  Accidental EOF is not such a cap: it invokes the existing longest-intact-chunk recovery and does
  not make an otherwise incomplete trailing chunk valid.

A validator MAY note the unusual combinations. A full-file validator refuses every structural fault
above; a partial reader refuses the faults its selected index entries and fetched payloads expose,
without expanding the seek merely to search for faults elsewhere.

---

## 10. Conformance plan

Nothing here is real until the suite proves it. This is what would be added to the corpus generator
and the canonical summary.

### 10.1 Canonical JSON

A variant whose `Header.attributes` declares LOD gains a per-level view of the scene, and the
existing per-instant states gain a requested-level parameter, so that the summary can assert "level
≤ N at time t is exactly this set of gaussians". Where the variant also carries spherical harmonics,
each state additionally records a per-chunk selected SH prefix and digest, so differing per-read
transfer caps over one uniformly stored scene (§3.3) are asserted rather than assumed.

```json
{
  "lod": {
    "exclusiveUpperBound": "3",
    "byLevel": [
      {
        "level": "0",
        "chunkCount": "4",
        "gaussianCount": "1024",
        "byteFootprints": [
          { "throughShDegree": 0, "byteSize": "48210" },
          { "throughShDegree": 3, "byteSize": "91106" }
        ]
      },
      {
        "level": "1",
        "chunkCount": "8",
        "gaussianCount": "4096",
        "byteFootprints": [
          { "throughShDegree": 0, "byteSize": "191044" },
          { "throughShDegree": 3, "byteSize": "362628" }
        ]
      }
    ]
  },
  "states": [
    {
      "t": 0.5,
      "atLevel": "0",
      "liveCount": "1024",
      "sample": { "positions": [], "levels": [], "gaussianIds": [] },
      "aggregate": { "positionSum": [], "opacitySum": 0.0 },
      "byChunk": [{ "chunkOffset": "512", "throughShDegree": 3, "shCrc": "…" }]
    }
  ]
}
```

- `lod.exclusiveUpperBound` is the canonical Header value, not the number of `byLevel` rows and not
  a claim that its predecessor is present. `lod.byLevel` exists so that a field no expectation
  mentions is a field an implementation can decline to decode — the reason `chunks` is in
  keyframe-delta's summary. The array contains only levels actually present and is never padded to
  the bound. Each `byteFootprints` row defines its selected contiguous band prefix, and `byteSize`
  is the sum of `chunk_length` plus all indexed SH ranges through `throughShDegree` for that level.
  This catches implementations that count only base chunk bytes or allocate a dense array from
  `lod_levels`.
- **`gaussianCount` follows the Header's `gaussian_count` semantics, scoped to one level over the
  whole file.** Under `gaussian-birth`, it is the number of stored gaussians whose owning chunk has
  that level — equivalently, the Header count for the file filtered to that tranche. Under
  `keyframe-delta`, it is the number of distinct `gaussian_id` values whose immutable ownership
  level is that level, counted once across every keyframe restatement, update, birth and death. It
  is a lifetime population: an id that later dies still counts, while repeated records for one id do
  not. It is never a sum of keyframe or delta row counts and never the population at an instant;
  `states[].liveCount` is the latter. `LodKfDeltaChurnCount` makes the distinction observable.
- **`states` carries a requested level.** Each probe instant is summarized at one or more requested
  levels, and `sample.levels` is each sampled gaussian's level. This is the conformance teeth: a
  decoder that filters level wrongly — off-by-one on `≤`, or including a level's chunks when it
  should not — produces a different `liveCount` and a different gaussian set at that level and fails
  on that row. A requested level equal to `lod.exclusiveUpperBound - 1` MUST reproduce the
  full-scene state a non-LOD decode produces, even when that numeric level has no chunks. This makes
  both the §5 forward-compatibility claim and the exclusive-bound semantics checkable.
- **Ownership and identity are checked at the scope each temporal model exposes.** For
  `gaussian-birth`, which has no `gaussian_id`, a source-aware encoder conformance test compares the
  expected state and `liveCount` to prove each source gaussian appears in exactly its assigned level
  and once in the full union. A file reader cannot make that check and has no corresponding identity
  refusal. For `keyframe-delta`, `sample.gaussianIds` uses the existing canonical identity field;
  the full-file validation runner checks one bounded id partition or externally sorted id history at
  a time, including uniqueness across active levels and one lifecycle across every level and
  separated run. It refuses a cross-level migration, a live duplicate, or an id reborn after death
  even if the offending id falls outside the sample. Its adapter reports the configured identity
  memory budget and `identityRetainedBytesHighWater` with §3.5's accounting boundary; conformance
  fails if the latter exceeds the former. The exhaustive runner also validates
  `LodKfDeltaIdentityBudgetOverflow`, whose 4,096 sparse pseudorandom ids exceed a 4,096-byte test
  budget before a final cross-level occurrence of the last id. Passing therefore requires the
  partitioned-pass or external-sort path; neither a dense bitmap nor a scene-wide map fits under the
  configured capacity. The indexed decode runner checks the identity evidence its selected chains
  fully expose: live uniqueness across the fetched active union and no-reuse across the histories
  present in those chains. Its adapter reports `identityScratchEntriesLive` and
  `identityScratchEntriesHighWater` after every seek. The former MUST be zero on return, and the
  latter MUST be no greater than the number of identity rows in that seek's selected decoded chains.
  A disjoint-seek sequence increases cumulative visited ids far beyond any one seek and asserts that
  live entries remain zero and high-water remains bounded by the largest single seek; reusable
  capacity may remain, but no keyed identity history may. The request trace separately proves the
  runner never fetches unrelated payloads to complete a whole-file identity audit. Positive
  multi-level rows use level-stable, never-reused ids, and the invalid corpus contains both
  exhaustive cases and selected-chain cases (§10.3).
- **`states[].byChunk` carries a per-chunk transfer cap and SH digest.** `throughShDegree` is the
  highest contiguous band prefix selected for that chunk in this read, and `shCrc` digests only the
  coefficients through that prefix. The file still stores the same Header-declared degree for every
  chunk. A decoder that incorrectly replaces requested per-chunk caps with one global read cap
  produces the wrong `throughShDegree`/`shCrc` and fails on that chunk specifically.
- **The two read paths must agree**, as keyframe-delta §11.2 requires: a streamed decode that
  filters level as chunks pass and an indexed decode that seeks with the level predicate of §3.5
  MUST produce identical `states` at every requested level when given the same deliberate SH read
  plan. EOF recovery is a separate corpus expectation: an unplanned cut drops short trailing chunks
  instead of synthesizing transfer caps (§3.3).

### 10.2 Scenarios

New corpus variants. Most are crossable with both temporal models, since level is orthogonal to the
model (§3.5); `LodSparseLevels` and `LodKfDeltaPerLevelRuns` specifically exercise the sparse
level-run generalization and its compatibility boundary (§3.5, §4.6):

| scenario                  | shape                                                                                | what it catches                                                                          |
| ------------------------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| `LodSingleLevel`          | Header `lod_levels = 1`, every chunk level 0                                         | decoded states equal the non-LOD variant; wire bytes are expected to differ              |
| `LodTwoLevels`            | level 0 coarse, level 1 detail, both spanning the clip                               | the seek predicate; `states` at each requested level; the union rule                     |
| `LodBoundSlack`           | levels 0 and 2, `lod_levels = 8`; requests through 7                                 | exclusive-bound semantics; absent levels add nothing; request 7 is the full union        |
| `LodSparseLevels`         | level 0 spans the clip, level 1 has two keyframe-rooted runs with a gap              | sparse `keyframe-delta` run validity and partial timeline coverage (§3.5, §9)            |
| `LodLevelGap`             | levels 0 and `4294967295`, `lod_levels = 4294967296`, only two actual levels         | sparse/count-independent storage and the full `u32` level domain (§4.4, §9)              |
| `LodLevel0CompleteBirth`  | `gaussian-birth`; overlapping level-0 intervals whose union covers the clip          | complete means gap-free interval union; overlap remains valid (§3.5, §4.4)               |
| `LodLevel0CompleteKf`     | `keyframe-delta`; level 0 is one non-overlapping run covering the clip               | model-specific complete-run promise (§3.5, §4.4)                                         |
| `LodProgressiveBands`     | every chunk stores degree 3; deliberate reads probe contiguous prefixes 0..3         | the quality axis; the contiguous-prefix rule; SH-inclusive byte footprints (§3.3)        |
| `LodOutOfOrderBands`      | degree 3; one chunk completes base, band 2, band 1, then band 3                      | band 2 is held at degree 0 until band 1 closes the contiguous prefix                     |
| `LodMixedReadDegree`      | every chunk stores degree 3; one read deliberately caps two chunks at 3 and two at 0 | per-chunk transfer caps and digests; a decoder substituting one global read cap fails    |
| `LodStreamBandCut`        | degree-3 stream ends after band 1 of its final chunk                                 | longest-intact-chunk recovery; accidental EOF does not create a degree-1 cap             |
| `LodStreamLevelCut`       | `lod_levels = 8`; stream recovers intact level-0 records before a later level-2 cut  | observed levels may be below the bound; recovery neither invents nor requires levels     |
| `LodNoDeclare`            | chunk `level > 0`; Header gate and index `level` append both absent                  | semantic/physical iff gate: reader does not filter or infer a field, and gets full scene |
| `LodMetadataOnlyComplete` | Metadata `lod_level0_complete = "TRUE"`; Header completeness key absent              | noncanonical Metadata value is legal, inert and cannot affect level-0 completeness       |
| `LodIndexMissingLevel`    | declared indexed LOD; one Chunk Index entry omits the appended `level`               | mandatory range-seekable level predicate (§4.2)                                          |
| `LodKfDeltaPerLevelRuns`  | `keyframe-delta`, two levels; one full run and one sparse keyframe-rooted run        | run-local chains, unique active ids and one global no-reuse identity history (§3.5)      |
| `LodKfDeltaRangeSeek`     | seek a later sparse run from the index without fetching earlier valid runs           | selected chains only; whole-file identity validation never becomes a payload scan        |
| `LodKfDeltaChurnCount`    | one level repeats id 7, births id 8, updates both, then kills id 7                   | `gaussianCount = 2` for lifetime ids while per-instant `liveCount` changes               |
| `LodFullEqualsUnion`      | request `lod_levels - 1` vs a non-LOD full decode, including an over-declared bound  | decoded union equality and one-level ownership under both temporal models                |

Crossed with the existing flags `Quantized`, `SHDegree2`, `UseCrc`, `UseChunkIndex`, and one variant
with no index (a streamed reader filtering level without one). `LodProgressiveBands` and
`LodMixedReadDegree` are additionally crossed with the per-band bit-depth ladders, since the quality
axis and the bit-depth dial share the band records. `LodOutOfOrderBands` drives the incremental band
adapter in completion order `[base, 2, 1, 3]` for one chunk. Immediately after band 2 completes, the
expectation remains `throughShDegree = 0` with the base-only digest; after band 1 completes it jumps
to degree 2 with the degree-2 digest, and only the final band advances it to degree 3. A reader that
consumes a non-contiguous band early therefore fails before the gap is repaired.
`LodMetadataOnlyComplete` MUST produce the same completeness state as an otherwise identical file
with no completeness key: no Header promise is visible, no value grammar is applied to the Metadata
entry, and no level-0 coverage guarantee is inferred. `LodKfDeltaPerLevelRuns` additionally carries
a runner-side assertion that a **pre-LOD** `keyframe-delta` decoder _refuses_ it on the overlap or
gap rule (spec §11.1) — the §4.6 compatibility boundary made checkable, so the
non-forward-compatible case is proven to refuse cleanly rather than mis-decode. `LodStreamBandCut`
runs only through the streamed recovery path and compares its state to the longest full-degree
intact chunk prefix. `LodStreamLevelCut` likewise runs through streamed recovery and retains the
Header's declared bound while summarizing only levels found in the intact record prefix.
`LodKfDeltaRangeSeek` records every range request and fails if the decoder fetches a state chunk
outside the index-selected chains; the same valid fixture is separately accepted by the exhaustive
identity validator. The invalid selected-chain fixtures in §10.3 use the same request trace to prove
that local identity validation does not expand the seek; the scratch counters defined above
separately prove that it retains no keyed identity history between seeks.

### 10.3 Files full-file conformance must refuse

§9's structural faults, as a small corpus of deliberately invalid files, each paired with the
identifier of the refusal it must produce — `lod-levels-malformed`, `level-exceeds-declared`,
`lod-level0-complete-malformed`, `lod-level0-without-gate`, `level-index-missing`,
`level-index-mismatch`, `delta-crosses-level`, `level-overlap`, `level-run-without-keyframe`,
`level-chain-crosses-gap`, `id-crosses-level`, `duplicate-id-across-levels`,
`id-reuse-across-levels-after-death`, `lod-level0-birth-has-holes`, `lod-level0-kf-invalid-run`.
These files run through the exhaustive validation entry point; a single-instant indexed decode is
not required to fetch unselected payloads merely to discover a whole-history fault. The
malformed-completeness file carries `Header.attributes["lod_level0_complete"] = "TRUE"` alongside a
valid LOD gate and MUST produce `lod-level0-complete-malformed`; this prevents truthiness or
case-folding from changing the promise. The orphan-promise file carries Header
`lod_level0_complete = "true"` without Header `lod_levels` and proves that the promise cannot
authorize its own seek. The migration file gives id 7 a state-bearing occurrence in a level-0 run
and a later non-overlapping level-1 run without a death; it MUST produce `id-crosses-level`. The
duplicate-id file gives two active levels individually valid chains that both contain
`gaussian_id = 7`; it MUST produce the more specific duplicate identifier only after the
reconstructed union exposes the collision, naming both levels and chunks. The reuse file gives id 7
a valid lifecycle that ends in death, then births id 7 again in a later run; it MUST produce the
more specific reuse identifier and name the earlier lifecycle, death and later birth even though no
reconstructed instant has two live id-7 gaussians. The two level-0 files prove the
temporal-model-specific coverage definitions. There is no `gaussian-birth` identity-refusal file,
because that model exposes no wire identity with which a reader could diagnose cloned source
ownership (§3.1, §9). This reuses the refusal-expectation harness contract keyframe-delta §11.5
introduces; if that contract has landed by the time this does, this adds rows to it rather than a
mechanism.

`LodKfDeltaIdentityBudgetOverflow` is a generated exhaustive-validation refusal case. The runner
configures the validator with a 4,096-byte identity-memory budget. A level-0 keyframe contains the
4,096 distinct sparse ids

```
id_i = (i << 20) | low20(SHA-256("4dgs-lod-identity-budget" || u32le(i)))
```

for `0 ≤ i < 4096`. The top 12 bits put one id in each of 4,096 buckets across the full `u32`
domain; the pseudorandom 20-bit suffix prevents a range or run representation from standing in for
the exact set. After those histories have been observed, a later non-overlapping level-1 keyframe
contains `id_4095` without an intervening death. The validator MUST produce `id-crosses-level`, and
its reported `identityRetainedBytesHighWater` MUST remain at or below 4,096 bytes. The current
level-0 keyframe's validated decode buffer may exceed that budget while the chunk is being consumed,
but before the validator advances to the later keyframe it MUST release that buffer or count every
retained identity-bearing byte under §3.5's budget. A dense bitmap over the spanned `u32` domain is
roughly 512 MiB; the four-byte ids alone occupy 16,384 bytes; and even storing only the 20-bit
suffix from each implied bucket requires 10,240 bytes. Thus no exact scene-wide identity set fits
the budget. Implementations may make budget-sized numeric-id passes or use their memory-capped
external sort; the expected refusal, allocation trace and budget assertion are the same.

Two additional invalid cases run through the **indexed seek** entry point with an instrumented byte
source:

- `LodKfDeltaSeekDuplicateId` selects two active level chains that both contain `gaussian_id = 7`.
  The decoder MUST produce `duplicate-id-across-levels` before returning the union, even though
  unrelated earlier and later runs remain unread.
- `LodKfDeltaSeekReuse` selects a level-0 chain that explicitly kills id 7 and a level-1 chain that
  births id 7 before the requested state. The decoder MUST produce
  `id-reuse-across-levels-after-death` from those two selected histories without reading any chunk
  outside either chain.

For both cases the request log is part of the expectation: only the Header, Footer, summary,
selected Chunk / Delta Chunk records and their selected SH ranges may be fetched. A decoder that
skips fetched-chain identity checks fails on the missing refusal; a decoder that obtains the refusal
by scanning the whole file fails on the range trace. A separate sequence of disjoint valid seeks
drives cumulative visited identities above the largest single request, asserting
`identityScratchEntriesLive = 0` after each call and a per-request-bounded
`identityScratchEntriesHighWater`; cross-run migration that is not wholly present in one selected
seek remains an exhaustive-validation invariant.

### 10.4 Feature matrix rows

Added as `No` or `Planned` for every SDK, moved only by a passing suite:

- Level seek and gated index field — filter by `level ≤ N` and decode the append only when Header
  `lod_levels` declares it (§4.1, §4.2)
- Exclusive LOD bound — over-declaration and truncated-stream recovery keep observed levels sparse,
  while a `lod_levels - 1` request includes every observed level
- Contiguous band prefixes — the highest-contiguous-prefix rule with out-of-order bands held (§3.3)
- Per-chunk SH transfer caps — `byChunk` agrees while stored scene degree remains uniform
- Stream truncation — an incomplete trailing band set is dropped, never treated as an implicit cap
- Keyframe-delta range seek — indexed reads fetch only selected chains and validate identity
  evidence in those chains, including invalid duplicate/reuse cases, without scanning unrelated
  payloads; scratch-counter high-water is bounded by one seek and live scratch is zero on return
- Keyframe-delta full-file identity — every id has one immutable level, active unions have unique
  ids, and lifecycle history never restarts across levels or separated runs, checked through
  budgeted numeric partitions or bounded-memory external sorting; the over-budget migration fixture
  proves validation continues after the configured in-memory capacity is exceeded
- Full-union equivalence — a `lod_levels - 1` decode equals a non-LOD decode
- Encode: source partition and one-level ownership — each source gaussian is emitted in exactly one
  level tranche

---

## 11. What this proposal costs

Stated together so a reviewer can weigh them without assembling them from the sections above.

1. **One appended field**, `u32 level` on the Chunk Index (§4.2) — four bytes per index entry,
   mandatory on every entry of an indexed declared-LOD file and absent otherwise. It is the sole
   wire change.
2. **A declared meaning for a field that was informational** (§4.1), gated specifically by Header
   `lod_levels` so it is opt-in. It changes no existing file: a file whose Header does not declare
   LOD keeps `level` at its §5.5 meaning, and a reader never filters on it.
3. **A coordination constraint on the Chunk Index's appended-field order** (§4.2, §12.1), shared
   with keyframe-delta — the one genuinely fiddly part, because two extensions append to one frozen
   record.
4. **A small new invariant class in readers and full-file validators** — §9's structural refusals,
   most of them the index/record consistency check the format already performs on other duplicated
   fields. Whole-history identity validation uses budgeted numeric partitions or bounded-memory
   external sorting and never turns a direct range seek into a payload scan or a scene-sized map.
5. **An incremental-fetch capability the consumer may use or ignore** (§3.4). The format guarantees
   every deliberately selected refinement prefix decodes coherently; accidental EOF retains the
   existing longest-intact-chunk recovery (§3.3). A reader that ignores incremental fetches
   everything and is correct for the forward-compatible layouts (§5). How and when a consumer
   fetches is the consumer's, not the format's.
6. **One compatibility boundary:** a `keyframe-delta` file that relies on sparse level runs is
   refused by a pre-LOD reader on the existing overlap or gap rule (§3.5, §4.6). It is a clean,
   rule-based refusal rather than a version gate or a silent wrong scene. `gaussian-birth` at any
   number of levels, and a single-level `keyframe-delta` file that still tiles the full clip, keep
   the full no-gate forward compatibility.

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

| #   | question                                           | ruling                                                                                                                                                                                                                    | folded into         |
| --- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- |
| 1   | Chunk Index appended-field order vs keyframe-delta | keyframe-delta block first iff Header `temporal_model`; `level` next iff valid Header `lod_levels`; length only bounds/skips; **any third appender starts a presence-map suffix after both gated blocks**                 | §4.2                |
| 2   | Per-level quality metadata                         | Defer both key and record: no canonical omission metric or sparse string grammar is justified; transfer size remains index-derivable                                                                                      | §3.2, §12.2         |
| 3   | A network manifest                                 | Not added; the byte-range index suffices and a manifest breaks "one resource"                                                                                                                                             | §8                  |
| 4   | Additive levels vs replacement levels              | Additive; forward compatibility is incompatible with replacement                                                                                                                                                          | §3.1, §5            |
| 5   | Must every level cover the whole timeline          | No; only Header `lod_level0_complete` promises level 0: gap-free interval union for `gaussian-birth`, one full non-overlapping run for `keyframe-delta`                                                                   | §3.5, §4.4, §9      |
| 6   | How a reader knows `level` carries LOD importance  | Opt-in only via `Header.attributes["lod_levels"]`; without that exact entry, `level` keeps its §5.5 meaning and a reader never filters on it                                                                              | §4.1, §4.4          |
| 7   | Gate and index integrity                           | Header `lod_levels` is a canonical exclusive bound in `1..4294967296`; over-declaration is valid; every level is lower; indexed LOD entries carry `level`; readers store observed levels sparsely                         | §4.2, §4.4, §9      |
| 8   | LOD `keyframe-delta` vs the global tiling rule     | Header-gated LOD generalizes full tiling to sparse per-level runs; a pre-LOD reader cleanly refuses layouts with cross-level overlap or same-level gaps rather than silently mis-decoding                                 | §3.5, §4.6, §5      |
| 9   | Progressive SH vs scene-wide degree                | Every chunk stores the Header-declared complete band set; deliberate reads may select different contiguous caps, while accidental EOF drops short trailing chunks                                                         | §3.3, §3.4, §10     |
| 10  | What conformance compares and counts               | LOD/non-LOD variants compare decoded state, not container bytes; footprints include selected SH ranges; per-level gaussian counts use model-specific Header-count semantics over the whole file                           | §10                 |
| 11  | Identity across level unions                       | One-level ownership is source-aware encoder conformance for both models; bounded `keyframe-delta` full-file validation fixes every id to one level and forbids reuse, while direct seeks use measured per-request scratch | §3.1, §3.5, §9, §10 |

Rulings 3, 4 and 5 are the same judgement the existing specification makes everywhere — the format
takes on the smaller thing. Ruling 3 declines a second representation of facts the index already
carries, the keyframe-delta §4.5 argument reused. Ruling 4 declines the model that would have needed
a version gate, the object-layer §5-versus-keyframe-delta-§5 distinction reused. Ruling 5 declines
to force a coverage rule on levels that only add detail locally, so an honest sparse level is not
made a refusal. Ruling 6 is the correctness spine of the whole design — that the LOD reading of
`level` is opt-in, so an existing file whose `level` means something else is never mis-read — and it
is written up in §12.3. Rulings 7 and 8 are the review's later refinements of that spine: 7 makes
the gate range-visible, bounded and self-consistent so an indexed reader can trust it without a
count-sized allocation; 8 defines sparse level-run validity and the honest scope of forward
compatibility. Ruling 9 preserves the normative scene-wide SH degree while keeping the existing
per-band ranges useful for deliberate partial reads without weakening truncation recovery. Ruling 10
makes byte and state consequences testable, and ruling 11 separates source-aware ownership from
wire-checkable `keyframe-delta` identity while keeping whole-history checks in exhaustive validation
so direct seeks remain range-bounded. Rulings 1, 2, 6, 8, 9 and 11 carry the most implementation
weight and are written up in full below or inline in §3.3/§3.5/§4.6.

### 12.1 The Chunk Index appended-field order

This is the one genuinely load-bearing coordination in the design, and it matters because the
format's append-only extension model (spec §4.2) was built for a _single_ line of evolution, and
this is the first time two conditional extensions append to the same frozen record. keyframe-delta
appends six fields to the Chunk Index — `chunk_kind`, `delta_mode`, `reference_offset`,
`keyframe_offset`, `depth`, `live_count` (spec §5.8) — present only under
`temporal_model = "keyframe-delta"`; this layer appends one, `level`. Appended fields are positional
and record length does not identify their meanings, so each reader must know _which_ Header gates
place which blocks and _in what order_. `content_length` only bounds the record and lets an older
reader skip fields it does not know.

**Decided.** The layout of the appended region is fixed, in this order, and recorded in the registry
so it is decided once:

- **The keyframe-delta block comes first, and its presence is keyed to `temporal_model`.** It is
  present exactly when the model is `keyframe-delta`, which a reader has already read from the
  Header before it parses the index — so a reader knows, before it reaches the appended region,
  whether the six-field block is there.
- **`level` comes next, and its presence is keyed to a valid Header `lod_levels`.** It is physically
  and semantically present exactly when that gate is set. A reader evaluates `temporal_model` first,
  advances past the keyframe-delta block if required, then evaluates `lod_levels` and reads `level`
  if required. A short record is a missing-gated-field refusal. When the LOD gate is absent, bytes
  after the known blocks are not an optional `level`; they are an unknown append-only suffix and a
  current reader skips them to `content_length`.
- **Re-verified against the merged record at implementation time**, exactly as the object layer
  re-verifies its opcode assignments against `main` (object-layer §12.6), because the append region
  is spent by more than one design at once and the only safe layout is one checked at landing.

**And the escalation is normative, so the scheme cannot grow into ambiguity.** Both current blocks
are unambiguous because their Header gates locate them before record length is consulted. After
those gates have been evaluated, every reader agrees on the byte offset immediately following the
current layout. Raw optional blocks cannot accumulate there: length would reveal that some suffix
exists but not which blocks it contains.

> **Any third appender to the Chunk Index MUST begin a presence-map suffix at that deterministic
> post-gated offset.** The map's bits declare which later blocks the suffix contains.

A future reader first walks the two existing Header-gated blocks, then reads the map from the next
byte when a suffix remains. A current reader assigns no meaning to the suffix and skips all of it by
`content_length`, preserving the frozen-record append-only rule. The map is not built now, and the
reason is the object-layer §12 principle that a mechanism built before the file that needs it is a
mechanism nobody has tested: the two present blocks need no map because their Header gates already
locate them. It is the pinned next step — documented here, built at appender three — so the
positional scheme cannot be extended silently past the point where it stays safe.

### 12.2 Per-level quality metadata is deferred

§3.2 established that a level's deviation from the full scene is real but content-and-encoder
dependent. That fact is not enough to define an interoperable scalar. A metadata string would still
need all of the following: a metric (for example, but not silently assumed, PSNR), a reference state
and sampling procedure, units and direction, treatment of time and view direction, and a canonical
sparse grammar mapping actual level numbers to values. Without those, two producers can emit
different meanings under the same key and two SDKs can both claim conformance while disagreeing.
Calling the value advisory does not solve the vocabulary failure.

**Decided: reserve neither a metadata key nor a dedicated record now.** Per-level transfer size
needs neither: at any chosen contiguous SH prefix it is derived from the index by summing
`chunk_length` and every selected band's indexed length over the level's entries (§4.4). Per-level
quality waits until a concrete consumer and metric can define the missing semantics and a
conformance expectation together. A richer descriptor record may eventually be the right shape for
multiple metrics or independently range-readable descriptors, but no `Level Table` opcode is
reserved before that shape exists. This follows the repository's rule against speculative
mechanisms: defer the name with the mechanism rather than publish an interoperable-looking key with
no shared meaning.

### 12.3 The LOD reading of `level` is opt-in, and why it must be

This is the ruling the design's correctness rests on, and it was sharpened in review. An earlier
draft claimed the cumulative-subset meaning could simply be assigned to `level`, on the belief that
every existing file carried only level 0. That belief is false: spec §5.5 defines `level` as
"informational only", and the reference writers already put the depth of a chunk in the temporal
partition tree into it, so files in the wild carry `level > 0` that has nothing to do with
importance. Assigning the importance meaning unconditionally would do two unacceptable things — it
would violate spec §4.4's freeze on an existing field's meaning, and it would let a new LOD-aware
reader filter such a file to `level ≤ 0` and return an arbitrary incomplete scene, mistaking
partition depth for detail.

**Decided: the LOD meaning is opt-in, gated only by `Header.attributes["lod_levels"]`, and a reader
MUST NOT filter on `level` unless that exact Header entry is present and valid.** A same-named key
in a Metadata record does not declare LOD. A file whose Header declares LOD uses `level` as the
cumulative subset key and carries the matching index field; a file whose Header does not keeps chunk
`level` at its §5.5 informational meaning, carries no LOD index field, and a reader loads all its
chunks. Unknown trailing index bytes are skipped as future append-only data, not guessed to be
`level` (§4.2). So no existing file changes meaning, §4.4's freeze holds, and the failure mode — a
temporal-depth `level` read as importance — cannot occur, because the importance reading exists only
where a producer opted in at range-readable front matter.

Two alternatives were weighed and rejected. **A new attribute** (a separate `lod_level` field
distinct from `level`) would have avoided the overload cleanly, but it spends a field and forgoes
the whole economy of the design, which is that the format _already carries_ a per-chunk hierarchy
number; the opt-in key recovers the same safety at the cost of one metadata key rather than a new
wire field. **A version gate** (a magic-byte bump, or a Header flag that refuses old readers) was
rejected for keyframe-delta §5's reason turned around: the layer is additive, an old reader reading
a new file loads everything and is correct, so a gate would refuse readers that need no refusing.
The opt-in key is neither — it is a declaration, in the shape of `visibility_profile` and
`object_track_role`, that selects an interpretation without changing the bytes or gating a reader.
That it gates a _seek_ rather than only a label is why it is normative here where those are
advisory.

---

## 13. Deliberately deferred

Named so the boundary is a decision rather than an omission, in the shape spec §10.1 uses.

- **Spatial subdivision within a temporal chunk.** The within-chunk detail axis, reserved by spec
  §10.1 and left there by §6. This layer is the between-chunk axis and composes with the reserved
  one when it lands.
- **Per-gaussian stored SH degree.** Reserved by spec §10.1. The quality axis here selects whole
  contiguous band ranges during a read while storage remains scene-wide; spending an encoded degree
  per gaussian is a larger change with its own evidence.
- **A presence map for the future Chunk Index suffix** (§12.1). Not built, because both current
  blocks are located by Header gates. It is normatively required at the deterministic offset after
  those blocks when the _third_ appender arrives, so the direction is pinned rather than merely
  noted.
- **Per-level quality metadata or descriptors** (§12.2). Neither a key nor a record is reserved
  until a concrete metric, sparse grammar and conformance expectation can be designed together.
- **A network manifest and client-side adaptive selection policy** (§8). The format carries the
  facts a selection policy needs; the policy itself is the client's, and a manifest is declined
  outright.
