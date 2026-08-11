# SHIP.md — Throughput without quality debt

**Audience:** humans and coding agents shipping in this repository.

**Purpose:** raise _landed, correct_ change rate via parallel work and tight feedback loops —
without weakening [`AGENTS.md`](AGENTS.md) (cross-SDK principles),
[`CONTRIBUTING.md`](CONTRIBUTING.md), or conformance.

**Not a goal:** commit count, token spend, or “vibe” volume. Those are lagging noise. Optimize for
**green PRs merged per week** and **time from idea → first green CI**.

Companion to the Avala monorepo’s `SHIP.md` (same discipline, this repo’s lanes).

---

## 1. Relationship to the other root docs

| Doc                                  | Job                                                                       |
| ------------------------------------ | ------------------------------------------------------------------------- |
| [`AGENTS.md`](AGENTS.md)             | Cross-SDK design principles + **one language per PR, stacked**            |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | How to contribute                                                         |
| [`RELEASING.md`](RELEASING.md)       | Release process per language                                              |
| **This file**                        | How to _structure work_ so many agents ship in parallel without thrashing |

**When to read this file (opt-in):** multi-agent work, multi-language / cross-lane changes, stacked
multi-SDK features, or a PR that is about to bloat. **Skip** for tiny single-language edits. Root
[`AGENTS.md`](AGENTS.md) uses the same threshold.

**Already load-bearing here:** AGENTS.md §9 — _one language per pull request, stacked_. SHIP does
not replace that; it adds blast radius, worktrees, and commit rhythm around it.

---

## 2. Blast radius (size the work first)

Before editing, name the blast radius out loud (or in the agent prompt):

| Size          | Typical scope                                                     | Parallel?                                                 |
| ------------- | ----------------------------------------------------------------- | --------------------------------------------------------- |
| **Tiny**      | 1–3 files, one concern, &lt;~150 LOC                              | Alone or as a satellite next to a hard task               |
| **Medium**    | One language SDK / one package                                    | One agent or one PR                                       |
| **Large**     | Spec/corpus change + N language SDKs                              | **Stack** (corpus bottom → languages) — never one mega-PR |
| **Dangerous** | Format semantics, conformance meaning, hostile-input decode paths | Serial review; no parallel writers on the same claim      |

Rules:

1. Prefer **many tiny/medium PRs** over one fat PR reviewers cannot hold in their head.
2. If an agent run exceeds the expected radius (touches a second language “while here”), **stop**,
   re-scope, and continue — do not “finish the wander.”
3. **Unknown blast radius** → explore read-only first, then re-plan. Do not start four writers.

---

## 3. Parallel lanes (the real speedup)

Throughput comes from **non-overlapping writers**, not from more tokens on the same files.

### Default lane map

| Lane                       | Conflict scope (write exclusive)                                                                 | Notes                                                              |
| -------------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------ |
| **python**                 | `python/`                                                                                        | Reference-friendly encoder/decoder                                 |
| **rust**                   | `rust/`, root `Cargo.toml` / `Cargo.lock` when the workspace changes                             | Rust SDK + CLI                                                     |
| **typescript**             | `typescript/`, root `package.json` / `yarn.lock` when deps change                                | Core / node / browser packages; stage lock with the package change |
| **dart**                   | `dart/`                                                                                          | Dart SDK                                                           |
| **swift**                  | `swift/`                                                                                         | Swift SDK                                                          |
| **cpp**                    | `cpp/`                                                                                           | C++ SDK                                                            |
| **spec / kaitai / corpus** | `kaitai/`, `spec-tools/`, `tests/conformance/`, **`website/docs/spec/`** (normative format docs) | Bottom of a feature stack — wire-format + corpus                   |
| **fuzz (shared)**          | `tests/fuzz/`                                                                                    | Shared hostile-input seeds — **serialize**; one writer only        |
| **website / docs**         | `website/` **except** `website/docs/spec/`                                                       | Guides/concepts only; normative spec is corpus lane                |
| **scripts / ci**           | `scripts/`, `.github/`                                                                           | Prefer dedicated PRs                                               |
| **root prose**             | `AGENTS.md`, this file, CHANGELOG, RELEASING                                                     | lead when multi-agent                                              |

Hard rules:

1. **Two writers never share a file.** Split by language directory first.
2. **One language per PR** (AGENTS.md §9). A feature across SDKs is a **stack**, not one PR and not
   four parallel PRs against `main` that all edit shared corpus meaning without a base.
3. **Contract / corpus first.** Spec or shared fixture changes (`tests/conformance/`, kaitai,
   spec-tools) land at the **bottom** of the stack; each language PR above proves the same claim.
4. **One `git worktree` per concurrent lane (required)** for parallel writers.
5. **Lead owns integration.** When stacking languages, one person/agent manages retargets,
   conformance, and PR narrative.
6. Propose durable learnings to the **lead** (root-prose lane); do not parallel-edit root
   `AGENTS.md` from multiple language lanes.
7. **Fork exception (AGENTS.md §9):** contributors on a fork use ordinary **sequential** PRs (one
   language after another merges to upstream), not an in-repo stack GitHub cannot create.

### `git worktree` — default for parallel / multi-agent work

Resolve the **upstream** remote (`avala-ai/4dgs`). On a fork that is often `upstream`.

```bash
UPSTREAM=$(git remote -v | awk '/avala-ai\/4dgs/ {print $1; exit}')
if [ -z "$UPSTREAM" ]; then
  echo "No remote for avala-ai/4dgs. Add e.g.: git remote add upstream git@github.com:avala-ai/4dgs.git"
  exit 1
fi
git fetch "$UPSTREAM" main

# Independent bugfixes in two languages (parallel PRs to main):
git worktree add --no-track -b fix/python-<slug> ../4dgs-wt-python "$UPSTREAM/main"
git worktree add --no-track -b fix/rust-<slug>   ../4dgs-wt-rust   "$UPSTREAM/main"

# Publish — set PR_HEAD_REMOTE explicitly (writable remote for the PR head). Never `git remote | head -1`.
#   : "${PR_HEAD_REMOTE:?}"; git push -u "$PR_HEAD_REMOTE" HEAD
# Stacks on the canonical repo: git push -u "$UPSTREAM" HEAD

# Cleanup — resolve and enter the primary clone even when this block starts in a linked
# worktree. `--show-toplevel` would only name the linked worktree itself.
PRIMARY_GIT_DIR=$(git rev-parse --path-format=absolute --git-common-dir)
PRIMARY=$(dirname "$PRIMARY_GIT_DIR")
cd "$PRIMARY"
state=$(gh pr view <n> --json state --jq .state)
if [ "$state" = "MERGED" ] || [ "${ABANDON_CONFIRMED:-}" = "1" ]; then
  if [ -n "$(git -C ../4dgs-wt-python status --porcelain 2>/dev/null)" ]; then
    echo "Worktree ../4dgs-wt-python is dirty — refuse remove. Commit/stash/discard first."
    exit 1
  fi
  git worktree remove ../4dgs-wt-python
  git branch -D fix/python-<slug>
else
  echo "PR still $state — not deleting branch"
fi
```

**Stacked multi-SDK feature** (corpus then languages) — each layer branches from the layer
**below**, not all from the corpus tip as siblings. **Open/submit upper-layer PRs while the corpus
PR is still open** (stack bases stay live). Do not wait until corpus is merged and its remote branch
deleted, then try to target the old local tip.

```bash
# 1) corpus layer — open PR targeting main (do not merge yet)
git worktree add --no-track -b feat/<slug>-corpus ../4dgs-wt-corpus "$UPSTREAM/main"
# push + open corpus PR

# 2) first language — base = corpus branch; PR targets corpus branch
git worktree add --no-track -b feat/<slug>-python ../4dgs-wt-python feat/<slug>-corpus
# push + open PR with base=feat/<slug>-corpus

# 3) next language — base = previous language branch
git worktree add --no-track -b feat/<slug>-rust ../4dgs-wt-rust feat/<slug>-python

# Merge bottom-up. If corpus already merged and branch is gone, open sequential PRs from
# updated $UPSTREAM/main instead of inventing a dead stack base.
```

Do **not** create every language worktree from the corpus branch alone as siblings (AGENTS.md §9).

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
2. **Only stage your lane’s files.** Rust may stage root `Cargo.toml` / `Cargo.lock` when the
   workspace changes. TypeScript may stage root `yarn.lock` / workspace `package.json` when the
   change updates deps.
3. **History rewrites:** no casual amend/force-push.
   - Allowed: stack recovery on **feature** branches per AGENTS.md §9.
   - **Never** force-push `main`, even on a casual human request — protected branch rules win.
4. **Batch review-bot findings** into one follow-up commit when possible.
5. **Conformance with the claim** (AGENTS.md §8).

---

## 5. Fast feedback loops (close the loop without full multi-SDK waits)

| Loop                  | Prefer                                                                                                                                                                                                                                                      |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Python                | Package tests under `python/`. **Format claim:** generate corpus, then `python tests/conformance/run.py --runner python` from repo root (same as CI).                                                                                                       |
| Rust                  | Package `cargo test` in `rust/`. **Format claim:** build runners as CI does, generate corpus, then `python tests/conformance/run.py --runner rust`.                                                                                                         |
| TypeScript            | **Repo root:** generate the corpus first, then `yarn test`; **format claim:** `python3 tests/conformance/generate.py`, `yarn build`, then `yarn conformance` / `python3 tests/conformance/run.py --runner typescript`. The corpus must precede both checks. |
| Dart                  | Package tests under `dart/`. **Format claim:** build dart runners as CI does, generate corpus, then `python tests/conformance/run.py --runner dart`.                                                                                                        |
| C++                   | Package/build tests under `cpp/`. **Format claim:** build runners as CI does, generate corpus, then `python tests/conformance/run.py --runner cpp`.                                                                                                         |
| Swift                 | Package tests under `swift/`. **Format claim:** build runners as CI does, generate corpus, then `LD_LIBRARY_PATH=$PWD/target/release python3 tests/conformance/run.py --runner swift` (the Linux runner loads `libfourdgs.so` there).                       |
| Vocabulary / concepts | `website/docs/guides/concepts.md` (not normative `website/docs/spec/`)                                                                                                                                                                                      |

**Close the loop before expanding scope.**

---

## 6. What to parallelize vs serialize

**Parallelize:** independent bugs in different SDKs (separate worktrees → separate PRs to `main`);
docs while an SDK change sits in review; isolated hypothesis worktrees; in-lane cleanup.

**Serialize:** format semantics / shared conformance meaning; hostile-input decode hardening that
redefines errors; multi-language feature delivery (**stack**, bottom-up); release cuts.

**Anti-patterns:** one PR across four languages; two writers one tree; sibling branches where a
stack is required; fork contributors forced into in-repo stacks; commit vanity.

---

## 7. Cleanup is a product (scheduled, small, separate)

Prefer dedicated small PRs: dead code in one language, duplicate tests, AGENTS.md command fixes. Do
not hide large refactors inside feature PRs.

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
6. Propose learnings to the **lead** (root-prose lane); do not parallel-edit root `AGENTS.md`.

---

## 10. See also

- Root [`AGENTS.md`](AGENTS.md) — design principles + stacked multi-language PRs
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — contribution flow (including forks)
- [`RELEASING.md`](RELEASING.md) — per-language release
- [`website/docs/guides/concepts.md`](website/docs/guides/concepts.md) — shared vocabulary
