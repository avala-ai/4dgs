# Proposal: the `keyframe-delta` temporal model

**Status: accepted design. Not yet normative, not yet implemented, and not to be emitted by any
writer.** Nothing in this document changes what a conforming file looks like today. It is the
approved design, written at wire precision, and it becomes a revision of
[the specification](../index.md) and a set of entries in [the registry](../registry.md) as the
implementation lands. Until it does, the specification is the format and this is a plan.

Every question this design left open has been decided; the decisions are recorded in §13 and folded
into the sections they affect, so no section contradicts a ruling. Implementation is sequenced: the
refusal-corpus harness change lands first and on its own (§11.5), then the model.

---

## 1. What is missing

The format defines one temporal model. `gaussian-birth` gives every gaussian its own birth time,
temporal width, linear velocity and validity window, and reconstructs any instant in closed form
(spec §3). It is a good fit for content fitted as a cloud of independently-lived gaussians, and it
has a property no other model here will match: an instant costs only the chunks whose interval
contains it, and nothing depends on anything else.

It is a poor fit for content produced as a **sequence of states with correspondence between them** —
a population of gaussians that persists, moves, and changes appearance step by step, with gaussians
entering and leaving. Importing such content into `gaussian-birth` is always possible and always
correct (spec §11): one validity window per step, zero velocity. It is also lossy in the one way
that matters commercially — it discards the correspondence, so every step restates every gaussian,
and the file is a stack of independent frames.

The registry reserves the name `keyframe-delta` for the model that keeps the correspondence. This
proposal designs it.

The gap is worth stating precisely, because it is not "the format cannot represent this content". It
can; §11 says how. The gap is that the representation throws away the structure that makes the
content compact, and there is no way to declare it.

---

## 2. Scope

**Designed here:** the temporal model, its wire mapping onto existing records, one new record, the
reconstruction rule, the seek predicate, how the declared error bounds extend to composed state, and
the conformance corpus the model needs.

**Not designed here**, deliberately:

- **Compression codecs for delta payloads.** Deltas ride the existing Attribute Stream record and
  therefore the existing codec registry. Whether a delta-shaped payload wants a codec of its own is
  a separate question with its own rate-distortion evidence, and answering it here would couple two
  changes that should be reviewable apart.
- **`deformation-field`.** A different reserved model, out of scope by spec §10.1.
- **Rate control.** How an encoder chooses keyframe cadence, which gaussians to update at a given
  step, and what residual justifies a byte is encoder policy. The format's job is to represent the
  choice and to state its cost; it is not to make it. This follows the existing division in
  AGENTS.md §4 — the reference encoder is a reference, and rate and quality heuristics are where
  encoders differentiate.
- **Spherical harmonic deltas.** Ruled out for this revision; see §8 and §13.3.
- **Spatial subdivision within a temporal chunk.** Reserved by spec §10.1; §7 notes where this
  design would have to be revisited if it lands.

---

## 3. The model

### 3.1 State chunks

Under `keyframe-delta` the timeline is covered by **state chunks**, each valid over its own
half-open interval `[t0, t1)`. There are two kinds:

- A **keyframe chunk** carries the complete state of every gaussian live over its interval. It is an
  ordinary `Chunk` record (`0x05`), unchanged in every field.
- A **delta chunk** carries the changes between a named **reference chunk** and itself: updates to
  gaussians that persist, births of gaussians that appear, deaths of gaussians that leave. It is a
  new record, `Delta Chunk` (`0x10`).

A **group of pictures**, or GOP, is a keyframe chunk and the run of delta chunks that reach it. The
term is borrowed from video coding, where it means the same thing.

**The state chunks tile the timeline.** Sorted by `t0`, each chunk's `t1` equals the next chunk's
`t0`; the first `t0` is `0`; the last `t1` is the Header's `duration_sec`. A reader MUST refuse a
file whose state chunks overlap or leave a gap, naming the two intervals. This is what makes the
seek predicate in §7 a lookup rather than a search, and it is a real constraint: under
`gaussian-birth` chunks may overlap freely, and here they may not.

### 3.2 Identity

A delta names the gaussians it applies to, so gaussians need identity, and `gaussian-birth` has
none. Spec §6.1 is explicit that an encoder may reorder gaussians within a chunk freely and a reader
MUST NOT rely on their order, so position in a stream cannot be the identity.

This proposal adds one attribute: **`gaussian_id`**, a `u32`, attribute id `13` from the reserved
range. Every chunk of a `keyframe-delta` file carries it, and it is the only thing that ties a delta
to the gaussian it changes.

- Within one reconstructed state, ids are **unique**. A reader that finds a duplicate MUST refuse
  the file, naming the id.
- An id MUST NOT be reused after the gaussian carrying it dies. Reuse is representable and its only
  effect is to make a decoder's bookkeeping wrong in a way that looks like content, so it is
  forbidden rather than discouraged.
- Ids need not be dense, ordered, or start at zero. An encoder that sorts a chunk for spatial
  locality (spec §6.1) still may; the id stream is delta-coded like any other and pays for the
  reordering, not for the ids.

`gaussian_id` is **not** attribute id 12, `source_index`. That one is a producer-side stable id, is
optional, and is described by the registry as something a reader may skip. Quietly promoting an
optional field into the identity the whole model rests on would change what an existing value means
in files that already carry it. The two coexist: `source_index` remains a producer's own handle,
`gaussian_id` is the format's.

### 3.3 Reconstruction — the §3-equivalent

For scene time `t`:

```
K, D1..Dd = the chain for t (see §7)
S         = compose(K, D1, ..., Dd)
```

where `compose` applies each delta in order to the state it references, and each delta is applied
as:

```
1. deaths   -- remove every id in the death set
2. updates  -- for each id in the update set, replace the attributes the delta carries
3. births   -- insert every id in the birth set, with the full state the delta carries
```

The order is normative because a chunk that both kills and creates would otherwise be ambiguous. An
id MUST NOT appear in more than one of the three groups of the same chunk; a reader MUST refuse a
file where one does.

`S` is a set of gaussians in exactly the state spec §3 describes — the same fields, the same types.
**Spec §3's arithmetic then applies verbatim, with no change of any kind:**

```
visible  =  win_lo <= t < win_hi  AND  marginal >= cutoff
marginal =  sigma_t == +inf ? 1 : exp(-0.5 * ((t - mu_t) / sigma_t)^2)
center   =  position + motion * (t - mu_t)
opacity  =  color.a * marginal
```

That is the design's central constraint and it is worth being explicit about why it was worth paying
for. A consumer of this format has a decode path that ends in §3's four lines. A temporal model that
needed a fifth line, or a different fourth one, would fork every renderer and every downstream tool
for the sake of a container feature. So this model changes **where the state comes from** and
nothing about what the state means.

The one thing it asks of a producer is that `mu_t` carry the time the state was stated at. A
keyframe chunk sets every gaussian's `mu_t` to its own `t0` — which is one constant stream (spec
§5.6, `mode = 2`) costing a handful of bytes for the whole chunk — and `center` then reads
`position + motion * (t - t0)`, which is the right extrapolation. A gaussian that no delta touches
keeps the `mu_t` of the chunk that last stated it and keeps extrapolating from there, exactly and at
no cost. **Untouched means no bytes**, which is the property the whole model exists to buy.

### 3.4 Chaining, and why the choice is not about error

A delta's reference may be the GOP's keyframe or the chunk immediately before it. The `delta_mode`
byte says which, **per chunk**:

| `delta_mode` | name                | reference                                  |
| ------------ | ------------------- | ------------------------------------------ |
| `0`          | keyframe-referenced | the keyframe at the head of the GOP        |
| `1`          | chained             | the state chunk immediately preceding this |

The usual reason to prefer keyframe-referencing is that chained deltas accumulate error. **Here they
do not, at any depth**, because a delta is a difference of quantization bins rather than a
quantization of a difference. §8 works the arithmetic through. Since the error argument is gone, the
choice is decided on cost alone:

- **Chained** deltas are smaller: each carries only what changed at that step. Their read is
  `depth + 1` records, and those records are **adjacent in the file**, so an HTTP reader coalesces
  them into one request by the rule the implementation notes already give.
- **Keyframe-referenced** deltas are always two records, but the two are **not** adjacent — the
  keyframe is at the head of the GOP — so they cost two requests, and the delta must restate every
  change since the keyframe, which grows towards a full restatement by the end of a long GOP.

So chained is the better default on both bytes and requests, and this proposal recommends it. The
mode is nonetheless per-chunk rather than per-file, for a reason worth keeping: an encoder that
knows a particular instant is a likely seek target — a chapter boundary, a shot cut, the start of a
loop — can place a keyframe-referenced delta there and make that one instant cost two records
regardless of how deep into the GOP it falls, without spending a whole keyframe on it. Mixing is
legal, and §7's chain walk handles both uniformly because it follows `reference_offset` rather than
assuming a shape.

### 3.5 What a delta may not change

Four attributes are **GOP-invariant per gaussian**: a delta MUST NOT carry them in its update group,
and a reader MUST refuse a file where one appears there.

| attribute        | why                                                                      |
| ---------------- | ------------------------------------------------------------------------ |
| `sigma_t`        | derives the per-gaussian grids for `motion` and `mu_t` (spec §6.3)       |
| `flags`          | bit 0 selects which branch of both of those derivations runs             |
| `window_index`   | feeds the velocity grid for a never-fading gaussian (spec §6.3)          |
| `rotation_index` | selects which quaternion component the three stored bins are (spec §6.4) |

The first three are the same rule seen three times: two attributes in this format have a grid pitch
that varies per gaussian and is derived from values the decoder has already read. A difference of
bins is only meaningful when both bins are on the same grid. Change `sigma_t` mid-GOP and the
velocity delta is a difference between a bin on one grid and a bin on another — a number with no
interpretation, which decodes silently into a wrong velocity rather than into an error. Forbidding
the change is what keeps §8's bound true.

`rotation_index` is a different failure with the same shape: the smallest-three coding omits the
largest-magnitude component (spec §6.4), so the three stored bins mean different components before
and after the largest component changes. A rotating object crosses that boundary constantly, so
forbidding rotation change is not an option. Instead:

**Rotation in a delta's update group is an absolute restatement, not a difference.** The update
carries `rotation_index` and the three `rotation` bins as written, and they replace the previous
ones outright. This costs a few bytes per touched gaussian and removes the whole class of problem;
it also means the rotation bound in §8 is the §6.4 bound with no composition term at all, which is
the strongest statement available for any attribute here.

A producer that must change `sigma_t`, `flags` or `window_index` emits a death and a birth, or a
keyframe. Both are representable; neither is silent.

### 3.6 A delta's reference shares its `level`

Both chunk records carry a `level` field, the producer's hierarchy level, which the specification
describes as informational only. **A delta chunk's reference MUST have the same `level`**, and a
reader MUST refuse a file where it does not, naming both levels.

**Decided (§13.7).** This is the one constraint this design puts on level-of-detail, and it is
deliberately the weakest one that keeps the question open. Whether a GOP may mix levels, whether
levels are separate GOPs with separate keyframes, and how a reader chooses between them are
undesigned here — they belong with the reserved spatial-subdivision work, which is where the
level-of-detail design track lives.

The rule exists because the alternative is not neutrality. A format that says nothing about levels
here would let a delta at one level reference a keyframe at another, and once such files exist the
meaning of that combination is decided by whatever the first decoder did with it. Requiring the
levels to match costs a producer nothing today — every file the model is designed for has one level
— and leaves every option available to the design that eventually needs them, because relaxing a
rule is an append and tightening one is not.

---

## 4. Wire mapping

The design principle throughout: **ride the existing machinery**. Chunks with time intervals, the
chunk index, attribute streams, quantization records and the summary all already do what this model
needs. One new opcode is spent; everything else is an appended field, a registry value, or an
attribute id from the reserved range.

### 4.1 Header (`0x01`) — no wire change

`temporal_model` carries `"keyframe-delta"`. No field is added, removed, or reinterpreted.

One existing field is read differently under this model, and it is called out rather than left to be
discovered: `gaussian_count` is documented as "total across all chunks", which under a model where
chunks restate the same gaussians would count each of them many times and mean nothing. Under
`keyframe-delta` it is **the number of distinct `gaussian_id` values in the file**. This is a
reading of a field for a model that did not exist when it was written, not a change to what it means
in any `gaussian-birth` file, of which there are many and none of which move. It is also the field's
only useful reading here.

**Decided (§13.1): accepted, and it goes in the normative text rather than being left to be
inferred.** A reading that has to be reconstructed from first principles by each implementer is a
reading that two implementers will reconstruct differently, which is how the `f32[6]` / `f64[6]`
divergence happened to a field whose type was stated.

### 4.2 Keyframe chunk — `Chunk` (`0x05`), unchanged

A keyframe chunk is an ordinary Chunk record. Every field means what §5.5 says. Its attribute
streams are the required set for version 1 plus `gaussian_id`. Its spherical harmonic bands ride in
SH Band Stream records following it, exactly as they do today, and the band-skipping path is
untouched.

Spec §5.5 says "Chunks are **independently decodable**: nothing in a chunk references another
chunk." That sentence stays true, word for word, and this is the single strongest argument for
spending an opcode rather than adding a flag: a delta chunk is exactly the record that does not have
that property, and it must therefore not be that record.

### 4.3 Delta Chunk — opcode `0x10`, new

```
f64     t0, t1              -- the interval this composed state is valid over
u32     level               -- producer's hierarchy level; informational only
u8      delta_mode          -- 0 keyframe-referenced, 1 chained
u64     reference_offset    -- byte offset of the record this delta applies to
u64     keyframe_offset     -- byte offset of the Chunk record at the head of this GOP
u16     depth               -- Delta Chunk records that must be composed, this one included
u32     update_count
u32     birth_count
u32     death_count
string  compression         -- codec applied to the block below, or ""
u64     uncompressed_size
bytes   records             -- decompresses to: bytes updates; bytes births; bytes deaths
```

`records` behaves precisely as §5.5's does: `compression` names a codec applied to the whole block,
`uncompressed_size` is what it decompresses to, and a reader MUST honour it or refuse the file
naming the codec. What it decompresses to is three `bytes`-framed sub-blocks, back to back, in that
order. Each sub-block holds concatenated Attribute Stream records (`0x06`) — the same record, the
same decode pipeline, the same byte-plane and zigzag stages, with nothing added.

- **`updates`** — streams whose `element_count` is `update_count`. `gaussian_id` (id 13) is required
  and names the touched gaussians. Every other stream present carries **bin differences** against
  the reference state, aligned element-for-element with the id stream. A stream that is absent means
  that attribute did not change for any gaussian in this chunk. `sigma_t`, `flags`, `window_index`
  MUST be absent (§3.5); `rotation_index` and `rotation`, when present, are absolute (§3.5).
- **`births`** — streams whose `element_count` is `birth_count`, carrying **absolute** values: the
  full required attribute set of a keyframe chunk, plus `gaussian_id`. A born gaussian's spherical
  harmonics ride in SH Band Stream records following this Delta Chunk record, as they do for a
  Chunk.
- **`deaths`** — exactly one stream: `gaussian_id`, `element_count` equal to `death_count`.

Three sub-blocks rather than a group byte on each stream is a deliberate choice. The alternative — a
new stream record prefixed with a group byte, mirroring the shape of SH Band Stream (`0x07`) — would
have worked and would have spent a second opcode to distinguish an update's `position` stream from a
birth's, which have the same attribute id. Framing the groups by length instead spends none, keeps
`0x06` literally unchanged, and gives a reader something the group byte would not: it can read the
death list, which is small and which a consumer often wants alone, by skipping two lengths.

**A reader MUST NOT dispatch on group by counting element counts.** The sub-block a stream is in is
what says which group it belongs to. This is the same lesson §5.7 records the hard way, applied
before rather than after: there, an SH band stream's `attribute_id` field carries a value that
collides with `mu_t`, and the specification has to say in bold that a reader must not route on it.
The group here is framing, not a field, and cannot collide with anything.

`update_count`, `birth_count` and `death_count` are in the record header so that a streamed reader
can size its working set before it decompresses, and so that a stream whose `element_count`
disagrees with its group's count is a refusal rather than an allocation. That is the constant-stream
lesson from the implementation notes, applied one level up: check the declared count against the
count its container declares **before** sizing anything from it.

### 4.4 Chunk Index (`0x08`) — appended fields

The Chunk Index is frozen, so nothing existing moves. Six fields are appended, after the variable
band array:

```
... existing fields, unchanged ...
u8   chunk_kind        -- 0 keyframe (a Chunk record), 1 delta (a Delta Chunk record)
u8   delta_mode        -- 0 when chunk_kind is 0
u64  reference_offset  -- 0 when chunk_kind is 0
u64  keyframe_offset   -- this entry's own chunk_offset when chunk_kind is 0
u16  depth             -- 0 when chunk_kind is 0
u64  live_count        -- gaussians live over [t0, t1), after composition
```

Appending after a variable-length array is legal and is what §4.2 describes: a reader that knows
only version 1's fields parses the band array and stops, using `content_length` rather than assuming
the record ended where its knowledge did. `chunk_offset` and `chunk_length` continue to frame a
whole record, opcode byte included, for a Delta Chunk exactly as for a Chunk (§5.8).

`live_count` is appended because the existing `gaussian_count` field cannot answer the question. For
a delta entry it is `update_count + birth_count + death_count` — the size of the delta, not the size
of the population — and a reader budgeting a decode needs the population. Both numbers are useful
and neither substitutes for the other, so the entry carries both.

Four of these fields duplicate what the Delta Chunk record already says. That is intentional and is
the price of the format's second design goal: a reader must answer "which keyframe, which deltas,
how many bytes" **from the index alone**, without fetching a chunk to find out what it references. A
reader MUST refuse a file where the index and the record disagree, naming the field — which makes
the duplication a cheap corruption check rather than only a cost.

### 4.5 The summary is untouched

No record class is added to the summary. §4.5's rule — the summary is exactly Chunk Index,
Statistics and Summary Offset, contiguous, immediately before the Footer — holds unchanged, and the
streamed CRC verification that rule exists to enable keeps working without any new case.

This was a design constraint rather than an outcome. The obvious alternative was a new index-class
record describing GOP structure. The implementation notes anticipate exactly that move and sanction
it for a bounded record, so it was available; it was not taken because everything a GOP-level record
would carry is derivable from per-chunk fields that have to exist anyway, and a second index is a
second thing to keep consistent with the first.

### 4.6 Registry: what this follows and what it amends

The registry's sketch of this model is four sentences, and the design starts from them. Two are
followed and two are amended, with reasons:

**Followed — "delta records typed per attribute."** Deltas are per-attribute streams, using the
existing Attribute Stream record with nothing added.

**Followed — "a rule for which gaussians a delta applies to."** §3.2 is that rule. The sketch does
not say what the rule should be; explicit ids are the only option compatible with §6.1's prohibition
on relying on order.

**Amended — "a base gaussian set."** Singular. One base set plus deltas for the whole clip makes
seek cost grow without bound in clip length, makes any truncation past the base unrecoverable in the
middle, and gives a live consumer no join point. Keyframes recur; cadence is the encoder's knob and
the index states the result.

**Amended — "a declared keyframe interval so a reader knows how far back it must go."** A declared
interval is a producer's promise, and a reader that navigates by it seeks to the wrong byte whenever
it is wrong — including when it is wrong because the encoder inserted a keyframe at a shot cut,
which is exactly what a good encoder does. The index carries the reference per chunk, so a reader
never needs the declaration and must never use it. The interval survives only as advisory metadata,
for a consumer choosing between files before downloading one. This is the same distinction §5.3
already draws for the `bounds` map: a producer's declaration, not an instruction.

**Amended — "its natural chunk boundary is the keyframe, which the existing index expresses
unchanged."** Both halves. The boundary is each state chunk, not each GOP: making a GOP one index
entry would mean seeking to any instant costs the whole GOP even when two records would have done,
which discards the model's main benefit. And the index does not express it unchanged — without the
appended fields of §4.4 a reader cannot answer which keyframe a delta needs without fetching the
delta, which is one round trip too many and defeats the point of an index.

Registry additions, none of which change the format version:

- `Temporal models`: `keyframe-delta` moves from reserved to implemented.
- `Attribute ids`: `13` becomes `gaussian_id`, `u32`, required in every chunk of a `keyframe-delta`
  file and absent from a `gaussian-birth` one.
- `Profiles`: a `keyframed` profile promising tiling state chunks, an index with more than one
  entry, statistics present, and a bounded maximum depth — so a consumer can reject an unsuitable
  file up front, which is what a profile is for.
- `Metadata keys`: `keyframe_interval_sec` and `gop_max_depth`, both advisory, both authoritative
  only in the index.

### 4.7 `frame-sequence` is subsumed, and the name is kept as a tombstone

A `keyframe-delta` file whose every chunk is a keyframe — cadence one, no delta chunks at all — is
structurally exactly what the reserved `frame-sequence` model describes: independent time steps with
no correspondence between them. That shape is legal here and is the `KeyframeOnly` corpus scenario.

**Decided (§13.5): one wire shape gets one implemented name.** `frame-sequence` is not separately
defined, now or later. The registry row stays, with its status changed from `reserved` to
`subsumed`, and says plainly that the shape it names is covered by `keyframe-delta` at cadence one
and that no separate definition will follow.

The reservation is kept rather than retired because retiring it frees the name, and a freed name is
one somebody spends on something else — at which point the format has a `frame-sequence` that is not
the frame sequence anyone meant. A tombstone that points at the covering model costs one table row
and answers the question permanently. This is the same reasoning that put `flat-top` in the
visibility-profile table: a name is reserved to stop a term being applied loosely, and that job does
not end when the underlying capability arrives by another route.

---

## 5. Versioning: this is version 1.1

**The magic's version byte does not change. Existing files do not move. No frozen field changes.**

Every mechanism used is one §10 already permits within version 1:

| what this adds                 | §10 rule that permits it                  |
| ------------------------------ | ----------------------------------------- |
| `Delta Chunk`, opcode `0x10`   | new opcodes MAY be added in `0x01`–`0x7F` |
| six fields on Chunk Index      | existing records MAY gain appended fields |
| `gaussian_id`, attribute id 13 | registry addition                         |
| `temporal_model` value         | registry addition                         |
| `keyframed` profile, two keys  | registry addition                         |

A version-1 file with `temporal_model: gaussian-birth` remains valid, byte for byte, and every
existing implementation keeps reading it with no change at all.

**The gate for an old reader is `temporal_model`.** The registry's standing rule is that a reader
which does not know a well-known value MUST fail cleanly with a message naming it, so a
version-1-only reader refuses a `keyframe-delta` file and says why: it names the model it does not
implement. That is the whole compatibility story and it is deliberately a refusal rather than a
degradation.

It is worth being precise about what the new opcode does and does not buy here, because it is easy
to mistake for a fallback. A reader that ignored `temporal_model` — non-conforming, but the failure
that actually happens — would skip the Delta Chunk records it does not recognize and decode the
keyframes only. That is a scene, and it is the wrong scene. **It is not a sanctioned fallback and a
reader MUST NOT rely on it.** What it is worth is that the wrong answer is a subset of the content
rather than arbitrary geometry, which is the difference between a bug someone notices and a bug
someone ships. Had a delta ridden the `Chunk` opcode with appended fields, that same reader would
have decoded bin differences as absolute positions, and the whole scene would have collapsed into a
knot at the origin with no error anywhere.

**The rejected alternative: Header `flags` bit 2.** Bits 2–7 are reserved and MUST be 0 in version
1, so defining bit 2 as "chunk data is delta-coded" would make an old reader refuse mechanically,
before it parses a string, and impossible to skip. It produces a worse diagnosis: the reader would
report a reserved flag bit set, which says the file is malformed, when in fact the file is
well-formed and the reader is old. AGENTS.md §6 asks that errors name the problem and distinguish
"unknown but legal" from "malformed", and `temporal_model` does exactly that.

**Decided (§13.2): the bit is not spent. A well-formed file must never be reported malformed.** The
mechanical gate is cheaper for the reader and more expensive for the person holding the file, and
the person is who the error message is for. Bits 2–7 stay reserved and a `keyframe-delta` writer
leaves them 0, so the only thing an old reader has to get right is the rule the registry has always
had.

---

## 6. Lessons this design inherits

The existing specification's discipline came from real failures. Each one has an analogue here, and
they are named rather than left to be rediscovered.

**Out-of-range window index (§5.4): refuse, do not clamp.** A delta that names an id which is not
live, a death for a gaussian that is already dead, a duplicate id in one state, a chain whose walked
length disagrees with `depth` — all of these are refusals that name the id or the value, never
repairs. Clamping an out-of-range window index substituted one gaussian's lifetime for another's;
inventing a gaussian for an unknown id would do the same thing with more steps.

**Non-finite quantization parameters (§5.3): a value that only arrives by corruption still needs a
rule.** §8's representability rule is the same shape — a composed bin outside the range its symbols
can hold is refused with the attribute and the id named, not wrapped.

**The head probe (`WithLargeAudio`): fixture scale is itself a thing to cover.** A delta chunk's
index entry must be answerable without reading the chunk, and the corpus must contain a GOP big
enough that a reader which quietly fetches the chunk to find its reference is measurably slower
rather than invisibly wrong. §12 asks for a variant whose GOP exceeds a reader's head probe.

**Repeated positions: synthetic uniformity hides bugs.** A corpus in which every delta touches a
different gaussian never exercises the case where the same gaussian is updated in every chunk of a
GOP, which is what real content looks like. §12 asks for both.

**The `aabb` that said `f32[6]` and was always written as `f64[6]`.** That was found by building an
implementation from the published documents and nothing else. Before any part of this is frozen, one
implementation should be written from this document alone, by someone who has not read the encoder.

---

## 7. Seeking

This is the point of the model, so the predicate is stated exactly, and it is answerable **from the
index alone**.

```
current(t) = the unique index entry with t0 <= t < t1            -- unique, by the tiling rule (§3.1)

chain(t)   = [current(t)]
             while chain[0].chunk_kind == delta:
                 prepend the entry whose chunk_offset == chain[0].reference_offset

reads(t)   = for every entry in chain(t): [chunk_offset, chunk_offset + chunk_length)
             plus, for the wanted bands, each band's own range
```

Four properties make that walk safe, and each is a rule a reader enforces:

1. `reference_offset` is strictly less than the entry's own `chunk_offset`. **References point
   backwards only**, so the walk terminates and cycles are unrepresentable.
2. `chain(t)` has exactly `current(t).depth + 1` entries. A reader that walks a different number
   MUST refuse, naming both. This is a cheap integrity check on a structure a reader is about to
   trust.
3. `chain(t)[0].chunk_kind` is keyframe, and every entry's `keyframe_offset` equals its
   `chunk_offset`. A chain that reaches the front of the file without finding a keyframe is a
   refusal.
4. The total byte cost of a seek is `sum(chunk_length)` over the chain, which the reader can compute
   **before it fetches anything**. A consumer that wants to budget a seek can; a consumer that wants
   to choose a nearby instant that is cheaper can do that too.

### Worst-case cost

Let `N` be the number of state chunks per GOP, `K` the bytes of a keyframe chunk and `D` the mean
bytes of a delta chunk.

| mode                | records read | bytes read, worst case   | HTTP requests, after coalescing  |
| ------------------- | ------------ | ------------------------ | -------------------------------- |
| chained             | `N`          | `K + (N - 1)·D`          | 1 — the chain is contiguous      |
| keyframe-referenced | `2`          | `K + D_max`, `D_max ≤ K` | 2 — the keyframe is not adjacent |

The worst case for a chained GOP is the last chunk in it, and it costs the whole GOP. The worst case
for keyframe-referencing is also the last chunk, where the delta has accumulated every change since
the keyframe and approaches `K`. So both are bounded by roughly `2K`, and the useful difference is
the request count and the average: chained averages `K + (N-1)/2·D`, which for content where most
gaussians hold still between steps is much closer to `K` than to `2K`.

### Against `gaussian-birth`

Spec §8 is candid that seek efficiency under `gaussian-birth` is a property of the content:
finite-window content partitions and seeks cheaply, while content where every gaussian lives for the
whole clip degenerates to one index entry and an instant costs the whole scene. That cliff is why
the `baked` profile exists — to warn a consumer before it fetches 100 MB.

**`keyframe-delta` has no such cliff, and that is its central claim.** A seek costs at most one GOP,
whatever the content does, because the partition is imposed by the encoder rather than discovered in
the gaussians. Content where every gaussian lives forever — precisely the content that collapses
`gaussian-birth`'s index — is the content this model handles best, since nothing ever dies and
almost nothing needs restating between keyframes.

The cost is stated with equal candour. **A keyframe restates gaussians that did not change.** For a
clip of length `T` and cadence `T_gop`, the file carries a floor of `T / T_gop` full restatements
whether or not the scene ever moves. A static scene stored under `gaussian-birth` is one chunk;
under `keyframe-delta` at a two-second cadence it is thirty. The knob is cadence, the trade is size
against seek, and this model gives a producer the knob where `gaussian-birth` gives it a property of
the fit. A producer who does not want the trade should keep using `gaussian-birth`, which stays the
better model for the content it was designed for.

One further cost, on the streaming side. A `gaussian-birth` streamed reader can decode a chunk,
report it, and discard it; its working set is one chunk. A `keyframe-delta` streamed reader must
hold the composed state and mutate it as deltas arrive, so its working set is one full population.
That is still bounded — by the scene, not by the file, and it is what any consumer that draws the
scene must hold anyway — but it is strictly more than before, and a validation scan that used to run
in a chunk's worth of memory now needs a population's worth.

**If spatial subdivision within a temporal chunk (§10.1) is ever added,** the tiling rule in §3.1
becomes "the chunks tile time × space" and `current(t)` becomes a set rather than a single entry.
The chain walk is unaffected; the uniqueness claim is the part that would need rewriting.

---

## 8. Error bounds

The declared-bounds contract (spec §5.3) says that for each attribute the file declares a maximum
deviation, that the grid pitch is exactly twice it, and that `|decoded - original| <= bound` holds
by construction. A delta model has to say what that bound applies to after composition, and there is
exactly one answer worth having:

> **The bound is on the reconstructed absolute state at every instant, at every depth. It is not on
> the delta.**

A bound on the delta would be worthless. Composed `d` deep it would permit `(d+1)·bound` of error on
the value a consumer actually uses, and since `d` varies per chunk, the number a file declares would
not describe the file. The design achieves the strong form, and the mechanism is one sentence:

> **A delta is a difference of bins, never a quantization of a difference.**

### The arithmetic

Let `s` be an attribute's grid pitch, `ε = s/2` its declared bound, and `q(x) = round(x / s)` the
bin an encoder stores for true value `x`. Spec §5.3 gives `|s·q(x) - x| ≤ ε`.

The keyframe stores `b₀ = q(x₀)`. Delta `j` stores the integer `Δⱼ = q(xⱼ) - q(x_{j-1})`, where
`x_{j-1}` is the true value at the referenced chunk's time. A decoder composes:

```
b_d = b₀ + Δ₁ + Δ₂ + ... + Δ_d
    = q(x₀) + (q(x₁) - q(x₀)) + (q(x₂) - q(x₁)) + ... + (q(x_d) - q(x_{d-1}))
    = q(x_d)                                    -- exactly; the sum telescopes over integers
```

so `|s·b_d - x_d| = |s·q(x_d) - x_d| ≤ ε`, **independent of `d`**. The reconstructed bin is not an
approximation of the bin the encoder would have written at that instant; it **is** that bin.

This works because every stage after decompression is integer arithmetic, which spec §5.6 already
requires and already relies on for exactly this reason: "decoders in different languages produce
bit-identical integers and error cannot accumulate." The delta model does not need a new property.
It needs the existing one to be true one level further out, and it is.

For contrast, the design this rules out: `Δⱼ = q(xⱼ - x_{j-1})`, a quantization of a difference.
Composition then yields `Σ q(xⱼ - x_{j-1})`, whose deviation from `x_d` is bounded by `(d+1)·ε` and
by nothing tighter. Every keyframe would have to be close enough to bound the drift, cadence would
become an error parameter rather than a seek parameter, and the `bounds` map would be describing a
quantity no consumer cares about.

### Per attribute

- **Position, colour, opacity, motion, `mu_t`, `time`** — bins compose by the telescoping above;
  bounds are the declared ones, unchanged, at any depth. The colour transform `(g, r-g, b-g)` is
  exact in the integer domain (§6.2) and therefore commutes with the difference; a delta may be
  taken before or after it and the composed bins are the same.
- **Scale and `sigma_t`** — bins are in the log domain, so a bin difference is a **ratio** in the
  value domain. The telescoping argument is identical because it is an argument about integers, and
  the declared relative bounds `scale_rel` and `sigma_rel` hold unchanged at any depth. (`sigma_t`
  is GOP-invariant under §3.5, so in practice it never composes; the property is stated because
  scale does.)
- **Rotation** — never composed at all. §3.5 makes rotation an absolute restatement, so the bound is
  §6.4's post-reconstruction bound applied once, exactly as in a `gaussian-birth` file. This is the
  only attribute for which the delta model changes nothing whatsoever.
- **Spherical harmonics** — not delta-coded. A band's coefficients are `u8` stored as written and
  consumed as read (§6.5), which gives a difference no defined domain to live in. A gaussian's
  coefficients are therefore fixed for its lifetime within a GOP; changing them needs a keyframe, or
  a death and a birth. **Decided (§13.3): accepted as a limitation, to be revisited only against
  content that demonstrates the need.** Inventing a signed band form on the strength of an argument
  rather than a file is how a format acquires a record nobody writes; this is precisely what a later
  minor revision is for, and the door stays open because adding a stream form is an append.

### Representability

The one new failure mode is a composed bin that does not fit.

Bins travel as `u8`, `u16` or `u32` symbols, zigzagged (§5.6), and a delta stream will usually use a
narrower symbol than its keyframe does — which is a large part of where the size win comes from. The
composed bin, however, lives in the decoder's accumulator, not in a stream.

**Composed bins are `i32`.** A writer MUST NOT emit a chain any of whose composed bins falls outside
the range of a signed 32-bit integer, and a reader that detects one MUST refuse the file, naming the
attribute, the `gaussian_id` and the chunk. Not wrap, not saturate: a wrapped position bin is a
gaussian at a plausible-looking wrong place, which is the failure this format's `bounds` contract
exists to make impossible. The rule is the same shape as §5.3's finiteness rule — it constrains what
a writer may emit, it adds no arithmetic to §6, and a validator is where it is enforced.

`i32` is not tight for any real content: at a millimetre grid it spans about 2,000 km. It is stated
so that two decoders in two languages agree on where the boundary is, rather than one of them
discovering it on a 64-bit accumulator and the other on a 32-bit one.

---

## 9. Failure modes a reader refuses

Collected in one place, because a reader implementing this model should be able to check itself
against a list. Every one of these names the offending value in its message.

| condition                                               | why it is not repairable                                 |
| ------------------------------------------------------- | -------------------------------------------------------- |
| state chunks overlap or leave a gap                     | `current(t)` would not be unique                         |
| `reference_offset` ≥ the entry's own `chunk_offset`     | a forward or self reference; the walk would not end      |
| `reference_offset` names no entry in the index          | the chain is broken                                      |
| walked chain length ≠ `depth + 1`                       | index and file disagree about the read cost              |
| chain reaches the file's start without a keyframe       | no absolute state to compose onto                        |
| index and Delta Chunk disagree on any duplicated field  | one of them is corrupt and there is no way to know which |
| an update or death names an id that is not live         | there is no gaussian to change                           |
| a birth names an id that is already live                | ids are unique within a state                            |
| an id appears in two groups of one chunk                | the outcome would depend on application order            |
| a duplicate id within one state                         | every later delta naming it is ambiguous                 |
| `sigma_t`, `flags` or `window_index` in an update group | the per-gaussian grids would differ across the delta     |
| a stream's `element_count` ≠ its group's declared count | the alignment between ids and values is unknown          |
| a composed bin outside `i32`                            | wrapping produces a plausible wrong value                |
| a delta's `level` differs from its reference's          | the combination has no defined meaning (§3.6)            |

---

## 10. Truncation and recovery

The implementation notes' rule is unchanged: a streamed reader recovers every complete record before
the cut and MUST NOT interpret a partial one. What this model adds is that the recovered prefix is
**guaranteed self-consistent**, and the guarantee comes from one rule doing double duty.

Because references point strictly backwards (§7), every chunk's reference is a record that arrived
earlier in the file. So any complete prefix of records is a complete set of chains: a delta chunk
that survived the cut has, necessarily, everything it needs. A cut mid-GOP loses the tail of that
GOP and nothing else, and the last decodable instant is the `t1` of the last complete chunk.

The trailing-band rule from the notes applies unchanged to both kinds of chunk: a cut between a
chunk and its spherical harmonic bands leaves a chunk with fewer bands than the file, which is
recoverable by dropping the trailing chunks whose band sets are short rather than by refusing the
file or by zero-filling.

Had references been allowed to point forwards — which nothing in the wire form would have prevented,
since offsets are just offsets — a truncated file would have had chunks referencing records that
never arrived, and "keep the longest intact prefix" would have stopped being a valid recovery. The
rule is cheap and it is load-bearing in two places.

---

## 11. Conformance plan

Nothing in this proposal is real until the suite proves it, and the feature matrix records only what
the suite proves. This section is what would be added to `tests/conformance/generator/scenarios.py`
and to the canonical summary.

### 11.1 The corpus cannot summarize this model as it stands

The canonical JSON summarizes a **file**: its gaussians, their aggregate, a digest of their
harmonics. Under `gaussian-birth` that is well defined, because a file's gaussians are a set. Under
`keyframe-delta` a file has a different set at every instant, and "the file's gaussians" names
nothing.

This is the same gap the feature matrix already admits in its own words — that reconstruction at an
instant is the one thing the canonical JSON does not carry, so two implementations could disagree
about §3's arithmetic and both pass. `keyframe-delta` forces it closed, which is a benefit of this
work independent of the model: the summary has to start describing moments.

### 11.2 Canonical JSON

For a variant whose `temporalModel` is `keyframe-delta`, the summary gains two keys, and every
existing key keeps its meaning.

```json
{
  "temporalModel": "keyframe-delta",
  "chunks": [
    {
      "t0": 0.0,
      "t1": 0.25,
      "kind": "keyframe",
      "deltaMode": null,
      "depth": "0",
      "liveCount": "256",
      "updateCount": null,
      "birthCount": null,
      "deathCount": null
    },
    {
      "t0": 0.25,
      "t1": 0.5,
      "kind": "delta",
      "deltaMode": "chained",
      "depth": "1",
      "liveCount": "259",
      "updateCount": "97",
      "birthCount": "4",
      "deathCount": "1"
    }
  ],
  "states": [
    {
      "t": 0.0,
      "liveCount": "256",
      "sample": { "positions": [], "scales": [] },
      "aggregate": { "positionSum": [], "opacitySum": 0.0 },
      "sh": { "degree": 2, "coefficients": "8", "crc": "…" }
    }
  ]
}
```

- `states` is the composed state at a list of **probe instants derived from the file itself**: for
  every index entry, its `t0` and the midpoint of its interval, plus an instant just below
  `duration_sec`. Deriving them from the file rather than hardcoding them means "seek to every
  chunk" is the expectation rather than a separate test, and a decoder that gets one GOP's
  composition wrong fails on that GOP's rows specifically.
- Each state's `sample`, `aggregate` and `sh` are computed exactly as today, over the composed
  state, in the existing content order. Nothing in `canonical.py`'s ordering machinery changes; it
  is called once per probe instead of once per file.
- `chunks` exists because a field no expectation mentions is a field an implementation can decline
  to decode — the reason `profile` and `library` are in the summary. Without it a decoder could
  ignore `depth`, `delta_mode` and `live_count` entirely and pass.
- `gaussianCount` in the summary keeps meaning the Header's field, which §4.1 reads as the count of
  distinct ids.

**The two read paths must agree.** `StreamedDecode` produces `states` by composing front to back;
`IndexedDecode` produces them by seeking to each probe and walking the chain. Identical output from
those two paths is the check that §7's predicate is right, and it is not a check the current corpus
could make.

### 11.3 Scenarios

New scenarios, each carrying `temporal_model = "keyframe-delta"`:

| scenario                  | shape                                                                    | what it catches                                                         |
| ------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------------- |
| `KeyframeOnly`            | every chunk a keyframe, no deltas at all                                 | the model with the delta path switched off; a legal degenerate file     |
| `KeyframeDelta`           | cadence 8, chained, constant population                                  | the ordinary case                                                       |
| `KeyframeDeltaChurn`      | births and deaths in every delta, population growing then shrinking      | the birth and death groups, and id bookkeeping                          |
| `KeyframeDeltaStill`      | the same gaussians updated in every chunk of a GOP, others never touched | untouched-means-no-bytes, and the repeated-update case real content has |
| `KeyframeDeltaLongGop`    | cadence 32, one GOP larger than a reader's 64 KiB head probe             | a reader that fetches a chunk to learn what it references               |
| `KeyframeDeltaModesMixed` | keyframe-referenced and chained deltas interleaved in one GOP            | the chain walk, rather than an assumed shape                            |

Crossed with existing flags: `Quantized` (the bound argument in §8 is only interesting on a coarse
grid), `SHDegree2` (births carrying bands), `UseCrc`, `UseChunkIndex`, and one variant with no index
at all, since a streamed reader must compose without one. `UseChunks` does not apply — chunking is
intrinsic to the model — and is excluded.

New flags: `DeltaChained`, `DeltaKeyframeRef`, `DeltaModesMixed`.

### 11.4 Truncation

Handled the way the existing truncation row is handled — runner-side, since a cut file is a
different file and no expectation can carry it. Each runner cuts its variant three ways and asserts
what survives:

- **mid-GOP**, inside a delta chunk: the last decodable instant is the `t1` of the last complete
  chunk, and every earlier probe still matches the expectation.
- **between a delta chunk and its SH bands**: the trailing-band recovery, on the delta path.
- **inside the first keyframe**: nothing is decodable, which must be a clean report and not a crash.

### 11.5 Files a reader must refuse

§9's table is fourteen conditions, and none of them is provable by a corpus of valid files. This
needs a second, small corpus of deliberately invalid files, each paired with the identifier of the
refusal it must produce — `forward-reference`, `unknown-death-id`, `duplicate-id`,
`invariant-changed-in-update`, `non-tiling-chunks`, `depth-mismatch`, `bin-overflow`,
`level-mismatch`.

That is a **new contract for the harness**: today an expectation is canonical JSON, and this makes
it "JSON, or a named refusal". It is the right shape — a decoder that refuses nothing is not safer
than one that refuses correctly, it is less safe.

**Decided (§13.4): accepted, and it lands first, as its own change.** The harness change is
reviewable on its own and the model's is not reviewable while carrying it. Sequencing it first also
has a property worth naming: the refusal contract can be introduced against conditions that already
exist in version 1 — a window index outside its table, a non-finite quantization step, an unknown
codec — which means it ships proven by rules the format already has, rather than arriving
simultaneously with the rules it is meant to police. A harness feature whose only exercise is the
feature it was built for has not been tested; it has been co-designed with its single test.

### 11.6 Feature matrix rows

Added as `No` or `Planned` for every SDK, and moved only by a passing suite:

- Temporal model: `keyframe-delta`, decode
- Delta composition, chained
- Delta composition, keyframe-referenced
- Births and deaths in deltas
- Reconstruction at an instant — the first row that proves §3's arithmetic rather than a file
  summary
- Encode: `keyframe-delta`

---

## 12. What this proposal costs

Stated together so a reviewer can weigh them without assembling them from the sections above.

1. **One opcode**, `0x10`, out of the specification-defined range. Justified in §4.2: a delta chunk
   is precisely the record that does not satisfy §5.5's independence property, so it must not be
   that record.
2. **A larger file for content that does not move.** §7 quantifies it: a floor of `T / T_gop` full
   restatements regardless of content.
3. **A larger working set for a streamed reader** — one population rather than one chunk (§7).
4. **A new invariant class in readers.** §9 lists fourteen refusal conditions that do not exist
   today, most of them about referential integrity. That is real implementation surface in five
   SDKs.
5. **A second corpus shape** for refusal expectations (§11.5), if it is accepted.
6. **Two models to keep straight.** Every reader now has two decode paths, and the conformance suite
   has to prove that a `gaussian-birth` file still decodes identically after the change — which it
   does mechanically, since the existing 34 variants are untouched and must remain byte-identical.

---

## 13. Disposition

The design was reviewed and **accepted**. Every question it left open was ruled on; each ruling is
recorded here and folded into the section it affects, so the document has no section that
contradicts a decision and no reader has to hold both a recommendation and its outcome in mind.

| #   | question                                   | ruling                                                      | folded into |
| --- | ------------------------------------------ | ----------------------------------------------------------- | ----------- |
| 1   | `gaussian_count` under this model          | Accept the re-reading; state it in normative text           | §4.1        |
| 2   | Header `flags` bit 2 as a mechanical gate  | Do not spend the bit                                        | §5          |
| 3   | Spherical harmonic deltas                  | Accept the limitation; revisit only against real content    | §8          |
| 4   | The refusal corpus                         | Accept, sequenced first, as its own change                  | §11.5       |
| 5   | A single-keyframe file vs `frame-sequence` | Subsume; keep the reserved name as a tombstone              | §4.7        |
| 6   | Per-chunk `delta_mode`                     | Keep it                                                     | §3.4        |
| 7   | Interaction with `level`                   | The reference MUST share `level`; the rest stays undesigned | §3.6        |

Three of these are worth reading as a set, because they are the same judgement applied three times.
Ruling 2 declines a cheaper mechanism because it would produce a worse error message. Ruling 3
declines a wire form that no file needs yet. Ruling 7 adds the smallest rule that stops a question
being answered by accident, and answers nothing else. In each case the format takes on less than it
could have, and in each case the reason is that the alternative would have been decided by
implementation rather than by design — a reserved bit spent to save a string comparison, a signed
band form written before the content that wants it, a level combination whose meaning is whatever
the first decoder did.

Ruling 5 goes the other way and is the one that removes something: `frame-sequence` will never be
separately defined, because this model covers its shape and two names for one wire shape is what a
registry exists to prevent. The name stays as a tombstone rather than being freed, since a freed
name gets spent.

## 14. Implementation sequence

1. **The refusal-corpus harness change**, on its own, first (§11.5). It introduces "an expectation
   may be a named refusal" against conditions version 1 already has, so it arrives proven by rules
   that predate it.
2. **The model.** Specification text moves out of `proposals/` and into the normative document with
   a changelog row; the registry entries land; the Python reference and the Rust production encoder
   and decoder implement it; the corpus gains the scenarios of §11.3 and the truncation cuts of
   §11.4; the canonical summary gains the `states` array of §11.2.
3. **The feature matrix**, last and only then. The rows of §11.6 start at `No` and move when the
   public suite proves them, in the repository's own CI, which is the rule the matrix has always had
   and the reason its cells mean anything.
