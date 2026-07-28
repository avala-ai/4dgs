# Releasing

Packages are versioned and released independently. A release is a tag; CI does the rest.

## Tag format

```
releases/<language>/<package>/vX.Y.Z
```

for example `releases/python/4dgs/v0.2.0`.

## Checklist, per package

1. Conformance is green on `main`, including the corpus `--verify` gate.
2. The package's `CHANGELOG.md` has a released section for this version, following Keep a Changelog.
3. The version constant in the package source matches the version in the tag. CI asserts this and
   fails the release if they diverge — there is exactly one version constant per package and it is
   the source of truth.
4. The feature matrix reflects what this version actually implements.
5. Tag and push. The release workflow builds, verifies the version-vs-tag assertion, and publishes
   via trusted publishing (no long-lived tokens).

## Naming

The format, the repository, the CLI and the distribution are all **4dgs**. The only exception is
where a language forbids an identifier starting with a digit:

- **Python**: install `4dgs`, import `fourdgs`.
- **TypeScript**: `@4dgs/core` and friends — no alias needed.
- **Rust**: the crate is `fourdgs` (Cargo identifiers cannot start with a digit); the format is
  still `4dgs` everywhere in prose and on disk.

Never write `fourdgs` in prose except in the one install-versus-import sentence a package README
needs.

## Pre-1.0

While the spec is a draft, minor versions may change the wire format. Once version 1 is declared
stable, the compatibility rules in the spec apply and the frozen records are frozen for good.
