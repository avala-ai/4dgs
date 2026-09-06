# Decision record: a `gaussian-birth` Chunk bounds its gaussians

**Status: adopted and folded into [the specification](../index.md).** This record resolves
[#171](https://github.com/avala-ai/4dgs/issues/171). It changes no wire field and creates no new
refusal. Shared conformance and SDK delivery remain separate follow-up work.

---

## 1. The contradiction

Three existing statements did not compose into one answer when a per-gaussian validity window
outlived the Chunk that stored it:

1. Specification §3 tested only `win_lo <= t < win_hi` when defining visibility and called the
   validity window the format's only hard temporal gate.
2. Specification §5.5 defined the Chunk interval as `[t0, t1)` and said its gaussians are invisible
   outside it.
3. Specification §8 made every indexed seek fetch exactly the Chunks whose `[t0, t1)` contains the
   requested instant, and said nothing else is required.

For a gaussian with window `[14, 16)` stored in a Chunk `[14, 15)`, a whole-scene streamed decoder
that retained only the per-gaussian fields could report it at `t = 15`, while an indexed decoder
could not: §8 correctly omitted the owning Chunk. This was observed in
`TenWindows-DeltaStreams-Quantized-UseChunkIndex-UseChunks-UseCrc.4dgs`, where the two paths
reported 25 and 24 gaussians respectively. Both behaviours had text to point at.

This is decoder semantics: it changes the gaussian state reconstructed at one scene-clock instant
and therefore needs one format answer.

## 2. Evidence for the ruling

The Chunk-bounds-window reading is the only one that preserves both explicit container properties:

- §5.5 has described the Chunk interval as semantic since version 1's initial wire definition. It
  says the stored gaussians are invisible outside that interval, not merely that the interval is a
  search hint.
- §8 calls its interval predicate the whole seek algorithm. If a gaussian could contribute after its
  owning Chunk ended, the index would not contain enough information to reconstruct an instant: a
  reader would have to fetch unrelated Chunks and inspect their rows.
- Each Chunk carries `t0` and `t1` in its own content. Applying the rule on a front-to-back path
  does not depend on a Chunk Index and does not require discovery of any new bytes.

The competing interpretation would have to demote §5.5's interval to metadata and abandon §8's
complete range-seek predicate, or add a new producer validity constraint that makes the known
counterexample malformed. Neither is a clarification of the existing model. The intersection rule
is: it gives operative meaning to both intervals already on the wire.

## 3. Decision

### 3.1 Contribution is the half-open intersection

For a gaussian stored in a `gaussian-birth` Chunk with interval `[t0, t1)`, define:

```text
exist_lo = max(win_lo, t0)
exist_hi = min(win_hi, t1)
effective existence = [exist_lo, exist_hi)
```

The Chunk contributes that gaussian to reconstructed state at `t` only if `exist_lo <= t < exist_hi`
and the existing marginal/cutoff test also passes. Both intervals remain half-open, so `t = t1`
never receives the gaussian from that Chunk even when `win_hi > t1`.

The intersection may be empty. A validity window that overhangs either Chunk endpoint, contains the
whole Chunk, or is disjoint from it remains legal. A reader clips contribution; it does not clamp or
rewrite the stored endpoints and it does not refuse the file.

This is specifically the `gaussian-birth` ownership rule. Under `keyframe-delta`, §11 selects the
current state Chunk before it reconstructs that state, so this decision adds no new chain,
composition or interval rule there.

### 3.2 The decoded window fields stay observable

`win_lo` and `win_hi` remain the per-gaussian values reconstructed from the Window Table. An API
that exposes resident rows or decoded attribute fields may return those values unchanged. The
derived intersection controls whether the owning Chunk contributes a row at a requested instant; it
does not replace the fields in a whole-scene or record-level inspection result.

Accordingly, a canonical summary of resident values is not by itself evidence that instant
reconstruction applied the Chunk gate. The executable follow-up must ask both read paths about a
specific instant whose answer changes at a Chunk boundary.

### 3.3 Indexed and streamed paths have one meaning

An indexed decoder applies the Chunk half of the intersection by selecting only entries whose
interval contains `t`, then applies the per-gaussian window and marginal tests inside those Chunks.
It need not fetch an unselected Chunk to discover whether one of its stored windows extends to `t`.

A streamed decoder owes the same contribution rule whether or not the file has a Chunk Index.
No-index input still carries each Chunk's `t0` and `t1` before that Chunk's payload. This decision
does not prescribe how a decoder represents that association: it may evaluate a requested instant
while the Chunk passes, retain interval provenance beside resident rows, or expose/materialize the
effective interval. It prescribes only the result and the repository's existing bounded-memory rule.
It does not require a second pass, an index, or a whole-file buffer.

## 4. Worked boundaries

### 4.1 Right overhang

```text
Chunk:             [14, 15)
validity window:   [14, 16)
effective:         [14, 15)
```

The gaussian may contribute at `t = 14.5` if its marginal reaches the cutoff. It is absent at
`t = 15` and thereafter from this Chunk.

### 4.2 Left overhang

```text
Chunk:             [2, 4)
validity window:   [1, 3)
effective:         [2, 3)
```

The row is absent before `2`, even though its per-gaussian window has begun, and absent from `3`
onward because the validity window is half-open.

### 4.3 Disjoint intervals

```text
Chunk:             [2, 4)
validity window:   [5, 6)
max(lo) >= min(hi), so the effective interval is empty
```

The Chunk still decodes. That row contributes at no instant and produces no diagnostic.

### 4.4 A contained window

```text
Chunk:             [2, 6)
validity window:   [3, 5)
effective:         [3, 5)
```

This common case is unchanged. The marginal/cutoff test may further reduce the instants at which the
gaussian contributes; the intersection is necessary, not sufficient, for visibility.

## 5. Diagnostics and compatibility

This decision adds no refusal identifier. Overhang and an empty intersection are valid data, not an
attribute/index mismatch. Existing validation of Chunk endpoints, Window Table indices, decoded
values, framing and index/record agreement is unchanged.

There is no byte migration:

- current indexed reconstruction retains its existing meaning because §8 already selects by Chunk
  interval;
- streamed and whole-scene APIs that already retain or apply the owning interval retain their
  existing result;
- a streamed or collecting path that previously discarded Chunk ownership and later tested only
  `win_lo`/`win_hi` must stop returning an overhanging row outside its owning Chunk; and
- resident/canonical data may continue to expose the original decoded window endpoints.

The known `[14, 16)`-inside-`[14, 15)` shape remains conforming and now has one meaning: absent at
`t = 15`. This is why the decision clips rather than adding a producer rule that every gaussian's
window or marginal support fit inside its Chunk. A producer may still choose containment, but a
reader may not depend on it. Writer round-trip or quality checks may still ensure that files they
create do not unintentionally clip authored support; that is a producer-output assertion, not a
condition of file validity.

## 6. Staged delivery

1. **Specification first — this change.** Fold the intersection into §§3 and 5.5 and make §8 state
   why its existing range predicate is complete. No feature claim moves in this layer.
2. **Shared conformance next.** Add a small capability-gated `gaussian-birth` witness with a window
   that extends past its owning Chunk. On the indexed form, the harness must query an instant before
   the boundary and exactly at `t1`, then compare the streamed and indexed instant results. A paired
   no-index form must prove that streamed reconstruction uses the interval from the Chunk record
   itself. The expected resident fields keep the original window while the at-`t1` state omits the
   row. Do not classify either file as invalid.
3. **One language per PR.** Each Python, Rust (including the C ABI), TypeScript, Dart, C++ and Swift
   layer implements or proves the gate on every instant-reconstruction path it exposes, including
   the no-index streamed path where applicable, then claims the shared capability only after its
   runner passes.

The shared layer should compare the paths directly at the boundary rather than infer visibility from
the current whole-scene canonical summary. That is the disagreement #171 exposed and the smallest
test that cannot pass while either path still uses the other interpretation.

## 7. Rejected alternatives

### Treat the per-gaussian window as the only truth

Then an indexed reader could not trust `chunks_for(t)`. It would have to fetch Chunks whose index
interval excludes `t` merely to inspect their windows, making the index unable to answer the query
it exists to answer. Calling the Chunk interval “storage only” also contradicts §5.5's explicit
invisibility rule.

### Make every gaussian fit its Chunk

A new producer rule could make the two paths agree by declaring an overhanging file malformed. It
would reject a shape the wire and §5.5 already define cleanly, including the file that revealed the
ambiguity, and it is unnecessary: intersection gives the existing Chunk interval its stated meaning
without a refusal or migration.

### Rewrite `win_lo` and `win_hi` while decoding

Materializing the intersection may be a valid implementation choice, but making it the only public
representation would conflate stored gaussian attributes with Chunk ownership and would change
record-level/canonical inspection unnecessarily. The normative requirement is the contribution at
`t`, not one internal layout.
