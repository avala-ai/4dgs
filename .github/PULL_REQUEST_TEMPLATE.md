## What this changes

<!-- One or two sentences. -->

## Scope

- [ ] This change is about the format: the specification, SDK read/write, conformance, or
      documentation of those.

Viewers, renderers, engine integrations and rendering benchmarks are out of scope — see
[CONTRIBUTING.md](../CONTRIBUTING.md).

## Checks

- [ ] Conformance passes, including the corpus `--verify` gate
- [ ] If this touches the encoder, the corpus was regenerated and the checksums updated
- [ ] If this changes the wire format, there is a linked spec-change issue and a
      conformance scenario that fails without this change
- [ ] The feature matrix still reflects reality
