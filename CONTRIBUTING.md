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
state at time `t`; everything downstream belongs to whatever draws it.

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

## Code of conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
