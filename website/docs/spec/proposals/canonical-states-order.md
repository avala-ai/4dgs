# Proposal: making the canonical form's `states` member order-free

**Status: proposed, not normative, not implemented.** This document resolves
[#95](https://github.com/avala-ai/4dgs/issues/95). Unlike the other two proposals in this directory
it changes **no specification text**: the canonical JSON is a property of the conformance reference
(`tests/conformance/canonical.py`) and its five ports, not of the format. §5 says where the text
goes instead, and §5.4 says why none of it belongs in [the specification](../index.md).

The canonical form promises that nothing it emits depends on decoded order. Its `states` member —
the post-track reconstruction the object layer exists to prove — breaks that promise in two places,
and this proposal recommends a portable fix for each.

---

## 1. What the reference says today

The promise is stated at the top of the module (`tests/conformance/canonical.py:17-21`):

> **Nothing here may depend on decoded order.** Gaussians may be reordered freely by an encoder and
> readers must not rely on their order, so a summary that did would be asking two correct decoders
> to disagree. Everything per-gaussian — the sample, the aggregates, the spherical harmonic digest —
> is taken in the content order defined by `_stable_order`, which is derived from decoded values
> alone.

It is a restatement of the format's own rule, §6.1: "Gaussians within a chunk MAY be reordered
freely by the encoder; nothing in the format depends on their order, and readers MUST NOT rely on
it."

The mechanism is `_stable_order` (`canonical.py:506-540`), which builds a key per gaussian from its
whole decoded state, rounded to `FLOAT_DECIMALS = 6` by `_sortable` (`:543-551`), with the spherical
harmonic coefficients and `object_id` appended, and sorts. Its docstring makes the argument that
justifies the rounding:

> The key is the gaussian's whole decoded state, rounded exactly as the summary rounds it, with its
> spherical harmonic coefficients last. Two gaussians that tie on all of it are identical in every
> value this summary emits, so their relative order cannot change the output.

Ties are broken by decode order, deliberately and identically in every port: Python sorts `(row, i)`
pairs on `k[0]` alone (`canonical.py:538-540`) and Python's sort is stable; Rust says so in a
comment (`rust/conformance/src/lib.rs:1014-1015`, "A stable sort, so gaussians that tie on every
rounded value keep decode order — the same tiebreak every other implementation's sort makes");
TypeScript pushes the decode index into the key explicitly as a final component
(`typescript/conformance/src/canonical.ts:697`).

Rounding is not an accident either, and any fix has to respect why it is there: two implementations
computing the same decoded value can differ in the last unit in the last place, so an ordering keyed
on exact values would put the same file's gaussians in different orders in different languages. The
rounding is what makes the key portable.

---

## 2. What breaks

### 2.1 The tie argument holds for `sample` and fails for `states`

`_stable_order`'s claim — "identical in every value this summary emits" — is true of the root
`sample` block (`canonical.py:189-204`), whose emitted values are `num(...)` of exactly the fields
the key rounds. Two gaussians that tie therefore emit identical rows and swapping them is invisible.

It is not true of `states` (`canonical.py:214-300`). Those rows are emitted after two operations the
key never sees:

```python
row_for_index = {int(index): row for row, index in enumerate(base["indices"])}
sample_indices = [index for index in order if index in row_for_index][:SAMPLE]  # canonical.py:250
```

and the values are the composed centre and orientation at probe time `t`:

```
base_center = position + motion * (t - mu_t)          # §3
center      = R(t) * base_center + T(t)               # §3, object track
```

The mechanism by which a tie becomes visible is **amplification**, and it is worth naming precisely
because "rounded values tie so the difference is at most 5e-7" is the intuition that makes this look
harmless. Two gaussians can tie on `motion` to six decimals and differ in exact `motion` by up to
1e-6; over a probe with `t - mu_t` of ten seconds that difference becomes 1e-5 in the composed
centre, an order of magnitude larger than the sixth decimal the summary prints. The rotation in
`R(t) * base_center` multiplies rather than adds, so the same argument applies to orientation.

So a legal reordering of gaussians — the reordering §6.1 explicitly permits an encoder — can change
which of two tied rows lands in `states[*].sample`, and the two rows are not interchangeable. That
is precisely the failure the module docstring forbids.

### 2.2 The `states` aggregate sums in resident order

```python
"positionSum": [num(sum(float(row[axis]) for row in centers)) for axis in range(3)],   # canonical.py:262
"opacitySum": num(sum(float(value) for value in base["opacity"])),                     # canonical.py:263
```

`centers` and `base["opacity"]` are indexed by **row**, which is position among the live gaussians
in decode order (`base["indices"]`), not content order. The root aggregate does the opposite,
iterating `for i in order` (`canonical.py:104-116`). Floating-point addition is not associative, so
two files that differ only by a legal reordering can produce different totals.

Two corrections to #95 here.

- **`opacitySum` has the same defect and the issue does not mention it.** Line 263 is the same
  mistake as line 262. A fix that changes only `positionSum` leaves half of it in place. Every port
  mirrors both: `typescript/conformance/src/canonical.ts:447-453`,
  `rust/conformance/src/lib.rs:511-518`.
- **"Iterate `order` rather than `centers`" is not a valid substitution.** `order` indexes all
  gaussians, `centers` is indexed by row over the _live_ ones only, and the two index spaces are
  different sizes at any probe where a gaussian is outside its window. The fix has to go through
  `row_for_index` (`canonical.py:249`) — which is to say it is the same expression the sample
  selection at `:250` already builds, minus the `[:SAMPLE]`.

### 2.3 The comment #95 quotes does not exist

#95 attributes this to `canonical.py:104`:

> Summed in content order, not index order: two decoders that visit gaussians differently must reach
> the same total, and floating-point addition is not associative enough to leave that to chance.

That comment is not in `canonical.py`, at line 104 or anywhere else, and no string containing "not
associative" exists anywhere in the repository. Line 104 is a bare `for i in order:`. The _intent_
is recorded — in the module docstring (`:17-21`), in `_spherical_harmonics`'s docstring (`:484-490`,
"Taken in content order so that two decoders which visit gaussians differently still agree") and in
`tests/conformance/README.md` — but the specific sentence, and the specific reasoning about
associativity, are not written down anywhere. The issue's diagnosis is right; its evidence is a
paraphrase presented as a quotation. Worth saying because "the reference is internally inconsistent"
is a stronger charge when the rule is written next to the code that follows it, and here it is not.

---

## 3. The options

### For the ties

**(1a) Order the `states` rows by what they emit.** Sort the live rows by the content key first and
by the emitted, rounded composed row second, so that any remaining tie ties on the centre, the
orientation and the `object_id` this block prints. Rows that tie after that emit identical arrays
and their relative order provably cannot change the output — which is `_stable_order`'s own
argument, applied at the level where the values are actually produced.

- Cost: `_stable_order` must expose its keys (today it discards them, `canonical.py:538-540`), and
  the `states` block gains a sort over live rows per probe. Six ports, a few dozen lines each.
- Keeps the correspondence with the root sample: where the content keys differ, the order is
  unchanged, so the two `sample` blocks still describe the same gaussians in the same sequence.

**(1b) Extend `_stable_order`'s key to exact decoded values.** Then no two distinct gaussians tie at
all.

- **Rejected.** The rounding in `_sortable` is there because two implementations can compute the
  same decoded value to different last bits; keying on exact values makes the order itself
  implementation-dependent, which turns a rare tie hazard into a routine cross-language ordering
  disagreement. This trades a defect nothing triggers for one everything would.

**(1c) Do nothing and document the exposure.** Legitimate, and cheapest. Its cost is that the module
docstring's "**Nothing here may depend on decoded order**" stays false, and the next person to read
it will take it at face value — which is how #95 was found and how the next one will be missed.

### For the summation order

**(2a) Sum in the same order the rows are emitted in.** Iterate the content-ordered live rows rather
than the resident ones, for `positionSum` and `opacitySum` alike. One expression per aggregate per
port.

- Removes the large exposure: today the sum depends on the chunk layout, which an encoder chooses
  freely.
- **Leaves a residual, and this proposal says so rather than claiming otherwise.** Tied rows form a
  contiguous run in the order, and permuting a run of addends can still change the total, because
  `(s + a) + b` and `(s + b) + a` are not equal in general. Fix (1a) narrows that run to rows whose
  emitted values are identical; it does not make the _unrounded_ addends identical.

**(2b) Sum exact canonical integer units.** First apply the canonical form's existing
`FLOAT_DECIMALS` rounding to each addend, convert the result to a signed integer count of
`10^-FLOAT_DECIMALS` units in an **arbitrary-precision signed integer**, and add those integers
exactly. Convert the final integer back only when serializing the aggregate. The sum then depends
only on the multiset of values the canonical form actually emits, not on row order or a language's
floating-point addition.

- Cost: one rounding and integer conversion per addend. Each port must use the same already-shared
  canonical rounding rule and an arbitrary-precision integer representation for both the scaled
  addend and every partial sum. A declared population is not an overflow proof: one finite decoded
  value may already exceed a fixed-width scaled range. This is `O(n)` and needs no sort.
- This is the only option here that discharges both parts of the promise. Sorting raw floats is not
  sufficient: equivalent cross-language computations may differ in their last bits, which can change
  both the sorted order of close addends and a non-associative result.

**(2c) Exact binary floating-point summation** (`math.fsum` and equivalents). Order-free for one
fixed collection of binary inputs, but not portable when independently computed inputs differ in
their last bits. Only Python has it in the standard library, too. Rejected on portability and cost.

---

## 4. Recommendation

**Adopt (1a) and (2b).**

- **(1a)** because it is the only fix that restores `_stable_order`'s argument at the level where
  the values are emitted, and it does so without touching the rounding that makes the key portable.
- **(2b)** because summing exact canonical units makes the aggregate a function of the emitted
  multiset and gives all six languages the same arithmetic. The adversarial tied-row pair in §6
  makes the rule observable, so it does not ship as an untested convention.
- The same exact-unit helper is used for the root `aggregate` and every `states[*].aggregate`;
  repairing only the latter would leave the module-level order-independence promise false.

### What regeneration costs, and what was measured

The corpus was regenerated into a scratch directory and every variant carrying a `states` member was
examined. `states` is emitted only when a file carries the object layer (`canonical.py:183-187`),
which is four files — `object/SingleObject`, `object/MultiObject`, `object/ObjectTrackComposed` and
the top-level `LongLived-UseChunkIndex-UseCrc-WithObjects`. (#95 and #134 both say "three"; the
top-level `WithObjects` variant is the fourth and it carries a table, a track and an `object_id`
stream.) For each, at each of the three probe times:

| variant                      | gaussians | ties in the key | content order == resident order | rounded `positionSum` changes | rounded `opacitySum` changes |
| ---------------------------- | --------- | --------------- | ------------------------------- | ----------------------------- | ---------------------------- |
| `LongLived-…-WithObjects`    | 256       | 0               | no                              | no                            | no                           |
| `object/SingleObject`        | 6         | 0               | no                              | no                            | no                           |
| `object/MultiObject`         | 8         | 0               | no                              | no                            | no                           |
| `object/ObjectTrackComposed` | 6         | 0               | no                              | no                            | no                           |

Read the two middle columns together: the summation-order defect is **live** — content order differs
from resident order in every variant at every probe, so today's sums really are taken in an order
the format says means nothing — and it is **currently harmless**, because these values are small and
well-conditioned enough that both orders round to the same six decimals. And there are no ties
anywhere, so (1a) reorders nothing.

So the measured cost of (1a) and the weaker (2a) is zero existing expectation bytes. The recommended
(2b) deliberately changes how each addend is rounded before aggregation; the bottom implementation
PR must regenerate and review the four affected expectations rather than assuming that this
measurement covers the stronger arithmetic.

Delivery follows the repository's stacked-PR rule: the corpus, reference canonical and Python runner
form the bottom layer; Rust, TypeScript, Dart, C++ and Swift each get their own language-only layer,
targeting the branch below. Merge and rebase them bottom-up. The affected ports are
`tests/conformance/canonical.py`, `rust/conformance/src/lib.rs`,
`typescript/conformance/src/canonical.ts`, `dart/conformance/lib/canonical.dart`,
`cpp/conformance/canonical.cpp` and `swift/conformance/Support/Summary.swift`. This is an unusually
good moment to make the change, and it will not stay true — the first adversarial scene makes the
same fix regenerate its new expectation.

---

## 5. The text

### 5.1 `canonical.py`'s module docstring, replacing the "Nothing here may depend on decoded order" paragraph

> **Nothing here may depend on decoded order.** Gaussians may be reordered freely by an encoder and
> readers must not rely on their order, so a summary that did would be asking two correct decoders
> to disagree. Per-gaussian rows and the spherical harmonic digest use the content order defined by
> `_stable_order`; the root aggregate and every per-state aggregate sum exact arbitrary-precision
> integer units after the same canonical rounding used for emitted values, so their result is a
> function of the multiset rather than an iteration order.
>
> That order rounds to `FLOAT_DECIMALS` before comparing, which is deliberate — two implementations
> can compute a decoded value to different last bits, and an order keyed on exact values would
> differ between languages — and it is why **two gaussians can tie on the key and still hold
> different exact values**. A tie is harmless wherever the emitted values _are_ the keyed fields,
> which is true of the root `sample`. It is not true of `states`, whose rows are composed at a probe
> time: a difference below the sixth decimal in `motion` becomes visible in a centre after
> multiplication by `t - mu_t`. So the `states` block orders its rows by the content key **and then
> by the rounded values it emits**, and a tie that survives both ties on every number that block
> prints.

### 5.2 `canonical.py`, as a comment on the root and `states` aggregates

> Each addend is rounded by the canonical `num` rule and converted to an integer count of
> `10^-FLOAT_DECIMALS` units before summation. Both the scaled addend and accumulator are
> arbitrary-precision signed integers: a population limit alone cannot make a fixed-width addend
> safe. The integer sum is exact and therefore depends only on the multiset, never resident or
> decoded order. Sorting and then adding raw floats would still be non-portable: equivalent
> computations in different languages may differ in their last bits and therefore sort or sum
> differently.

### 5.3 `tests/conformance/README.md`, replacing the "nothing depends on decoded order" bullet

> - **nothing depends on decoded order.** Gaussians may be reordered freely by an encoder, so the
>   sample, the aggregates and the spherical harmonic digest are all taken in a content order
>   derived from decoded values alone. That order rounds before comparing, so two gaussians can tie
>   on it and still hold different exact values — harmless wherever the emitted values are the keyed
>   fields, and not harmless in `states`, whose rows are composed at a probe time from inputs the
>   key sees only rounded. The `states` block therefore orders by the content key and then by the
>   rounded values it emits. The root aggregate and every state aggregate round each addend to
>   canonical arbitrary-precision integer units and sum those units exactly, making them independent
>   of both storage order and floating-point addition order.

### 5.4 Nothing in `website/docs/spec/index.md`

Stated as a recommendation rather than an omission. The canonical form is how two implementations
are diffed; it is not what a conforming decoder must produce, and no decoder emits it outside a
conformance runner. Putting the tie rule or the summation rule into the specification would make a
testing convention normative for every reader in the world, and would invite the reading that a
decoder's own aggregates have to be computed a particular way — which the format has never said and
should not start saying.

The format-level statement already exists and is sufficient: §6.1's "Gaussians within a chunk MAY be
reordered freely by the encoder; nothing in the format depends on their order, and readers MUST NOT
rely on it." Everything in this proposal is the conformance reference being held to that sentence.

---

## 6. The conformance variants that pin it

Five cases, represented by eight files; all three tie-sensitive cases are deliberately paired
encodings.

- **`ObjectTiedGaussians` and `ObjectTiedGaussiansReordered`** — two encodings of the same
  object-layer gaussian multiset, containing at least one pair of gaussians that tie on every field
  of the `_stable_order` key at six decimals while differing in exact `position` and `motion`, with
  a `mu_t` far enough from the probe times that the difference amplifies past the sixth decimal in
  the composed centre. Built by choosing a `step_pos` and `step_motion` fine enough that two
  adjacent bins round identically — a quantization choice, not a hand-written float. The second file
  permutes the tied rows' physical/resident order while preserving every decoded value; the
  generator refuses to emit the pair unless their pre-fix resident-order canonicals differ and their
  content-order canonicals are identical.

  **What it asserts:** every runner produces identical `states[*].sample` rows for both encodings.
  Without fix (1a), the stable sort retains the two different decoded resident orders when its key
  ties, so at least the reordered file disagrees with the shared expectation. No decoder is assumed
  to choose its own chunking or order; the two inputs supply both orders explicitly.

- **`ObjectCancellingPositionSum`** — live centres of large opposing sign spread across at least two
  chunks, with resident order grouping signs and content order interleaving them. The generator must
  assert before writing the expectation that the two pre-fix orders produce different values after
  six-decimal rounding. It asserts only `states[*].aggregate.positionSum`; opacity is deliberately
  held constant so a position fix cannot borrow evidence from another field.

- **`ObjectOpacityOrder`** — 64 live gaussians whose decoded opacities contain 32 high values, 31
  low values and one boundary value tuned so resident-order and content-order addition land on
  opposite sides of a six-decimal rounding boundary. Resident order groups high then low values; the
  content key alternates them. The generator records both sums and refuses to emit the variant
  unless their rounded `opacitySum` differs, while all centres are zero. This independently catches
  a port that fixes `positionSum` and leaves opacity in resident order.

- **`ObjectResidualTieSum` and `ObjectResidualTieSumReordered`** — two encodings of the same rows,
  which tie both on `_stable_order` and on the rounded secondary row emitted by (1a), while their
  unrounded composed centres differ. The second encoding reverses the surviving tied run's physical
  order and changes no decoded value. Their generator preconditions are explicit: secondary
  emitted-row keys compare equal, and resident-order addition in the two encodings lands on opposite
  sides of a six-decimal boundary. The generator evaluates the two summary levels independently,
  because they do not sum the same values: root `aggregate.positionSum` sums stored positions, while
  each `states[*].aggregate.positionSum` sums centres composed at that probe. For the root and for
  **every** probe whose aggregate is asserted, it MUST separately prove that sorting and adding the
  applicable raw floats produces a rounded total that differs from the exact sum of the individually
  rounded integer-unit addends. A state-level witness is not evidence for the root, and one probe is
  not evidence for another; an aggregate that does not meet the precondition is omitted rather than
  claimed. The pair shares the resulting integer-unit expectations, so neither stable resident order
  nor the explicitly rejected raw-float sort can pass at either summary level. This is the first
  pair that actually reaches (2a)'s residual and therefore the trigger for implementing (2b);
  `ObjectTiedGaussians` cannot serve that role because its emitted centres differ. It belongs in the
  follow-up stack that adopts (2b), not in the initial (1a)/(2a) stack whose limitation it is
  designed to expose.

- **`ObjectResidualTieOpacity` and `ObjectResidualTieOpacityReordered`** — the opacity counterpart
  to the preceding pair. The rows tie on the six-decimal opacity component of the primary key and on
  the complete rounded emitted-state secondary key, but carry distinct unrounded decoded opacities.
  The second encoding reverses only that surviving tied run. The generator must prove that
  resident-order addition crosses a six-decimal `opacitySum` boundary between the two files. Here
  too the root and state preconditions are separate: the root sums stored alpha, while each state
  sums the time-weighted opacity at its probe. For the root and for every asserted probe, the
  generator MUST independently show that raw-float sorted addition rounds differently from exact
  integer-unit addition; it cannot use a state witness to claim root coverage or vice versa. The
  pair shares those integer-unit expectations for root `aggregate.opacitySum` and every qualifying
  `states[*].aggregate.opacitySum`. `ObjectOpacityOrder` proves that (2a) must use content order,
  but cannot catch a port that applies (2b)'s exact-unit rule to centres alone; this pair makes both
  aggregates and both summary levels part of the deferred (2b) contract.

All five belong beside the existing `object/` variants. None needs a spec change, a new opcode or a
new writer capability — they are ordinary scenes with adversarially chosen numbers. The generator's
precondition assertions are part of the design: an adversarial name is not evidence unless the
constructed values demonstrably separate the two algorithms.

---

## 7. Claims in #95 this proposal could not confirm as written

- **The quoted comment at `canonical.py:104`.** Not present, at that line or anywhere; see §2.3. The
  substance of the claim — that the root aggregate deliberately sums in content order — is correct
  and is visible in the code (`for i in order`) and in the module docstring.
- **"For the sum: iterate `order` rather than `centers`."** Not a valid substitution as written; the
  two index different spaces. See §2.2.
- **"The three object-layer conformance variants."** Four; see §4.
- **What the issue does not say, and should:** `opacitySum` (`canonical.py:263`) has the same defect
  as `positionSum` and needs independent conformance evidence.

---

## 8. Deliberately not decided here

- **Whether `FLOAT_DECIMALS` should change.** Raising it narrows ties and widens cross-language
  last-bit disagreements; it is a different trade with different evidence and it should not ride
  along with this one.
- **Whether the `keyframe-delta` canonical needs the same treatment.** It does not, today:
  `keyframe_delta_file.reconstruct_at` orders by `gaussian_id`, which is unique within a state
  (§11.2) and is a decoded value, so it has no ties to break. That remains true only while that
  canonical stays keyed on identity, which is worth remembering if it ever grows an object-layer
  block ([#79](https://github.com/avala-ai/4dgs/issues/79)).
