# Contributing

> This repository is the 4dgs format: its specification, its conformance suite, and SDKs for reading
> and writing it. Viewers, renderers, engine integrations, and performance tooling are out of scope.

That sentence is the charter, and it decides most scope questions before they become arguments.

## In scope

- Specification changes and clarifications
- SDK correctness, API ergonomics, and decode performance
- New conformance scenarios, especially ones that catch a real divergence
- New language SDKs (see the recipe below)
- Documentation: the spec, the guides, the registry, the feature matrix

## Out of scope

- Viewer or renderer code of any kind
- GPU, shader, or graphics-pipeline code
- Rendering benchmarks, or performance comparisons between renderers
- Product or engine integrations
- Comparisons against other formats or products

These are declined by policy, not by judgement of quality. Decoding ends at reconstructed gaussian
state and audio-source state at time `t`; drawing and listener-relative audio spatialization belong
to the consuming renderer/player.

## Spec changes

Wire-format changes need an issue before a pull request, using the spec-change template. The issue
states the motivation, the wire impact, the backward-compatibility analysis, and which SDKs are
affected. A spec change needs two approvals and a conformance scenario that would fail without it.

Remember the compatibility rules the format is built on: records may gain appended fields; existing
fields in frozen records may not change; unknown records are skipped, so a new opcode is usually
cheaper than a change to an old one.

## Adding a language SDK

1. Implement the decoder against the conformance corpus, and a runner that prints the canonical JSON
   to stdout.
2. Declare which variants you support with `supportsVariant()`, and let the harness skip the rest —
   a partial SDK is welcome and honest.
3. Add a column to the feature matrix, filled in from what the suite actually proves.

## Pull requests

Title prefixes: `spec:`, `python:`, `typescript:`, `rust:`, `cpp:`, `conformance:`, `docs:`, `ci:`.

Every PR confirms the scope checkbox in the template. Conformance must pass; the corpus `--verify`
gate must be green, which means regenerating it if your change touches the encoder.

**A pull request with no CI run at all has a conflict, not a slow queue.** GitHub runs
`pull_request` workflows against the merge commit, and when that merge cannot be computed it skips
the run silently — no failure, no red mark, just an absence that looks like waiting. Rebase on
`main` and push again. Worth knowing because the natural reading of an empty checks list is the
wrong one.

## Platforms exercised in CI

Every runner is GitHub-hosted, so this is reproducible by anyone with a fork. The table is what
actually runs green, not what is expected to work — an SDK is only listed on a platform its jobs
really build and test there.

| SDK        | Linux x86-64              | Linux arm64  | macOS                             | Windows                   |
| ---------- | ------------------------- | ------------ | --------------------------------- | ------------------------- |
| Python     | build, tests, conformance | build, tests | build, tests, conformance         | build, tests, conformance |
| TypeScript | build, tests, conformance | build, tests | build, tests, conformance         | build, tests, conformance |
| Rust       | build, tests, conformance | build, tests | build, tests, conformance         | build, tests, conformance |
| C++        | build, tests, conformance | build, tests | build, tests                      | build, tests (MSVC)       |
| Swift      | build, tests, conformance | —            | build for macOS, iOS and visionOS | —                         |

This is a statement about platforms, not about features. Which parts of the format each SDK
implements is the feature matrix's job, and that matrix stays per-feature — a decoder does not
support a different set of records on Windows than it does on Linux.

Some jobs stay on Linux deliberately, each for a reason that is not "nobody got to it":

- **fuzz** bounds the decoder's address space with `ulimit -v`, and "never allocates without bound"
  cannot be checked on a machine willing to satisfy the allocation. There is no portable equivalent.
- **browser** needs a Chrome driven over the DevTools protocol, which the other images do not have.
- The C++ **sanitizer** leg looks for leaks and over-reads in the binding's own logic, which is the
  same code on every platform, so one platform finds them.
- **size-budget**, **markdown** and **no-committed-binaries** read the repository. Reading it four
  times returns the same answer four times.

Checks that read source rather than exercise a machine — `ruff`, `clippy`, `rustfmt`, `prettier`,
`clang-format` — also run on one leg only, for the same reason.

Two platform notes worth keeping if you touch these workflows:

- **Cache keys need `runner.arch`, not just `runner.os`.** `ubuntu-latest` and `ubuntu-24.04-arm`
  both report `Linux`, so an OS-keyed cache would hand the arm leg x86-64 binaries.
- **The default shell on `windows-latest` is PowerShell.** The jobs with an OS matrix declare
  `defaults.run.shell: bash` so one script serves every leg.

## Disabled CI jobs

A job behind `if: false` is a promise, and **it is untested by construction** — nothing runs it, so
nothing can tell you it has stopped being true. Four ways one goes wrong, all of which have happened
here:

- **Stale invocation.** It ran once and the world moved: a path changed, a package gained a
  dependency, a tool left the image. Fails loudly the moment anyone enables it.
- **Placeholder that would go green.** It never was an invocation — an `echo` standing in for work
  nobody has done. Enabling it produces a passing job that checked nothing, which is worse than a
  red one because it looks like coverage.
- **Publishes green but broken.** It succeeds and ships something wrong. A publish that fails is
  loud; a publish that succeeds broken is found by the first user.
- **Correct but fragile.** The invocation is right and it still dies on somebody else's outage — an
  network fetch with no retry, a registry that rate-limits. This is the one that survives an audit,
  because reading the job cannot reveal it.

So: keep a disabled job's steps correct as of today rather than as of whenever it was written, say
in the gate comment which kind it is and what enabling actually costs, and remember that fixing a
disabled job does not graduate it. **Only running it does.**

## Code of conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
