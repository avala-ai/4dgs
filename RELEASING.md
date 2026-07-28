# Releasing

Packages are versioned and released independently. A release is a tag; CI does the rest.

## Tag format

```
releases/python/vX.Y.Z
releases/rust/vX.Y.Z
releases/typescript/<package>/vX.Y.Z
```

for example `releases/python/v0.2.0` or `releases/typescript/core/v0.2.0`. Languages that ship one
package do not repeat its name in the tag; TypeScript ships four, so it does.

`releases/dart/vX.Y.Z` is reserved and unused.

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

The format, the repository, the CLI and the file extension are always **4dgs** and **`.4dgs`**.
Package names are a different matter, and not because we chose them: three registries impose three
different constraints, and the honest thing is to write down what each one is rather than imply a
consistency that does not exist.

| Registry  | Name                                                          | Why                                                                                                                                     |
| --------- | ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| PyPI      | `fourdgs`                                                     | `4dgs` is taken by an unrelated project. `pip install fourdgs`, `import fourdgs` — the two now agree, so there is no alias to remember  |
| crates.io | `fourdgs`                                                     | Cargo rejects a crate name beginning with a digit, so `4dgs` is not available to anyone. The `[lib] name` matches                       |
| npm       | `@4dgs/core`, `@4dgs/browser`, `@4dgs/nodejs`, `@4dgs/codecs` | Scoped names may begin with a digit. The unscoped `4dgs` was refused by npm's similarity filter, so the scope is not a stylistic choice |

In prose, in the specification, in the CLI and on disk: always `4dgs`. `fourdgs` appears only as a
package name, and only where a registry requires it.

## Pre-1.0

While the spec is a draft, minor versions may change the wire format. Once version 1 is declared
stable, the compatibility rules in the spec apply and the frozen records are frozen for good.
