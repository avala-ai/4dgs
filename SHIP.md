# SHIP.md — Throughput without quality debt

**Audience:** humans and coding agents shipping in this repository.

**Purpose:** raise *landed, correct* change rate via parallel work and tight feedback
loops — without weakening [`AGENTS.md`](AGENTS.md) (cross-SDK principles),
[`CONTRIBUTING.md`](CONTRIBUTING.md), or conformance.

**Not a goal:** commit count, token spend, or “vibe” volume. Those are lagging noise.
Optimize for **green PRs merged per week** and **time from idea → first green CI**.

Companion to the Avala monorepo’s `SHIP.md` (same discipline, this repo’s lanes).

---

## 1. Relationship to the other root docs

| Doc | Job |
|-----|-----|
| [`AGENTS.md`](AGENTS.md) | Cross-SDK design principles + **one language per PR, stacked** |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | How to contribute |
| [`RELEASING.md`](RELEASING.md) | Release process per language |
| **This file** | How to *structure work* so many agents ship in parallel without thrashing |

Read this when you are about to open a multi-file change, spawn parallel agents, or feel
the PR is growing into a review-hostile blob. Skip it for one-line fixes.

**Already load-bearing here:** AGENTS.md §9 — *one language per pull request, stacked*.
SHIP does not replace that; it adds blast radius, worktrees, and commit rhythm around it.

---

## 2. Blast radius (size the work first)

Before editing, name the blast radius out loud (or in the agent prompt):

| Size | Typical scope | Parallel? |
|------|---------------|-----------|
| **Tiny** | 1–3 files, one concern, &lt;~150 LOC | Alone or as a satellite next to a hard task |
| **Medium** | One language SDK / one package | One agent or one PR |
| **Large** | Spec/corpus change + N language SDKs | **Stack** (corpus bottom → languages) — never one mega-PR |
| **Dangerous** | Format semantics, conformance meaning, hostile-input decode paths | Serial review; no parallel writers on the same claim |

Rules:

1. Prefer **many tiny/medium PRs** over one fat PR reviewers cannot hold in their head.
2. If an agent run exceeds the expected radius (touches a second language “while here”),
   **stop**, re-scope, and continue — do not “finish the wander.”
3. **Unknown blast radius** → explore read-only first, then re-plan. Do not start four writers.

---

## 3. Parallel lanes (the real speedup)

Throughput comes from **non-overlapping writers**, not from more tokens on the same files.

### Default lane map

| Lane | Owns (write) | Notes |
|------|----------------|-------|
| **python** | `python/` | Reference-friendly encoder/decoder |
| **rust** | `rust/` | Rust SDK + CLI |
| **typescript** | `typescript/` | Core / node / browser packages |
| **dart** | `dart/` | Dart SDK |
| **swift** | `swift/` | Swift SDK |
| **cpp** | `cpp/` | C++ SDK |
| **spec / kaitai / corpus** | `kaitai/`, `spec-tools/`, shared conformance fixtures under language trees as documented | Bottom of a feature stack |
| **website / docs** | `website/` | Concepts vocabulary lives here |
| **scripts / ci** | `scripts/`, `.github/` | Prefer dedicated PRs |
| **root prose** | `AGENTS.md`, this file, CHANGELOG, RELEASING | lead when multi-agent |

Hard rules:

1. **Two writers never share a file.** Split by language directory first.
2. **One language per PR** (AGENTS.md §9). A feature across SDKs is a **stack**, not one PR
   and not four parallel PRs against `main` that all edit shared corpus meaning without a base.
3. **Contract / corpus first.** Spec or shared fixture changes land at the **bottom** of the
   stack; each language PR above proves the same claim.
4. **One `git worktree` per concurrent lane (required).** Do not run two writing agents in
   the same working tree. Shared dirt causes silent overwrites, false “fixes,” and unreviewable
   mixed diffs. **New** parallel work should use `git worktree` from a single primary clone
   (see below).
5. **Lead owns integration.** When stacking languages, one person/agent manages retargets,
   conformance, and PR narrative.

### `git worktree` — default for parallel / multi-agent work

From the primary clone (example paths; pick a sibling dir you control):

```bash
# One language = one branch = one worktree, branched from origin/main (or stack base)
git fetch origin main
git worktree add -b feat/python-<slug> ../4dgs-wt-python origin/main
git worktree add -b feat/rust-<slug>   ../4dgs-wt-rust   origin/main

# Agent A cwd: ../4dgs-wt-python   (writes python/ only)
# Agent B cwd: ../4dgs-wt-rust     (writes rust/ only — only if independent of A;
#                                   for one feature, stack instead of parallel)

# After PR merge or abandon:
git worktree remove ../4dgs-wt-python
git branch -d feat/python-<slug>   # if fully merged
```

When languages **depend on the same corpus change**, do **not** parallelize against `main`:
open the corpus PR first, then `git worktree add -b … <path> <corpus-branch>` for each
language layer (or wait and branch from the next stack base). Parallel worktrees are for
**independent** claims (e.g. two bugfixes in different SDKs).

Rules of use:

- **Branch from `origin/main`** (or the stack base), never from a dirty unrelated feature branch.
- **Agent cwd is the worktree root** for that lane — not the primary tree.
- **Do not** `git worktree add` into a path that already has uncommitted work.
- List with `git worktree list`; prune stale entries with `git worktree prune` after deletes.

Single-lane, single-agent work may stay in the primary tree. The moment a second writer starts,
**spin a worktree** — do not “just use another pane” on the same checkout.

### Prompt shape for a parallel agent

Keep prompts short; put judgment in the PR body later:

```text
Lane: python only. Cwd: <worktree path>. Write only under python/.
Goal: <one sentence>.
Out of scope: rust/, typescript/, dart/, other SDKs.
Done when: python conformance / package tests green for this claim.
Commit atomically as you go (see §4). Do not open the PR unless asked.
```

---

## 4. Commit rhythm inside a PR (atomic, not ceremonial)

Agents **should** commit as they go. Humans should too. The PR is the review unit; commits
are the undo/log unit.

1. **Atomic commits** — one concern per commit. Prefer Conventional Commit subjects when
   natural: `fix(python): …`, `test(rust): …`, `docs: …`. Put the long reasoning in the
   **commit body or PR body**, not a 40-line subject.
2. **Only stage your lane’s files.** Other agents’ dirt is not yours to “helpfully” fix
   unless you own that lane.
3. **Do not amend** shared history or force-push unless the human asked (stacked-PR recovery
   is the exception — follow AGENTS.md §9).
4. **Batch review-bot findings** into one follow-up commit when possible
   (`fix: address review — <theme>`), not five serial micro-pushes for five nits.
5. **Conformance with the claim.** An SDK claims a feature by passing the suite for it
   (AGENTS.md §8). A fix without a regression on decode semantics is unfinished unless the PR
   explains why and what encodes the gap.

PR description stays the place for narrative: which claim, which suite, risk. That quality
bar does **not** require a single sprawling commit.

---

## 5. Fast feedback loops (close the loop without full multi-SDK waits)

During the loop, run **that language’s** tests only. Cross-language full matrix is CI / stack
integration, not every keystroke.

| Loop | Prefer |
|------|--------|
| Python | package tests / conformance under `python/` (see package README/Makefile) |
| Rust | `cargo test` in `rust/` (scoped packages) |
| TypeScript | package scripts under `typescript/` |
| Dart | package tests under `dart/` |
| Vocabulary / concepts | `website/docs/guides/concepts.md` consistency |

**Close the loop before expanding scope.** If verification is red, fix or shrink — do not
open a second language layer on a red base.

---

## 6. What to parallelize vs serialize

**Parallelize (high ROI):**

- Independent bugs in different language SDKs (separate worktrees → separate PRs to `main`)
- Docs / website wording while a finished SDK change sits in review
- Hypothesis debugging on isolated worktrees
- Cleanup that cannot conflict: dead code in one SDK, lint-only

**Serialize (quality / correctness):**

- Format semantics and shared conformance meaning
- Hostile-input / untrusted-bytes decode hardening that redefines errors
- Multi-language feature delivery (**stack**, bottom-up)
- Release cuts (RELEASING.md)

**Anti-patterns (slow and low quality):**

- One PR touching Python + Rust + TypeScript + Dart “to finish the feature”
- Parallel writers in the same language tree “to go faster”
- Optimizing for commit count or merging before that language’s conformance is green
- Renaming concepts away from `website/docs/guides/concepts.md` vocabulary

---

## 7. Cleanup is a product (scheduled, small, separate)

Debt paydown keeps agents fast later. Prefer **dedicated small PRs**:

- dead code / unused exports in one language
- duplicate tests
- AGENTS.md / README command fixes

Do **not** hide large refactors inside feature PRs. Opportunistic cleanup is OK only when it
is high-confidence, in-lane, and does not obscure the feature diff.

---

## 8. Metrics (track these, not vanity)

Per person or team, weekly:

1. **PRs merged** with CI green (primary)
2. **Median time** idea → first green CI on the PR
3. **Median files changed** on non-merge commits (keep low; multi-language spikes mean stack)
4. **Bot/review findings that are real** vs noise (encode the real ones in AGENTS.md)

If (1) and (2) improve while conformance/regresses stay flat, the system is working.
If commit count rises and decode incidents rise, stop and re-read §2 and AGENTS.md §1–§8.

---

## 9. Standing rules for agents (checklist)

1. Declare **language lane + out-of-scope paths** before writing.
2. **One language per PR**; stack multi-SDK features (AGENTS.md §9).
3. Commit **atomically** in-lane; leave other agents’ files alone.
4. Verify with **that language’s** tests; escalate before open PR.
5. Self-check cross-SDK principles (bounded memory, streamable decode, I/O at edges, …).
6. When you learn something the next agent will need, write it into AGENTS.md — do not only
   put it in chat.

---

## 10. See also

- Root [`AGENTS.md`](AGENTS.md) — design principles + stacked multi-language PRs
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — contribution flow
- [`RELEASING.md`](RELEASING.md) — per-language release
- [`website/docs/guides/concepts.md`](website/docs/guides/concepts.md) — shared vocabulary
