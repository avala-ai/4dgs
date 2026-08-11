# Cross-SDK design principles

Rules every implementation in this repository follows, whatever the language. They exist so that
four SDKs behave like one format rather than four interpretations of it.

**Throughput (parallel agents / multi-language work):** read **[SPEED.md](SPEED.md)** — blast
radius, one language lane per writer, **one `git worktree` per concurrent writer**, atomic
commits. Complements §9 (one language per PR, stacked); does not replace it.

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
- **Retargeting is _not_ reliably automatic**, and you cannot fix it from the CLI. When the bottom
  PR merges, the one above it is supposed to re-target onto `main` by itself. It may not — see "When
  the retarget does not happen" below, which is a recovery procedure written from a real incident
  rather than from the documentation.
- **Branch protection and CI apply to every PR in the stack**, so a red check on layer three is not
  excused by a green one on layer one.
- **All branches must live in this repository.** Cross-fork stacks are not supported, which means a
  contributor working from a fork opens ordinary sequential PRs instead — that is fine, and nothing
  below is a requirement for outside contributions.

With the [`gh stack`](https://docs.github.com/en/pull-requests/reference/stacked-prs-cli-commands)
extension (`gh extension install github/gh-stack`):

```sh
# Every command here is in its non-interactive form, and each flag is there for a
# reason: bare `init` prompts for a branch name, `submit` opens a full-screen editor,
# `view` pages through `less`, and `sync` asks before pruning merged branches. Any one
# of them blocks an agent or a scripted shell. Typing them by hand, drop the flags.
gh stack init typescript/provenance --base main
gh stack add typescript/objects    # next layer, on top of the current one
gh stack submit --auto             # push every branch, open/update the PRs, no editor
gh stack view --json               # see the stack; bare `view` pages through `less`
gh stack sync --prune              # after a merge below you: fetch, rebase, push
gh stack link 74 75                # adopt a stack that was built by hand
```

Without the extension, the same shape is two ordinary commands — branch from the layer below, and
pass `--base` when opening the PR:

```sh
git checkout -b dart/objects typescript/objects
git push -u origin dart/objects
# `--fill` takes the title and body from the commits. Without it — and without an
# already-pushed branch — `gh pr create` prompts, which blocks an agent just as
# bare `gh stack init` does.
gh pr create --base typescript/objects --fill
```

That gives the thing that matters most — each diff shows one layer — and the base chain is what
makes the PRs merge in order. It does **not** make GitHub treat them as a stack: the stack map, the
banner and the cascading rebase appear only once the pull requests are linked, with `gh stack link`
or by confirming GitHub's recommendation banner. Until then it is a branch chain that reviews well,
not a stack.

**Rebasing the stack after the layer below merges.** This is the part that bites. GitHub
squash-merges, so when the bottom PR lands, its commits do not exist on `main` — one new commit
does, carrying the same content under a different hash. GitHub then retargets the next PR onto
`main`, and that PR immediately shows **conflicts**, because its branch still contains the originals
of everything the squash flattened.

With the extension, this is what `rebase` is for — check the stack out, replay it, push:

```sh
gh stack checkout 74        # the stack containing the PR you were told is conflicting
gh stack rebase             # replay every layer on the new base
# fix conflicts, `git add`, then `gh stack rebase --continue` — not plain
# `git rebase --continue`, which resumes only the rebase in front of you and
# leaves the extension without the bookkeeping it needs to carry on up the stack
gh stack push               # force-push each branch with lease
```

Without the extension, do not run a bare `git rebase main`: it tries to replay the merged layer's
commits on top of a `main` that already has their content, and every one of them conflicts. Replay
only the commits this layer owns, by naming the **old base tip** as the fork point:

```sh
# `d5199b6` is what the layer below pointed at before it merged — its final head, which
# `git reflog <branch>` or the merged PR's last commit will tell you. Everything after it
# is this layer's own work.
git rebase --onto origin/main d5199b6 feat/parity-objects-ts
git push --force-with-lease origin feat/parity-objects-ts
```

Then restack each layer above onto the one below, the same way, passing that layer's previous base
tip. **Count the commits before you push.** A wrong fork point silently produces a branch with zero
commits of its own, and force-pushing that empties the PR — GitHub closes it as an empty diff:

```sh
# Against the branch you rebased ONTO, never the branch you are on: `A..B` is what B has
# and A does not, so naming the current branch on both sides always answers zero — for a
# healthy branch and an emptied one alike.
git log --oneline origin/main..HEAD | wc -l              # bottom layer, now based on main
git log --oneline feat/parity-objects-ts..HEAD | wc -l   # a layer above, from its parent
```

**When the retarget does not happen.** Observed on 2026-08-02, with #92/#93/#94: the bottom PR
merged and the next one kept pointing at the merged branch. Everything you would reach for first
makes it worse, so the order below matters.

The symptom is a diff that suddenly grows. The child PR's base branch still points at the layer's
pre-squash commits while its head has been rebased onto `main`, so GitHub diffs across the squash
and shows the layer below as part of this PR — #93 jumped from 14 files to 22 without a single
source change.

What does **not** work, both confirmed the hard way:

```sh
# 1. Retargeting through the API or the CLI. Refused for any PR that is part of a stack —
#    top or bottom, and still refused after the layer below has merged.
gh pr edit 93 --base main
gh api -X PATCH repos/OWNER/REPO/pulls/93 -f base=main
#    422 Validation Failed — "Cannot change the base branch because the pull request is
#    part of a stack."

# 2. Deleting the merged base branch to force a retarget. GitHub CLOSES the child PR.
gh api -X DELETE repos/OWNER/REPO/git/refs/heads/feat/objects-rust-abi
#    #93 went to CLOSED, base unchanged, diff still wrong.
```

Recovery, in order:

```sh
# Keep a rescue ref BEFORE touching any branch — deleting a ref you cannot name again is
# the one mistake here with no cheap undo.
git branch -f rescue/objects-rust-abi 9d3756477a

# If a PR was closed by a branch deletion: recreate the ref, then reopen. Both survive.
gh api -X POST repos/OWNER/REPO/git/refs -f ref=refs/heads/feat/objects-rust-abi -f sha=9d37564...
gh pr reopen 93

# Point the stale base branch at main so the diff is readable again while you decide.
gh api -X PATCH repos/OWNER/REPO/git/refs/heads/feat/objects-rust-abi \
  -f sha=$(git rev-parse origin/main) -F force=true
```

Then pick one, because the base ref must end up as `main` before the PR can merge there:

- **In the web UI: unstack the PR, then change its base.** The UI permits what the API refuses. This
  is the cheapest route and it keeps the PR number and its whole review history.
- **Or replace the PR**: close it, and open a new one from the same (already rebased) head branch
  with `--base main`. Guaranteed to work, and what to do when nobody can reach the UI — at the cost
  of a new number, with the review thread left behind on the closed PR. Link the two in both
  directions so the history is followable.

Note that `gh` has no built-in `stack` command — 2.63 does not, at least. The `gh stack …` lines
GitHub shows in the "resolve conflicts" box come from the extension above, and if it is not
installed those instructions are dead ends. Check with `gh stack --help` before quoting them to
anyone.

**What does not belong in a stack.** A stack is for changes that genuinely depend on each other. Two
unrelated fixes stacked together inherit each other's review latency and each other's red CI for no
reason — open those side by side off `main`.

Everything else about pull requests — title prefixes, the scope checkbox, the conformance gate — is
in [CONTRIBUTING.md](CONTRIBUTING.md#pull-requests).
