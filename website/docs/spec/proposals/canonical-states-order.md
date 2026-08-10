# Proposal: making the canonical form's `states` member order-free

**Status: proposed, not normative, not implemented.** This document resolves
[#95](https://github.com/avala-ai/4dgs/issues/95). Unlike the other two proposals in this directory
it changes **no specification text**: the canonical JSON is a property of the conformance reference
(`tests/conformance/canonical.py`) and its five ports, not of the format. §5 says where the text
goes instead, and §5.4 says why none of it belongs in [the specification](../index.md).

The canonical form promises that nothing it emits depends on decoded order. Its `states` member —
the post-track reconstruction the object layer exists to prove — breaks that promise in two places,
and this proposal recommends one fix for each, plus a third defect found while verifying the first
two.

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
sample_indices = [index for index in order if index in row_for_index][:SAMPLE]   # canonical.py:250
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

### 2.4 A third defect, found while verifying the first two: signed zero

`num()` rounds and returns (`canonical.py:53-64`); `round(-4e-17, 6)` is `-0.0` and
`round(4e-17, 6)` is `0.0`, and `json.dumps` spells them differently. A composed coordinate whose
true value is zero and whose computed value is arithmetic noise of either sign therefore prints as
`0.0` or `-0.0` depending on the arithmetic path.

This is observable now.
`tests/conformance/data/object/ObjectTrackComposed-UseChunkIndex-UseCrc.json` carries exactly two
`-0.0` values in the whole corpus, at lines 505 and 602, both inside `states`. Regenerating the
corpus on this machine (Python 3.12.3, numpy 2.5.1, x86-64 Linux) reproduces every other byte of
every other expectation and turns the one at line 505 into `0.0`: the composed `z` there is
`+4.44e-17` locally, and was a small negative on whatever machine wrote the committed file.

**It is invisible to the harness and visible in git.** `run.py:207` compares
`json.loads(actual) == json.loads(expected)`, and `-0.0 == 0.0` is `True` in Python, so no runner
fails. What it does is make `tests/conformance/generate.py` produce a one-line diff on a corpus
nobody changed — and `generate.py --verify` will not catch it either, because `_verify`
(`generate.py:817-856`) asserts the `.4dgs` SHA-256s and generator determinism and never compares
the `.json` expectations, which `write_corpus` has already overwritten in place by then.

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

**(2b) Make the sum provably order-free by sorting the addends.** Sort each axis's values and sum
ascending. The result then depends only on the multiset of addends: equal values permute without
effect, so any reordering gives the identical total.

- Cost: an `O(n log n)` sort per axis per probe in six languages, and a rule ("ascending, ties
  irrelevant") that every port must implement identically. Real, and small.
- This is the only option that actually discharges the promise. It is not recommended **now** only
  because nothing can detect the difference between it and (2a) until a variant exists that ties,
  and a rule nobody can test is a rule that drifts.

**(2c) Exactly-rounded summation** (`math.fsum` and its equivalents). Order-free by construction,
and the most expensive: only Python has it in the standard library, and hand-rolling exact summation
in six languages is the easiest of these three to get subtly different between ports. Rejected on
cost.

### For signed zero

**(3a) Normalize in `num()`:** return `0.0` when the rounded value is zero, whatever its sign. One
line per port.

**(3b) Leave it.** The harness already treats the two as equal, so this is a diff-noise fix rather
than a correctness fix.

---

## 4. Recommendation

**Adopt (1a), (2a) and (3a). Name (2b) as the follow-up that the tie variant would justify.**

- **(1a)** because it is the only fix that restores `_stable_order`'s argument at the level where
  the values are emitted, and it does so without touching the rounding that makes the key portable.
- **(2a)** because it makes the reference internally consistent — the defect #95 actually names —
  and costs one expression per aggregate. It does not fully discharge the promise, and §5.2's text
  says that in the docstring rather than leaving a future reader to assume otherwise.
- **(3a)** because it costs one line, removes a source of committed-file churn that no test can see,
  and closes a hole in `generate.py --verify` without having to widen `--verify` itself.
- **(2b) deferred**, with a named trigger: once a corpus variant exists that produces a rounded-key
  tie, (2a)'s residual becomes detectable, and at that point sorting the addends is worth the six
  ports. Doing it before then means shipping a rule nothing checks.

### What regenerating expectations costs: nothing, and this was measured

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

So the cost of (1a) and (2a) is: **zero expectation bytes**, in any of the six languages. It is six
code changes and one review, not a corpus regeneration — `tests/conformance/canonical.py`,
`rust/conformance/src/lib.rs`, `typescript/conformance/src/canonical.ts`,
`dart/conformance/lib/canonical.dart`, `cpp/conformance/canonical.cpp` and
`swift/conformance/Support/Summary.swift`. That is an unusually good moment to make a change like
this, and it will not stay true — the first variant that ties, or the first scene with large
opposing coordinates, makes the same fix a corpus-wide regeneration.

(3a) is the only one that moves a byte: two values in one file
(`object/ObjectTrackComposed-UseChunkIndex-UseCrc.json:505` and `:602`), from `-0.0` to `0.0`. No
runner's result changes, since the harness already compares them equal.

---

## 5. The text

### 5.1 `canonical.py`'s module docstring, replacing the "Nothing here may depend on decoded order" paragraph

> **Nothing here may depend on decoded order.** Gaussians may be reordered freely by an encoder and
> readers must not rely on their order, so a summary that did would be asking two correct decoders
> to disagree. Everything per-gaussian — the sample, the aggregates, the spherical harmonic digest —
> is taken in the content order defined by `_stable_order`, which is derived from decoded values
> alone.
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

### 5.2 `canonical.py`, as a comment on the `states` aggregate

> Summed over the content-ordered live rows, not over the resident ones, matching the root aggregate
> at the top of `summarize`. Resident order is the order the file stored, which §6.1 says means
> nothing, and floating-point addition is not associative: two files differing only by a legal
> reordering would otherwise reach different totals.
>
> This narrows the exposure rather than removing it. Rows that tie on the content key form a
> contiguous run, and permuting a run of addends can still change a total — `(s + a) + b` is not
> `(s + b) + a` in general. Making the sum provably order-free means sorting the addends and summing
> ascending, so the result depends only on their multiset. That is deferred until a variant exists
> that can tell the two apart; a rule nothing checks is a rule that drifts.

### 5.3 `tests/conformance/README.md`, replacing the "nothing depends on decoded order" bullet

> - **nothing depends on decoded order.** Gaussians may be reordered freely by an encoder, so the
>   sample, the aggregates and the spherical harmonic digest are all taken in a content order
>   derived from decoded values alone. That order rounds before comparing, so two gaussians can tie
>   on it and still hold different exact values — harmless wherever the emitted values are the keyed
>   fields, and not harmless in `states`, whose rows are composed at a probe time from inputs the
>   key sees only rounded. The `states` block therefore orders by the content key and then by the
>   rounded values it emits, and sums its aggregates over that order rather than over the order the
>   file stored.

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

## 6. The conformance variant that pins it

Two variants, both new files, neither regenerating anything.

- **`ObjectTiedGaussians`** — an object-layer scene containing at least one pair of gaussians that
  tie on every field of the `_stable_order` key at six decimals while differing in exact `position`
  and `motion`, with a `mu_t` far enough from the probe times that the difference amplifies past the
  sixth decimal in the composed centre. Built by choosing a `step_pos` and `step_motion` fine enough
  that two adjacent bins round identically — a quantization choice, not a hand-written float.

  **What it asserts:** every runner produces the same `states[*].sample` rows. Without fix (1a) two
  decoders that chunk the scene differently produce different rows, so the variant fails today and
  passes after — which is the property that makes it worth adding rather than a restatement.

  It also makes (2a)'s residual detectable for the first time, which is the trigger §4 names for
  taking up (2b).

- **`ObjectCancellingSum`** — the same scene shape with live centres of large opposing sign spread
  across at least two chunks, so that the two summation orders produce different sixth decimals.
  Asserts `states[*].aggregate.positionSum` and `opacitySum`. This is the variant that would have
  failed on the day line 262 was written, and its absence is why the defect has been sitting in the
  reference.

Both belong beside the existing `object/` variants. Neither needs a spec change, a new opcode or a
new writer capability — they are ordinary scenes with adversarially chosen numbers, which is the
cheapest kind of variant this corpus can grow.

**One harness note, separable from this proposal.** `generate.py --verify` (`generate.py:792-856`)
asserts the `.4dgs` checksums and generator determinism, and `write_corpus` rewrites the `.json`
expectations in place before it runs, so a drifted expectation is silently overwritten rather than
reported. That is how the `-0.0` in §2.4 has stayed committed. Whether `--verify` should compare the
expectations too, or whether CI should add a `git diff --exit-code` after it, is a harness question
and not a canonical-form one — but it is the reason (3a) is worth doing rather than tolerating.

---

## 7. Claims in #95 this proposal could not confirm as written

- **The quoted comment at `canonical.py:104`.** Not present, at that line or anywhere; see §2.3. The
  substance of the claim — that the root aggregate deliberately sums in content order — is correct
  and is visible in the code (`for i in order`) and in the module docstring.
- **"For the sum: iterate `order` rather than `centers`."** Not a valid substitution as written; the
  two index different spaces. See §2.2.
- **"The three object-layer conformance variants."** Four; see §4.
- **What the issue does not say, and should:** `opacitySum` (`canonical.py:263`) has the same defect
  as `positionSum`, and the signed-zero exposure in §2.4 is a third instance of the same class.

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
- **Whether `--verify` should compare expectations.** Named in §6 as the reason (3a) matters; left
  to whoever owns the harness.
