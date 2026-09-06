# Decision: aggregate decoded-state budgets

**Status: adopted shared reader contract.** The normative rule is
[specification §3.3](../index.md#33-aggregate-decoded-state-resource-budgets), the stable result is
in the [registry](../registry.md#reader-result-categories), and the executable capability gate is
part of the [runner protocol](../../reference/conformance.md#aggregate-decoded-budget-gate). This
decision changes no `.4dgs` byte and creates no invalid-corpus variant.

This record resolves the aggregate-memory question in
[#303](https://github.com/avala-ai/4dgs/issues/303). It remains here because the normative text says
what every reader owes, while this page records why, identifies today's affected APIs, and gives
each SDK layer a bounded implementation target.

---

## 1. The unanswered question

Every state record declares its decoded size before allocation, but several convenience APIs retain
many individually bounded results. A million legal small chunks are not made safe by proving each
chunk is small. Their sum can exhaust the process even though no record is malformed.

The distinction is between transport and ownership:

- A function may read front to back in bounded blocks and still return one object containing every
  decoded chunk. That function is **collecting**.
- An iterator or callback that yields a chunk and then lets the library release it is **streaming**.
- A seek or composition call that retains only the requested state and the reference/workspace
  needed to build it is **current-reference**.

Only the first accumulates a decoded history by contract. Calling its input path “streamed” does not
change the memory its output owns.

## 2. Evidence in the current SDKs

The audit was performed against the public surfaces on `origin/main` at the time this decision
landed. “Bounded” here means an aggregate decoded-state ceiling, not the separate per-record,
front-matter, summary, or identity-cardinality ceilings an SDK may already have.

| SDK        | Collecting surfaces today                                                                                                                        | Existing aggregate behaviour                                                                                                   | Incremental/current-reference surface                                           |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------- |
| Python     | `stream_reader.read`; `keyframe_delta_file.decode_streamed` / `decode_indexed`                                                                   | No aggregate decoded-state budget. `ExceedsReaderLimit` already names other legal reader ceilings.                             | `indexed_reader.read_chunk`; `compose_chain`; validator scans                   |
| TypeScript | `decodeScene`; `decodeKeyframeDeltaStreamed` / `decodeKeyframeDeltaIndexed`                                                                      | No aggregate decoded-state budget. `ExceedsReaderLimit` already names other legal reader ceilings.                             | `IndexedDecoder.readChunk` / instant reads                                      |
| Dart       | `readFourdgsBytes`; `decodeKeyframeDeltaStreamed` / `decodeKeyframeDeltaIndexed`                                                                 | No aggregate history budget. `FourdgsReaderLimit` already names per-state and other legal reader ceilings.                     | `readFourdgsChunk`; `readKeyframeDeltaChain`                                    |
| Rust       | `stream_reader::read_from` / `read_bytes` / `read_path`; sequential `SceneReader::open_with`; `keyframe_delta_file::decode_streamed` / `indexed` | Gaussian-birth uses a fixed `MAX_DECODED_SCENE_BYTES = 512 MiB`; keyframe-delta collectors do not bound the retained sequence. | Indexed chunk/instant reads; keyframe-delta `compose_chain` and validator scans |
| C          | sequential/auto `fourdgs_open_*`; `fourdgs_scene_load_all`; `fourdgs_keyframe_delta_states_json`                                                 | Inherits the Rust fixed ceiling where that core applies; resource failures currently collapse into unsupported mode.           | `fourdgs_scene_load_chunk` / `load_at`                                          |
| C++        | streamed/auto `Scene::open*`; `Scene::loadAll`; `keyframeDeltaStatesJson`                                                                        | Inherits the Rust C ABI and has no configurable aggregate option or dedicated result code.                                     | `Scene::loadChunk` / `loadAt` / `stateAt`                                       |
| Swift      | streamed/automatic `SceneReader.init`; `SceneReader.allGaussians`; `keyframeDeltaStatesJson`                                                     | Inherits the Rust C ABI and has no configurable aggregate option or dedicated error case.                                      | `SceneReader.chunk` / `loadedGaussians(at:)` / `gaussians(at:)`                 |

The Rust constant is useful prior art rather than an arbitrary new number. It is already shipped as
the production core's scene ceiling and is the same 512 MiB value used for decoded stream working
sets across the repository. Making it the shared default aligns existing safe behaviour without
claiming that every caller has the same amount of memory.

## 3. What is counted

The normative boundary is peak simultaneous **library-owned decoded state plus its working
storage**, not file size and not a count of gaussians. It includes:

- capacity retained for the collecting result, including all composed keyframe-delta states;
- a keyframe or reference state while an output state is being composed;
- decompressed state-record bodies, decoded integer bins, decoded attribute streams, and temporary
  assembly buffers while they coexist with retained state; and
- copies made by the library while growing or assembling the result.

It excludes encoded source bytes and range-cache contents, parsed Header/front-matter/summary
objects, encoded audio and attachment payloads, and values a streaming API has yielded into caller
ownership. Those resources keep their own declared bounds. Implementations count at least element
capacity at the representation's actual widths; they may conservatively add container and allocator
overhead. The gate deliberately does not require byte-identical allocator accounting across
languages.

The check happens before the allocation or retention that would cross the ceiling. Exactly the
configured number of bytes is allowed. Checked-size arithmetic that cannot represent the next total
has the same `resource-limit` outcome rather than wrapping or attempting an allocation.

## 4. Configuration and default

Every public collecting API exposes a positive integer maximum:

- `max_decoded_state_bytes` in Python, Rust, and C;
- `maxDecodedStateBytes` in TypeScript, Dart, C++, and Swift.

The omitted value is **536,870,912 bytes (512 MiB)** everywhere. A non-positive, non-integral, or
non-finite value is a caller argument error; it says nothing about a file. APIs whose current public
signature cannot grow compatibly add an options-bearing overload or suffixed entry point, and keep
the old entry point as a wrapper that supplies the shared default. In particular, no frozen C
function or C++ binary interface is silently changed in place.

The language layers apply that option to every collector named in §2. Python adds the keyword to its
three collecting functions. TypeScript extends `DecodeOptions` and adds an options-bearing
keyframe-delta overload; Dart adds named parameters. Rust extends `ReadOptions`, adds an
options-bearing `SceneReader` open and keyframe-delta decode variants, and keeps its convenience
wrappers on the default. The C ABI appends options-bearing open/load/keyframe-delta functions whose
`uint64_t max_decoded_state_bytes` reaches the core; existing symbols remain default wrappers. C++
adds overloads taking its options value. Swift accepts its `DecodeOptions.maxDecodedStateBytes` at
reader initialization as well as later collecting calls, because a streamed reader has already
collected its state by the time `allGaussians` is called. These are compatibility constraints on the
language changes, not extra wire-format fields.

The option does not turn a collecting API into a streaming one. It makes the cost it already incurs
finite and caller-controlled. Conversely, an incremental API does not debit a state after yielding
or releasing it. Its peak current state, reference, and workspace remain bounded by the existing
per-operation rules.

## 5. One category across the SDK surfaces

The portable category is `resource-limit`. Existing source-compatible names remain valid; SDKs that
currently collapse resource exhaustion into an unrelated mode error add the mappings below.

| Surface    | Required public result                                                                                                                      |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Python     | `ExceedsReaderLimit`                                                                                                                        |
| TypeScript | `ExceedsReaderLimit`                                                                                                                        |
| Dart       | `FourdgsReaderLimit`                                                                                                                        |
| Rust       | `Error::ResourceLimit`                                                                                                                      |
| C          | append `FOURDGS_STATUS_RESOURCE_LIMIT = 10`; existing numeric values do not move                                                            |
| C++        | append `ErrorCode::kResourceLimit = 12`; existing numeric values do not move                                                                |
| Swift      | add `FourDGSError.resourceLimit(message:)`; map the appended C status explicitly rather than falling through to `.core` or unsupported mode |

A diagnostic names the `decoded-state` resource, the configured limit, and the collection or
composition phase. It should include the next required or minimum peak byte count when that count is
known. It does **not** need a state-record byte attribution: the resource is legal, and another
reader or another configured limit can consume the same bytes. It carries no refusal identifier.

The distinction from `UnsupportedOperation` / `kUnsupportedMode` is intentional. Those mean that a
request belongs to a different read path; `resource-limit` means the requested operation exists but
the selected resource budget cannot complete it.

## 6. Conformance without a huge file

A giant fixture would test the host more than the API and would violate the corpus size ceiling. The
runner protocol instead uses dependency injection:

1. A runner claims `"aggregateDecodedBudget": true` in its capabilities object only after both its
   public collecting decoder and its runner adapter expose the budget.
2. The harness invokes that runner once with
   `--max-decoded-state-bytes 1 <OneGaussian-UseChunkIndex-UseCrc.4dgs>`.
3. The runner passes the one-byte limit into the collecting API. One decoded gaussian necessarily
   exceeds it, so a correct implementation prints exactly `{"unsupported":"resource-limit"}` and
   exits zero.
4. The ordinary corpus invocation, with no injected limit, still decodes the same file under the 512
   MiB default.

The one-byte probe is below every conforming decoded representation even if SDKs count container
overhead differently. It proves option plumbing, pre-allocation enforcement, and public error
classification with an existing tiny valid file. It makes no file invalid, adds no expectation to
`data/invalid/`, and adds no generated or committed corpus artifact.

## 7. Decisions and rejected alternatives

| Question                                      | Decision                                   | Why                                                                                      |
| --------------------------------------------- | ------------------------------------------ | ---------------------------------------------------------------------------------------- |
| Is aggregate exhaustion malformed?            | No; registered `resource-limit` result     | The same conforming file succeeds with a larger ceiling or incremental API               |
| Shared default                                | 512 MiB                                    | Existing Rust production-core precedent; finite and already exercised                    |
| What carries configuration?                   | Every collecting public API                | A hidden process constant is bounded but not caller-controllable                         |
| Do incremental calls accumulate prior yields? | No                                         | Released/library-unowned values are outside their working set                            |
| Count encoded input/front matter?             | No                                         | They are separate resources with separate bounds                                         |
| Conformance evidence                          | One-gaussian injected one-byte probe       | Deterministic across representations; no large fixture                                   |
| Reuse invalid corpus `refused` output?        | No; use `{"unsupported":"resource-limit"}` | Resource availability is neither malformed bytes nor a format refusal                    |
| Reuse unsupported mode?                       | No                                         | A supported collector over budget is not a request sent to the wrong path                |
| Set a wire-format maximum?                    | No                                         | Would turn machine/application policy into file validity and reject streamable resources |

## 8. Delivery order

This shared contract lands first. Each SDK then adds its own option, accounting, result mapping,
focused one-byte test, and runner capability in a language-only change. The feature-matrix row moves
from `Planned` only when that SDK's runner passes the injected gate on both read paths it claims.
