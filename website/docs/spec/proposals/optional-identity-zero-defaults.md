# Decision record: omitted optional identity lanes have logical value zero

**Status: adopted and folded into [the specification](../index.md) and [registry](../registry.md).**
This record resolves [#225](https://github.com/avala-ai/4dgs/issues/225). It decides only the three
optional identity lanes and their `keyframe-delta` composition. Object Track composition, the
`objects` profile under `keyframe-delta`, and their implementation/corpus work remain in
[#79](https://github.com/avala-ai/4dgs/issues/79) and its
[separate proposal](./objects-under-keyframe-delta.md).

---

## 1. The contradiction

Version 1 names three optional per-gaussian identity lanes:

| attribute      | id  | logical domain | role                         |
| -------------- | --- | -------------- | ---------------------------- |
| `source_group` | 11  | `i32`          | producer-side grouping label |
| `source_index` | 12  | `i32`          | producer-side stable label   |
| `object_id`    | 14  | `u32`          | object membership            |

Specification §6.1 said all three were optional, and §5.18 said a birth carried the full
**required** attribute set plus `gaussian_id`. Read literally, omitting any of the three from a
complete Chunk or birth was legal. Only §6.6 supplied a value for the omission: `object_id = 0`. No
text said what a composed row held when `source_group` or `source_index` was absent.

That gap produced incompatible readers. Some refused an otherwise complete birth as
`incomplete-birth`; some padded all three lanes; some padded only `object_id`. The bytes were legal
under §5.18 but did not reconstruct to one state under §8's cross-SDK contract.

There was a second ambiguity. §5.18 said every update stream except rotation carried bin differences
against its reference. That is sensible for a quantized position and meaningless for an identity
label. The accepted [object-layer design](./object-layer.md#34-composition--the-load-bearing-rule)
already ruled that `object_id` updates are absolute restatements, but that sentence had not reached
the normative specification. Nothing had made the equivalent decision for the two producer lanes.

---

## 2. Decision

### 2.1 One omission rule for all three lanes

`source_group`, `source_index` and `object_id` each have logical value **zero** where an introducing
record omits the lane:

- a `gaussian-birth` Chunk that omits a lane gives every gaussian in that Chunk value `0`;
- a complete `keyframe-delta` keyframe Chunk that omits a lane gives every gaussian in that keyframe
  value `0`;
- a Delta Chunk birth group that omits a lane gives every birth value `0`.

An implementation may retain physical-presence metadata or expose a nullable storage optimization.
That does not change the reconstructed state: absent and explicitly all-zero columns are logically
equivalent. A consumer asking for a row's identity gets zero, and a composer that materializes the
lane creates a population-length zero column.

When a `gaussian-birth` population combines Chunks with different physical stream sets, an omitted
Chunk contributes zero rows to a lane another Chunk carries. The reader cannot discard the other
Chunk's explicit labels merely because the stream was not universal. The default is a closed rule
for ids 11, 12 and 14; it does not assign zero semantics to unknown, reserved or private attributes.

The decision assigns no extra meaning to producer label `0`. It merely makes physical omission and
explicit zero indistinguishable in the logical state. `object_id = 0` retains §6.6's existing
background/unassigned meaning.

### 2.2 Updates carry forward on omission and replace absolutely on presence

Under `keyframe-delta`, absence from an **update group** has a different role from absence from a
complete state or birth:

- if an update lane is omitted, each touched gaussian keeps its reference value;
- if the lane is present, it has exactly `update_count` rows aligned one-for-one with the update
  group's `gaussian_id` stream, and each row replaces that gaussian's label absolutely;
- if the reference physically omitted the lane, the composer first treats every surviving reference
  row as zero, then applies the aligned absolute replacements;
- gaussians outside the update set retain their reference values, including implicit zeros.

This preserves §11.3's “untouched means no bytes” rule. Omission cannot mean zero in an update,
because it already means unchanged for every other update attribute. A producer that wants to reset
a non-zero label to zero writes an explicit absolute zero for that row.

### 2.3 Births extend the whole population

After deaths and updates, births append rows:

- if a birth supplies a lane that the surviving reference population lacks physically, the composer
  materializes zeros for all survivors before appending the births' absolute values;
- if survivors already carry the lane and a birth omits it, the composer appends zero for that
  birth;
- if both sides omit it, the logical column may remain implicit, but every row still has value zero.

The resulting column, if materialized, always has one row per gaussian in the composed population. A
`birth_count`-row suffix beside a larger `gaussian_id` population is not a valid internal state.

### 2.4 Identity labels are not temporal differences

All three lanes are exact labels. `source_group` and `source_index` use the signed `i32` domain that
the Attribute Stream integer pipeline produces. `object_id` owns `u32` and uses §6.6's same-bits
signed stream representation. None is dequantized and none has a meaningful error bound.

When any of them appears in a Delta Chunk update, its stored values are absolute labels, not
differences from reference labels. This is an explicit new semantic decision for `source_group` and
`source_index`. For `object_id` it promotes the already accepted object-layer ruling into normative
text without adopting the rest of #79.

Attribute Stream `mode = 1` remains legal for all three. That mode delta-codes consecutive symbols
inside one physical stream as reversible compression; it does not turn an update label into a
semantic difference across state chunks.

---

## 3. Worked transitions

The examples use source lanes so the rule cannot be mistaken for an object-only exception. Each
applies identically to all three attributes.

### 3.1 Absent reference, present update

A keyframe introduces A and B and omits `source_index`:

```text
reference ids:          [A, B]
physical source_index:  absent
logical source_index:   [0, 0]
```

A delta updates A and carries `source_index = 7`. The composer materializes the reference zeros and
applies the one aligned replacement:

```text
result:                 [7, 0]
```

### 3.2 Present reference, omitted update

If A already has `source_index = 7` and a position-only update touches A without a `source_index`
stream, the result remains `7`. The lane's omission means carry-forward, not reset.

If the producer's next complete source sample instead omits `source_index`, that sample logically
contains zero. Encoding it as a delta against A = 7 therefore requires an explicit absolute
`source_index = 0` update. Merely omitting the update stream would encode the different state A = 7.

### 3.3 Absent reference, present birth

A surviving gaussian A comes from a reference that omitted `source_group`. A Delta Chunk then births
B with `source_group = 4`:

```text
survivor prefix:        [0]
birth suffix:           [4]
composed result:        [0, 4]
```

The birth cannot create a one-row column beside a two-row population.

### 3.4 Present reference, omitted birth

A survives with `source_group = 4`; B is born without the lane:

```text
composed result:        [4, 0]
```

The omitted birth is complete and conforming. It does not erase A's label and it is not
`incomplete-birth`.

### 3.5 Complete keyframe omission

A new keyframe is not an update of the preceding GOP. If it omits an identity lane after an earlier
state carried non-zero values, every row in the new keyframe has logical value zero. No identity
label crosses a keyframe boundary unless that keyframe states it.

---

## 4. Diagnostics and refusal implications

This decision adds no refusal identifier.

- A reader MUST NOT report `incomplete-birth` merely because a birth omits `source_group`,
  `source_index` or `object_id`. That diagnosis remains appropriate for a required birth attribute
  or `gaussian_id` that is absent.
- A present optional lane still obeys ordinary Attribute Stream structure: one channel, the group's
  declared element count, a valid payload, and representable label codes. Existing structural or
  count diagnostics apply when those conditions fail.
- Introducing a present update or birth lane into a physically absent reference is valid and MUST
  NOT be refused as an attribute-set mismatch. The composer supplies the zero prefix.
- A writer MUST NOT put any identity lane in Quantization `bounds`. Labels are exact, so the
  existing malformed-Quantization rule applies; there is no new identity-specific refusal code.
- The `objects` profile is a producer promise, not a reader validity gate. This decision does not
  settle how that profile applies to keyframes, updates, births or deaths under #79.

---

## 5. Compatibility

No record layout, opcode, flag, attribute id or stored code changes. Files that explicitly carry all
three lanes decode exactly as before unless they put a producer identity in a delta update, where
the old normative text was ambiguous and this decision selects absolute replacement.

For omitted lanes, readers that already materialized zero keep the same result. Readers that raised
`incomplete-birth` for an omitted optional identity were rejecting bytes §5.18 allowed and must now
accept them. An API may continue returning a nullable column to report physical absence, provided
composition and all semantic consumers observe the logical zeros.

The repository's `keyframe-delta` writers do not currently emit optional identity lanes and the
shared keyframe corpus carries none, so there is no known produced file whose update meaning
changes. That makes this the compatibility-safe point to decide that producer identities are labels
rather than arithmetic quantities. A third-party file that already used them in updates encountered
an underspecified rule; after this decision its conforming interpretation is absolute.

This record deliberately does not adopt Object Track composition, the `objects` profile rewrite, or
the #79 corpus scenario. It adopts only the `object_id` update and omission mechanics that #79
needs, generalized to the two older optional identity lanes because leaving them different would
recreate #225 under new wording.

The same specification edit also corrects §11.5's pre-existing `rotation_index` contradiction: §5.18
already made it absolute when present, so it cannot also be GOP-invariant. That textual correction
changes neither this identity decision nor any stored value.

---

## 6. Delivery sequence

The change is delivered as a stack, with one writer per lane:

1. **Specification first — this decision.** Amend §§3, 5.3, 5.18, 6.1, 6.6, 11.1, 11.3, 11.5 and
   11.7 plus the attribute registry. No SDK or corpus claim moves in this layer.
2. **Shared conformance second.** Add small capability-gated witnesses for all three lanes and both
   read paths. They must cover omitted complete keyframes/Chunks, absent-to-present updates and
   births, omitted updates carrying forward, omitted births appending zero, explicit
   non-zero-to-zero updates, and exact absolute producer labels. The capability remains unclaimed
   until an SDK passes every applicable witness; existing corpus bytes and scores do not move
   silently.
3. **One SDK language per PR.** Stack Python, Rust, TypeScript, Dart, C++ and Swift implementation
   layers as required by AGENTS.md. Each changes only its own language, runs its validator and both
   decoder paths, and activates only its own capability after passing the shared suite.
4. **#79 remains separate.** Object Track composition, object-aware canonical output, the `objects`
   profile under `keyframe-delta`, and their feature-matrix claims land through #79's own
   spec/corpus/language sequence rather than hitchhiking on the identity-default fix.

---

## 7. Rejected alternatives

### Require every live column on every birth

This would make birth validity depend on which optional lanes happen to exist in the reference
population, contradicting §5.18's required-set wording and making the same birth legal after one
keyframe and malformed after another. It also loses the compact all-zero representation that makes
an optional lane optional.

### Give defaults only to `object_id`

That preserves the exact disagreement in #225. The two producer lanes remain optional with no value
for an omitted birth, so implementations must still invent either refusal or padding. One rule for
three structurally identical identity lanes is smaller and testable.

### Treat producer identities as bin differences

Subtraction has meaning on a metric grid; these lanes have no metric and no quantization bound.
Label 12 is not five units away from label 7. Absolute replacement is already the accepted
`object_id` precedent and avoids plausible, silent relabelling.

### Make omitted updates reset to zero

That conflicts with §5.18's generic meaning of an absent update stream and makes it impossible to
perform a position-only update without rewriting every identity lane. Explicit zero already encodes
a reset without overloading omission.
