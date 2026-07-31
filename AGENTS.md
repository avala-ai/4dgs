# Cross-SDK design principles

Rules every implementation in this repository follows, whatever the language. They exist so that
four SDKs behave like one format rather than four interpretations of it.

## 1. Bounded memory, always

No implementation ever buffers a whole file. The index is small, chunks are independent, and every
stream declares its decoded size before it is decoded. If an API can only work by reading everything
first, that API is wrong.

Concretely: no `readAll()` in a decode path, no unbounded accumulation across chunks, and every
allocation sized from a value the reader has already validated.

## 2. Decode is streamable and range-seekable

Two modes, both supported: front-to-back streaming that works on a pipe or a truncated file, and
indexed reads that touch only what an instant needs. Neither is an optimization of the other; they
serve different consumers and both are first-class.

## 3. I/O lives at the edges

The core of every SDK depends on one abstraction — something that can report its size and read a
byte range — and nothing else. No HTTP client, no filesystem, no platform types in the core.
Transports are separate, small, and swappable: a file handle, an HTTP range reader, an in-memory
buffer, a cache.

This is what lets the same decoder run in a browser, on a server, and in a test with a byte array,
and it is what keeps the core testable without a network.

## 4. Decoders are fast; the encoder is a reference

**Decoders should be genuinely fast**, using ordinary, well-understood techniques: typed arrays
rather than object arrays, views rather than copies where the language allows, worker- and
thread-friendly APIs, buffer reuse, streaming. A slow decoder misrepresents the format.

**The reference encoder optimizes for clarity and correctness**, not for output size or throughput.
It produces conforming files that are easy to reason about. Rate and quality heuristics are where
encoders differentiate, and this repository is not where that competition happens.

## 5. Decode ends at gaussian state

**Decoding ends at reconstructed gaussian state at time `t`. The format is renderer-agnostic;
rendering strategy is out of scope for this repository.**

Nothing here — code, comments, documentation, tests — describes how a renderer should consume that
state: no ordering or sorting strategy, no culling, no level-of-detail policy, no device tiering, no
budget management, no GPU or shader code. Those belong to whatever draws the splats, which is
somebody else's repository, including ours.

## 6. Errors name the problem

A decoder that refuses a file says which byte, which record, which value, and what was expected.
Implementations parse untrusted bytes; a bare exception type is not a diagnosis. Unknown-but-legal
values (an unrecognized codec, a future record type) are distinguished in the error message from
malformed ones, because the fix is different.

## 7. One vocabulary

The nouns in `website/docs/guides/concepts.md` are the nouns every SDK uses, in identifiers and in
messages. Where a language's conventions differ (casing, naming style), follow the language; do not
rename the concept.

## 8. Conformance is the contract

An SDK claims a feature by passing the conformance suite for it, and the feature matrix records only
what the suite proves. Implementations may differ in structure, API shape and performance; they may
not differ in what they decode a file to mean.

## 9. One language per pull request, stacked

A feature that lands in four SDKs is four pull requests, not one. Principle 8 is why: each SDK
claims a feature by passing the suite for it, and a reviewer can only check that claim against a
diff they can hold in their head. A single PR touching Python, Rust, TypeScript and Dart hides four
independent claims behind one approval.

So when work naturally continues across SDKs, **stack the pull requests** rather than batching them
or waiting for each to merge. Each PR targets the branch below it, so every diff shows only that
language's change.

GitHub supports this directly — see
[About stacked pull requests](https://docs.github.com/en/pull-requests/get-started/about-stacked-prs).
The mechanics that matter here:

- **Merge order is bottom-up.** GitHub enforces it, and it is also the order the work depends in:
  the corpus and the harness change once, at the bottom, and each language above it proves itself
  against that same corpus.
- **Retargeting is automatic.** When the bottom PR merges, the ones above it re-target the base
  branch on their own. Do not hand-edit base branches to chase a merge.
- **Branch protection and CI apply to every PR in the stack**, so a red check on layer three is not
  excused by a green one on layer one.
- **All branches must live in this repository.** Cross-fork stacks are not supported, which means a
  contributor working from a fork opens ordinary sequential PRs instead — that is fine, and nothing
  below is a requirement for outside contributions.

With the [`gh stack`](https://docs.github.com/en/pull-requests/reference/stacked-prs-cli-commands)
extension (`gh extension install github/gh-stack`):

```sh
gh stack init                      # start a stack on the current branch
gh stack add typescript/objects    # next layer, on top of the current one
gh stack submit                    # push every branch and open or update the PRs
gh stack view                      # see the stack and where you are in it
gh stack sync                      # after a merge below you: fetch, rebase, push
```

Without the extension, the same shape is three ordinary commands — branch from the layer below and
pass `--base` when opening the PR:

```sh
git checkout -b dart/objects typescript/objects
gh pr create --base typescript/objects
gh stack link 74 75                # optional: link existing PRs into a stack on GitHub
```

**What does not belong in a stack.** A stack is for changes that genuinely depend on each other. Two
unrelated fixes stacked together inherit each other's review latency and each other's red CI for no
reason — open those side by side off `main`.

Everything else about pull requests — title prefixes, the scope checkbox, the conformance gate — is
in [CONTRIBUTING.md](CONTRIBUTING.md#pull-requests).
