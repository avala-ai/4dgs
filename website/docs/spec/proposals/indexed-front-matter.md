# Proposal: front matter ends at the first Chunk

**Status: proposed, not normative, not implemented.** This document resolves
[#78](https://github.com/avala-ai/4dgs/issues/78). It proposes one rule, states the spec text that
would carry it, and names the conformance variant that would stop the next implementation guessing.
Nothing here is in force until it is folded into [the specification](../index.md).

The question in #78 is short and the answer decides geometry: **may a provenance-family record
(`0x20`–`0x2F`) appear after the first `Chunk`?** Auditing the two read paths exposes the same
unstated position rule for the legacy Audio (`0x04`), Camera (`0x0A`), Metadata (`0x0B`) and
Attachment (`0x0D`) records. The answer therefore has to cover every record the indexed front-matter
walk collects, rather than fixing one family while leaving four identical divergences.

---

## 1. What the format says today

Three statements, each individually reasonable, that together leave the question open.

**§5.15 dispatches by opcode, not by position.** The paragraph is explicit
([spec §5.15](../index.md)):

> Nothing requires a reader to see these in any order; records are skipped and dispatched by opcode,
> not by position. But a writer that emits them in ascending opcode order produces a file whose
> front matter reads close to the order a human would explain it.

**§4's layout is normative only where stated.** The layout diagram places
`[<Provenance record> ...]` before `<Chunk record> ...`, and the sentence under it says: "Order is
normative only where stated: the Header MUST be the first record, the Footer MUST be the last, and
the summary MUST be contiguous (§4.5)." Record position is therefore descriptive for everything else
in the diagram.

**§5.15.1 says where the family belongs, without a MUST.** "These are not summary records (§4.5).
They carry content, and trajectories are unbounded [...] They belong with the other content records
ahead of the chunks, for exactly the reason attachments do." That is intent, stated as a fact about
where they belong rather than as a rule about what a writer may emit.

So the only positions the format actually forbids are inside the summary run — §4.5 says a writer
"MUST NOT emit any other record inside that run" — and after the Footer, which must be last. The
window between the first `Chunk` and `summary_start` is legal, unstated, and is where the
disagreement lives.

**One record family already has the rule this one lacks.** [§5.17](../index.md) closes exactly this
gap for audio:

> Each pair MUST appear before the first Chunk so an indexed reader can frame every source and
> range-read its encoded bytes without fetching a gaussian chunk or the payload itself.

That sentence is the whole of this proposal, one record family further out. It is worth noticing
that it states the reason as a property of the indexed path, not as a stylistic preference.

## 2. What breaks

### 2.1 Every indexed reader stops at the first Chunk; no streamed reader does

The four native indexed readers frame front matter in one loop and leave it at the first `Chunk`:

| implementation | line                                                |
| -------------- | --------------------------------------------------- |
| Python         | `python/fourdgs/fourdgs/indexed_reader.py:216-218`  |
| Rust           | `rust/fourdgs/src/indexed_reader.rs:314-318`        |
| TypeScript     | `typescript/core/src/indexedDecoder.ts:209-210`     |
| Dart           | `dart/fourdgs/lib/src/indexed_reader.dart:999-1004` |

C++ and Swift are not a fifth and sixth answer: both consume the Rust core through the C ABI
(`rust/fourdgs/src/capi.rs`, `cpp/src/backend_capi.cpp`, `swift/Sources/CFourDGS/module.modulemap`),
so they inherit that loop rather than duplicate it. The issue's "all five implementations" is better
stated as **four native indexed readers and two bindings over one of them** — the conclusion is the
same and the count is not.

Legacy Audio, Camera, Metadata, Attachment, provenance and object-layer records are framed inside
that loop and nowhere else — Python `indexed_reader.py:263-264`, Rust `indexed_reader.rs:449`,
TypeScript `indexedDecoder.ts:257-261`, Dart `indexed_reader.dart:1203-1204` — and the deferred
readers walk only what the loop collected (`read_provenance`, `indexed_reader.py:430`;
`read_objects`, `indexed_reader.py:459`). A record past the break is therefore not merely unread: it
is never framed, so no later call can reach it.

The streamed reader has no such boundary. `python/fourdgs/fourdgs/stream_reader.py:344` iterates
every record in the file and dispatches the legacy records at lines 379–416 and `0x20`–`0x25` at
lines 417–444 with no position test at all. The contrast inside that same function is the tell:
`AUDIO_SOURCE` and `AUDIO_DATA` **do** carry one (`stream_reader.py:383-385` and `392-394`,
`raise MalformedFile("an Audio Source record appears after the first Chunk")`), because §5.17 gave
them a rule to enforce. The provenance family has no rule, so there is nothing to enforce and
nothing is enforced.

### 2.2 The divergence is geometric, and demonstrable today

This was checked rather than assumed. A file was written with the reference encoder carrying an
`object_id` stream and an Object Table but no track, and one Object Track record was then spliced in
between the last `Chunk` and the first `Chunk Index` — a position nothing in the specification
forbids. Only the Footer's `summary_start` moves for such a splice: the record sits after every
chunk so no index offset changes, and before the summary so `summary_crc` still covers the same
bytes.

The result, on `main` as of this writing:

```
streamed:  tracks seen: [7]   centre of gaussian 0 near t=duration: [99.999975  0.  0.]
indexed:   tracks seen: []    (table seen: 1 entry)    index entries: 1
validator: ok = True, no findings
```

Both paths report `summaryCrcOk: True`, and `fourdgs.validate` returns a clean report. One legal
file, one hundred units of disagreement about where a gaussian is, and no diagnostic anywhere. The
Object Table, which stayed in front matter, was seen by both — so this is not "indexed reads drop
the object layer", it is "indexed reads drop whatever sits past the first chunk", which is worse
because it is positional rather than categorical.

This is what makes #78 a format question rather than a bug. Fixing any one SDK would create
precisely the divergence [AGENTS.md §8](https://github.com/avala-ai/4dgs/blob/main/AGENTS.md)
forbids: implementations "may not differ in what they decode a file to mean".

### 2.3 Nothing in the corpus reaches it

No committed variant writes a family record after a chunk. The reference writer cannot produce one:
`python/fourdgs/fourdgs/writer.py:516-541` emits provenance and then the object layer, both before
the first chunk is written. The validator checks record position only for audio
(`python/fourdgs/fourdgs/validate.py:246` and `:291`). So the suite is green with the two read paths
capable of disagreeing, and would stay green whichever way this is decided — which is why the answer
needs a variant and not only a paragraph.

---

## 3. The options

### (a) A producer rule — indexed front matter MUST precede the first Chunk

Indexed readers keep stopping at the first `Chunk`; writers are forbidden from putting anything that
walk collects behind it. The rule covers legacy Audio, Camera, Metadata, Attachment, Audio
Source/Data pairs and the provenance family. Header, Quantization and Window Table already have
their own stronger placement requirements.

- **Cost to producers:** none that can be measured. Every writer in this repository already
  complies, and the rule is what §5.15.1 already says these records do.
- **Cost to readers:** none. It removes an obligation rather than adding one.
- **What it forbids:** a shape that is currently legal. See §7 for exactly which files that is.
- **Enforcement is asymmetric, and that is the design.** A streamed reader can detect a violation
  for free — it has already passed a chunk — so it refuses. An indexed reader cannot detect one
  without the scan the rule exists to avoid, so it is explicitly not required to. Both paths then
  agree on every conforming file, and the path that can name the fault does.

### (b) A reader obligation — indexed opens must find them wherever they sit

- **Cost:** an indexed open no longer costs a bounded read from the front plus the tail. To find a
  record that may sit anywhere before `summary_start`, a reader must walk the record chain across
  the chunks — and the chain is a linked list of lengths, so it cannot be jumped. Over a range
  transport that is one round trip per record, on the path whose defining property (AGENTS.md §2,
  §1) is that it "touch[es] only what an instant needs" in bounded memory.
- It also makes `bytes_for_time` (`indexed_reader.py:180`) a lie, since opening now costs an
  unpredictable amount that no caller can budget before asking.
- The one thing in its favour: it keeps every legal file legal. That is not enough. The property it
  preserves is the legality of files that do not exist, and the property it destroys is the reason
  the indexed path exists at all.

### (c) Index the late records

Give a reader an O(1) way to find them, so both properties survive.

- **The Chunk Index (`0x08`) is the wrong home.** It is one entry per chunk, and these are not
  per-chunk records. Appending "and also, unrelated front matter lives at N" to a frozen per-chunk
  record (§4.4) spends the append budget of the index on something that has nothing to do with
  chunks.
- **Summary Offset (`0x0F`) is closer, and could be extended.** Its body is
  `group_opcode, group_start, group_length` — one **contiguous run** of one opcode class — but the
  wire permits repeatable Summary Offset records and does not require `group_opcode` to be unique.
  Option (c) could define one entry per run, including multiple entries for the same opcode, without
  allocating a new opcode. That is a compatible extension of a provisional record, not something
  current readers implement: they would still need to retain every entry, define overlap and
  disagreement handling, and distinguish a complete list from an incomplete one.
- A dedicated front-matter index at reserved `0x0E` remains another design, not a prerequisite.
  Either representation needs six implementations, a variant for repeated runs, and a rule for an
  index that disagrees with the records (the Chunk Index precedent, §5.8, is "refuse, naming the
  field"). A new record is therefore avoidable; the cross-SDK discovery semantics are not.
- And it does not finish the job: the index is optional, so a file may still carry a late record
  with no entry for it, and (c) still needs (a)'s rule for that case. The most expensive option ends
  by needing the cheapest one anyway.

---

## 4. Recommendation

**Adopt (a): every record the indexed front walk collects MUST appear before the first `Chunk`.**

Four reasons, in the order they should be weighed.

1. **It is the rule the format already made for the identical problem.** §5.17 constrains Audio
   Source and Audio Data to the same position, for the same reason, in the same words — "so an
   indexed reader can frame every source and range-read its encoded bytes without fetching a
   gaussian chunk". A second family with the same discovery mechanism and the same indexed-path
   consequence should not get the opposite answer because it was written down later.

2. **It is what §5.15.1 already asserts.** "They belong with the other content records ahead of the
   chunks." Adopting (a) turns an assertion about where they belong into a rule about where they may
   be. That is a clarification with teeth, not a new policy.

3. **It costs nothing that exists.** No file in the corpus, no output of any writer here, and no
   documented producer shape is affected. §7 states this precisely, because "makes currently-legal
   files illegal" is true in the abstract and empty in the particular, and the difference is the
   whole decision.

4. **The alternatives trade a real property for a hypothetical one.** (b) spends the indexed path's
   defining guarantee to preserve files nobody writes. (c) can reuse repeatable Summary Offset
   records rather than spend an opcode, but still costs six implementations, completeness and
   disagreement rules, and still needs (a) for a late record omitted from that optional index.

The honest counter-argument is that (a) is a **tightening**, and §10's version rules do not list
"forbid a shape that was previously legal" among the additive changes. That is right, and it is why
this proposal states the affected set rather than waving at it: the tightening is of the same kind
and size as the two already recorded in [§13's changelog](../index.md#13-changelog) — §4.5's "no
other record inside the summary run" and §5.3's "every quantization step MUST be finite" — both of
which forbid shapes no encoder produced, and both of which regenerated nothing.

---

## 5. The normative text

Written as spec prose, ready to lift.

### 5.1 Into §5.15, after the "dispatched by opcode, not by position" paragraph

> **Every record in this family MUST appear before the first `Chunk` record.** Position within the
> family is still free — the dispatch above is by opcode, and a reader MUST NOT depend on the order
> these records arrive in — but the family as a whole is front matter, and front matter ends at the
> first chunk.
>
> The rule exists for the indexed path and is the same one §5.17 states for audio. An indexed reader
> frames the front matter with a bounded read from the start of the file and then reads the index; a
> record it must not miss cannot be somewhere that walk does not reach, because reaching it means
> walking the record chain across every chunk, which is the cost the indexed path exists to avoid.
> With the object layer the consequence is not confined to metadata: an Object Track (§5.15.7)
> changes where gaussians are (§3), so a track a reader cannot see is a scene in the wrong place
> rather than a description it lacks.
>
> **A reader that encounters a defined provenance-family record (`0x20`–`0x25`) after the first
> `Chunk` MUST refuse the file**, naming the opcode and its byte offset. An opcode the reader does
> not recognize is still skipped under §4.2; position cannot turn an unknown record into a known
> refusal rule. A future definition in the reserved `0x26`–`0x2F` range inherits the producer rule
> and states its corresponding reader check when it becomes known. A streamed reader detects a
> violation for free, because it has already passed a chunk. **An indexed reader MAY stop framing
> front matter at the first `Chunk` and is not required to detect the violation**: the two paths
> then agree on every conforming file, and the path that can name the fault at no cost is the one
> required to.
>
> This is a rule about a writer's output, not a new capability. A file that satisfies it is
> byte-identical to the file it would otherwise have been.

### 5.2 Into §5.15.1, replacing the last paragraph's final sentence

> **These are not summary records** (§4.5). They carry content, and trajectories are unbounded — a
> ten-minute capture logged at 100 Hz is sixty thousand samples. They belong with the other content
> records ahead of the chunks, for exactly the reason attachments do, and §5.15 makes that position
> normative rather than customary.

### 5.3 Into §4, under the layout diagram

Replace:

> Order is normative only where stated: the Header MUST be the first record, the Footer MUST be the
> last, and the summary MUST be contiguous (§4.5).

with:

> Order is normative only where stated: the Header MUST be the first record, the Footer MUST be the
> last, the summary MUST be contiguous (§4.5), and legacy Audio, Camera, Metadata, Attachment, every
> Audio Source and Audio Data pair (§5.17), and every provenance-family record (§5.15) MUST precede
> the first `Chunk`. Records not constrained here or in their own sections retain free placement,
> and a reader MUST NOT depend on their position.
>
> A reader that encounters any of those defined records after the first `Chunk` MUST refuse it,
> naming the opcode and byte offset. This does not override §4.2 for an opcode the reader does not
> recognize: unknown records are skipped until a specification defines both their meaning and any
> positional check.

### 5.4 Into §13's changelog table

| Change                                                                                                                                   | Kind       |
| ---------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| §4/§5.15 added: every record collected by the indexed front walk MUST precede the first `Chunk`, matching §5.17's Audio Source/Data rule | rule added |

---

## 6. The conformance variant that pins it

One variant, in `data/invalid/`, because after this proposal the file is not a legal file.

- **`LateProvenance`** — a well-formed scene carrying an `object_id` stream, an Object Table in
  front matter, and one Object Track record spliced between the last `Chunk` and the first
  `Chunk Index`, with `summary_start` adjusted. Every other byte is a conforming file: the index is
  correct, the summary CRC is correct, and both read paths currently open it without complaint.
- **What it asserts:** a streamed decode MUST refuse, naming opcode `0x25` and the record's byte
  offset. It joins the seven files already in `data/invalid/`, which are all single-value refusals —
  a bad magic, an unknown scheme, a window index out of range — so a record-position refusal is a
  new shape for that directory rather than a variation on one already there.
- **The rest of the positional family is independently pinned.** Add `LateLegacyAudio`,
  `LateCamera`, `LateMetadata`, `LateAttachment` and `LateAudioSource` using the same splice. One
  provenance example cannot prove the branches for unrelated legacy opcodes, and §5.17's existing
  Audio Source rule currently has no variant either. Each expectation names its opcode and offset;
  `LateAudioSource` closes the pre-existing §5.17 gap while the other four prevent this proposal
  from documenting a broader rule than the suite proves.
- **Why an invalid variant and not a valid one:** a valid variant can only assert that the two paths
  agree, and under this proposal they agree because the file cannot exist. The thing worth pinning
  is the refusal — without it, an implementation that keeps today's silent behaviour passes.
- **Second variant, optional:** `LateProvenanceIndexed`, the same bytes asserted against the indexed
  runner, expecting a **skip** rather than a refusal. It pins the asymmetry deliberately, so that a
  later implementer who "fixes" the indexed reader by scanning the whole file fails a test that says
  why. Whether the harness should encode "this runner is allowed to accept what that runner refuses"
  is a question for whoever writes it; the rule stands either way.

Neither variant regenerates anything. The corpus gains files; nothing existing moves.

---

## 7. What becomes illegal, precisely

The proposal's instruction is to say plainly which files this breaks, so:

**Files that become illegal:** any file carrying legacy Audio, Camera, Metadata, Attachment, Audio
Source/Data, or a record with an opcode in `0x20`–`0x2F` at a byte offset after the first `Chunk`
record.

**Files known to be in that set:** none.

- No conformance variant. All 60 `.4dgs` files the generator produces — top-level, `object/`,
  `keyframe/` and `invalid/` alike — were framed record by record and none carries a `0x20`–`0x2F`
  opcode after the first `Chunk` or `Delta Chunk`. (Two files in the invalid set cannot be framed at
  all, by design; neither is a counter-example.)
- No output of `fourdgs.write`: `writer.py:516-541` emits provenance and the object layer before the
  chunk loop, and there is no option that reorders them.
- No output of the Rust, TypeScript or Dart writers, which follow the same order.
- No third-party producer this project knows of. The records were defined in the same revision that
  shipped the reference writer, and every reader in this repository has been unable to see a late
  one since the day they were defined — so a producer that wrote one would have been shipping files
  its own indexed reader silently ignored.

**What is genuinely lost:** the abstract permission. A future producer that wanted to append a
Coordinate Frame to an already-written file without rewriting it must now rewrite the front matter,
or carry the information in a Metadata record or an Attachment. That is a real constraint and it is
the price. It is the same price §5.17 already charged for audio, and the same one §4.5 charged for
attachments.

---

## 8. Claims in #78 this proposal could not confirm as written

Every claim was checked against the code; two need correcting and one needs sharpening.

- **"All five implementations behave identically."** There are four native indexed readers (Python,
  Rust, TypeScript, Dart). C++ and Swift bind the Rust core through the C ABI and have no
  front-matter walk of their own, so they cannot differ. The conclusion — no SDK can be fixed alone
  — holds, and holds more strongly, since fixing Rust would move C++ and Swift with it.
- **"The result is that [...] indexed reads return neither."** Correct for a record placed after a
  chunk, and only for that record. In the demonstration above the Object Table, written in front
  matter, was returned by both paths; only the spliced track was missed. The defect is positional,
  not categorical, which matters when writing the variant: a file that puts the whole layer late and
  a file that puts one record late fail differently.
- **"Costs a tail scan"** (of option (b)). Not a tail scan: `summary_start` bounds the region but
  the records inside it can only be found by walking the chain forward from the front, because a
  record's position is only known from the previous record's length. The cost is a full forward walk
  over every chunk header, not a read of the tail. This makes (b) worse than the issue states, not
  better.

---

## 9. Deliberately not decided here

- **Whether the still-reserved `0x26`–`0x2F` (§5.15.8) inherit the producer rule.** They do: a
  future writer using that family keeps them before chunks unless their defining proposal moves them
  to a different family. An older reader still skips an unknown opcode wherever it appears under
  §4.2; only once an opcode is defined can a reader recognize it and enforce its positional refusal.
  This distinction keeps forward-compatible skipping and the producer layout rule from contradicting
  one another.
- **Whether a front-matter index is worth having anyway**, independently of this question, for files
  with very large front matter. Option (c)'s machinery has a use — an indexed open that wants one
  sensor out of two hundred still frames all two hundred today — and that is a legitimate proposal.
  It is not this one, and it should not be a prerequisite for closing #78.
- **Whether `0x0E` should be spent on it.** §5.13 keeps `0x0E` reserved with no defined body, and
  this proposal does not touch it.
