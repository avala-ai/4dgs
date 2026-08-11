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

**When to read this file (opt-in):** multi-agent work, multi-language / cross-lane changes,
stacked multi-SDK features, or a PR that is about to bloat. **Skip** for tiny single-language
edits. Root [`AGENTS.md`](AGENTS.md) uses the same threshold.

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

| Lane | Conflict scope (write exclusive) | Notes |
|------|----------------------------------|-------|
| **python** | `python/` | Reference-friendly encoder/decoder |
| **rust** | `rust/` | Rust SDK + CLI |
| **typescript** | `typescript/` | Core / node / browser packages |
| **dart** | `dart/` | Dart SDK |
| **swift** | `swift/` | Swift SDK |
| **cpp** | `cpp/` | C++ SDK |
| **spec / kaitai / corpus** | `kaitai/`, `spec-tools/`, **`tests/conformance/`** (shared generator, harness, expectations, fixtures) | Bottom of a feature stack |
| **website / docs** | `website/` | Concepts vocabulary lives here |
| **scripts / ci** | `scripts/`, `.github/` | Prefer dedicated PRs |
| **root prose** | `AGENTS.md`, this file, CHANGELOG, RELEASING | lead when multi-agent |

Hard rules:

1. **Two writers never share a file.** Split by language directory first.
2. **One language per PR** (AGENTS.md §9). A feature across SDKs is a **stack**, not one PR
   and not four parallel PRs against `main` that all edit shared corpus meaning without a base.
3. **Contract / corpus first.** Spec or shared fixture changes (`tests/conformance/`, kaitai,
   spec-tools) land at the **bottom** of the stack; each language PR above proves the same claim.
4. **One `git worktree` per concurrent lane (required)** for parallel writers.
5. **Lead owns integration.** When stacking languages, one person/agent manages retargets,
   conformance, and PR narrative.
6. **Fork exception (AGENTS.md §9):** cross-fork stacks are not supported. Contributors on a
   **fork** use ordinary **sequential** PRs (one language after another merges to upstream),
   not a required in-repo stack. Do not prescribe an impossible stacked workflow for forks.

### `git worktree` — default for parallel / multi-agent work

Resolve the **upstream** remote (`avala-ai/4dgs`). On a fork that is often `upstream`.

```bash
UPSTREAM=$(git remote -v | awk '/avala-ai\/4dgs/ {print $1; exit}')
UPSTREAM=${UPSTREAM:-origin}
git fetch "$UPSTREAM" main

# Independent bugfixes in two languages (parallel PRs to main):
git worktree add --no-track -b fix/python-<slug> ../4dgs-wt-python "$UPSTREAM/main"
git worktree add --no-track -b fix/rust-<slug>   ../4dgs-wt-rust   "$UPSTREAM/main"

# First publish: git push -u origin HEAD

# Squash-safe cleanup after merge/abandon:
git worktree remove ../4dgs-wt-python
gh pr view <n> --json state --jq .state
git branch -D fix/python-<slug>
```

**Stacked multi-SDK feature** (corpus then languages) — each layer branches from the layer
**below**, not all from the corpus tip as siblings:

```bash
# 1) corpus layer
git worktree add --no-track -b feat/<slug>-corpus ../4dgs-wt-corpus "$UPSTREAM/main"
# ... land corpus PR targeting main ...

# 2) first language — base = corpus branch (PR targets corpus branch)
git worktree add --no-track -b feat/<slug>-python ../4dgs-wt-python feat/<slug>-corpus

# 3) next language — base = previous language branch (PR targets that branch)
git worktree add --no-track -b feat/<slug>-rust ../4dgs-wt-rust feat/<slug>-python
```

Do **not** create every language worktree from the corpus branch alone; that yields sibling
branches, not a stack (AGENTS.md §9).

Rules of use:

- **Branch from `$UPSTREAM/main`** or the **immediate stack base**, never a dirty unrelated branch.
- **Agent cwd is the worktree root** for that lane.
- **Do not** `git worktree add` into a path that already has uncommitted work.
- List with `git worktree list`; prune with `git worktree prune` after deletes.

Single-lane, single-agent work may stay in the primary tree. The moment a second writer starts,
**spin a worktree**.

### Prompt shape for a parallel agent

```text
Lane: python only. Cwd: <worktree path>. Write only under python/.
Goal: <one sentence>.
Out of scope: rust/, typescript/, dart/, tests/conformance/ (unless corpus lane), other SDKs.
Done when: python conformance / package tests green for this claim.
Commit atomically as you go (see §4). Do not open the PR unless asked.
```

---

## 4. Commit rhythm inside a PR (atomic, not ceremonial)

Agents **should** commit as they go **inside their own worktree**.

1. **Atomic commits** — Prefer Conventional Commit subjects: `fix(python): …`, `test(rust): …`.
2. **Only stage your lane’s files.**
3. **History rewrites:** no casual amend/force-push.
   - Allowed: stack recovery on **feature** branches per AGENTS.md §9.
   - **Never** force-push `main`, even on a casual human request — protected branch rules win.
4. **Batch review-bot findings** into one follow-up commit when possible.
5. **Conformance with the claim** (AGENTS.md §8).

---

## 5. Fast feedback loops (close the loop without full multi-SDK waits)

| Loop | Prefer |
|------|--------|
| Python | package tests / conformance under `python/` (see package README/Makefile) |
| Rust | `cargo test` in `rust/` (scoped packages) |
| TypeScript | **Repo root:** `yarn test` and/or `yarn conformance` (packages under `typescript/` do not define test scripts). Generate corpus first when exercising corpus-backed tests. |
| Dart | package tests under `dart/` |
| Vocabulary / concepts | `website/docs/guides/concepts.md` consistency |

**Close the loop before expanding scope.**

---

## 6. What to parallelize vs serialize

**Parallelize:** independent bugs in different SDKs (separate worktrees → separate PRs to
`main`); docs while an SDK change sits in review; isolated hypothesis worktrees; in-lane cleanup.

**Serialize:** format semantics / shared conformance meaning; hostile-input decode hardening that
redefines errors; multi-language feature delivery (**stack**, bottom-up); release cuts.

**Anti-patterns:** one PR across four languages; two writers one tree; sibling branches where a
stack is required; fork contributors forced into in-repo stacks; commit vanity.

---

## 7. Cleanup is a product (scheduled, small, separate)

Prefer dedicated small PRs: dead code in one language, duplicate tests, AGENTS.md command fixes.
Do not hide large refactors inside feature PRs.

---

## 8. Metrics (track these, not vanity)

1. **PRs merged** with CI green  
2. **Median time** idea → first green CI  
3. **Median files changed** on non-merge commits  
4. **Real** review findings encoded into AGENTS.md  

---

## 9. Standing rules for agents (checklist)

1. Declare **language lane + out-of-scope paths** before writing.  
2. **One language per PR**; stack multi-SDK features (AGENTS.md §9); forks use sequential PRs.  
3. Commit **atomically** in-lane (own worktree).  
4. Verify with **that language’s** real test entry points; escalate before open PR.  
5. Self-check cross-SDK principles (bounded memory, streamable decode, I/O at edges, …).  
6. Encode learnings into AGENTS.md — not only chat.

---

## 10. See also

- Root [`AGENTS.md`](AGENTS.md) — design principles + stacked multi-language PRs  
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — contribution flow (including forks)  
- [`RELEASING.md`](RELEASING.md) — per-language release  
- [`website/docs/guides/concepts.md`](website/docs/guides/concepts.md) — shared vocabulary  
