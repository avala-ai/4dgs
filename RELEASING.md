# Releasing

Packages are versioned and released independently. A release is a tag; CI does the rest.

The log of what has been released is [CHANGELOG.md](CHANGELOG.md) at the root, which indexes the
per-package changelogs and lists every release in order.

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
2. The package's `CHANGELOG.md` has a released section for this version, following Keep a Changelog
   — a heading with the version in it, not `Unreleased`. This is a gate, not a reminder: the release
   workflow extracts that section as the GitHub Release body and fails before it builds anything if
   there is nothing to extract. Read what the release will say first:

   ```
   python scripts/changelog_section.py python/CHANGELOG.md 0.2.0
   ```

3. The version constant in the package source matches the version in the tag. CI asserts this and
   fails the release if they diverge — there is exactly one version constant per package and it is
   the source of truth.
4. The feature matrix reflects what this version actually implements.
5. Tag and push. The release workflow builds, verifies the version-vs-tag assertion, publishes via
   trusted publishing (no long-lived tokens), and creates the GitHub Release.
6. Add the line to the release log in [CHANGELOG.md](CHANGELOG.md).

## Every release gets a GitHub Release

A tag that publishes a package and leaves nothing behind is a version whose reason lives in a file
you have to know to look for. So the publish job creates a release for its own tag, and the notes
are the changelog section rather than a second description written for the occasion — one text, so
there is nothing for the two to disagree about.

| Field      | Value                                                                                          |
| ---------- | ---------------------------------------------------------------------------------------------- |
| Tag        | the release tag exactly as pushed, `releases/python/v0.1.0`                                    |
| Name       | `fourdgs (Python) 0.1.0`, `fourdgs (Rust) 0.1.0`, `@4dgs/core 0.1.0`                           |
| Body       | `## What's changed`, that version's changelog section, then the install line and registry link |
| Prerelease | set while the major version is `0`, because the wire format may still change                   |
| Assets     | none — the artifact of record is on the registry, published with its provenance attestation    |

**A missing changelog section fails the release.** `scripts/changelog_section.py` runs before the
build, so a version nobody wrote notes for never reaches a registry; a release with an empty body is
the drift this rule exists to prevent, and it is easier to refuse the tag than to fix it afterwards.

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
| Swift     | module `FourDGS`, C seam `CFourDGS`                           | A Swift module name is an identifier and may not begin with a digit. The casing is Swift's own convention for acronyms, not a rename    |

In prose, in the specification, in the CLI and on disk: always `4dgs`. `fourdgs` appears only as a
package name, and only where a registry requires it.

## Swift, before its first release

Two decisions are recorded here rather than left to the day someone tries to publish.

**Linking.** The package is a binding, so it needs the core's staticlib on the linker's search path
— today that is `-Xlinker -L…` on the command line, deliberately not an `unsafeFlags` entry in
`Package.swift`, because that would make the package undependable as a versioned dependency. A
published package needs one of two answers instead: a prebuilt `.xcframework` as a binary target, or
a build plugin that compiles the core. **Not yet chosen.** It is not a blocker for anything before a
release, and it is a blocker for the release itself.

**Platforms.** The core builds for visionOS on stable toolchains — the Apple targets ship a
distributed standard library, so no nightly and no `-Z build-std`, and CI cross-compiles and links
against them. That was the strategy's biggest open question and it is settled.

## Pre-1.0

While the spec is a draft, minor versions may change the wire format. Once version 1 is declared
stable, the compatibility rules in the spec apply and the frozen records are frozen for good.
