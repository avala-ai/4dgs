# Releasing

Packages are versioned and released independently. A release is a tag; CI does the rest.

The log of what has been released is [CHANGELOG.md](CHANGELOG.md) at the root, which indexes the
per-package changelogs and lists every release in order.

## Tag format

```
releases/python/vX.Y.Z
releases/rust/vX.Y.Z
releases/dart/vX.Y.Z
releases/typescript/<package>/vX.Y.Z
```

for example `releases/python/v0.2.0` or `releases/typescript/core/v0.2.0`. Languages that ship one
package do not repeat its name in the tag; TypeScript ships four, so it does.

Dart's changelog is `dart/fourdgs/CHANGELOG.md` rather than `dart/CHANGELOG.md`, one level deeper
than every other language's. That is pub.dev's requirement rather than a preference: it renders the
changelog from the package root, so a file beside the package would not be published with it.

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
Package names are a different matter, and not because we chose them: four registries and two
language-identifier rules impose six constraints, and the honest thing is to write down what each
one is rather than imply a consistency that does not exist.

| Registry  | Name                                                          | Why                                                                                                                                            |
| --------- | ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| PyPI      | `fourdgs`                                                     | `4dgs` is taken by an unrelated project. `pip install fourdgs`, `import fourdgs` — the two now agree, so there is no alias to remember         |
| crates.io | `fourdgs`                                                     | Cargo rejects a crate name beginning with a digit, so `4dgs` is not available to anyone. The `[lib] name` matches                              |
| crates.io | `fourdgs-cli`, binary `4dgs`                                  | The same constraint applies to the CLI's crate, but not to what it installs: a `[[bin]] name` may begin with a digit, so the command is `4dgs` |
| npm       | `@4dgs/core`, `@4dgs/browser`, `@4dgs/nodejs`, `@4dgs/codecs` | Scoped names may begin with a digit. The unscoped `4dgs` was refused by npm's similarity filter, so the scope is not a stylistic choice        |
| pub.dev   | `fourdgs`                                                     | A pub.dev package name is a Dart identifier and may not begin with a digit — the same rule as Cargo and Swift. `import 'package:fourdgs/…'`    |
| Swift     | module `FourDGS`, C seam `CFourDGS`                           | A Swift module name is an identifier and may not begin with a digit. The casing is Swift's own convention for acronyms, not a rename           |
| Kaitai    | `kaitai/fourdgs.ksy`, type id `fourdgs`                       | A `.ksy` type id becomes an identifier in every target the compiler emits, so the same rule as Swift and Cargo applies                         |

In prose, in the specification, in the CLI and on disk: always `4dgs`. `fourdgs` appears only as a
package name or a language identifier, and only where a registry or a compiler requires it.

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

## Dart, before its first release

**The first publish must be done by hand, and this is a pub.dev constraint rather than a choice.**
Every other registry here accepts an OIDC-authenticated publish for a name nobody has claimed;
pub.dev does not, because automated publishing is configured _on a package_, and until the package
exists there is nothing to configure it on. So the order is fixed:

1. `cd dart/fourdgs && dart pub publish`, once, from a machine logged in with a Google account. This
   claims the name and puts the first version on the registry.
2. On pub.dev, the package's **Admin** tab → **Automated publishing**, enabled for `avala-ai/4dgs`
   with the tag pattern `releases/dart/v{{version}}`.
3. Delete the `if: false` on the `dart` job in
   [`.github/workflows/release.yml`](.github/workflows/release.yml).

The gate is there so that step 3 cannot happen before step 2. Flipping it early does not fail loudly
in a useful way — it produces a job that fails authentication on every tag, which reads as a broken
workflow rather than as a missing setting on a web page.

**Verified publisher.** The intent is to take `fourdgs` to verified-publisher status under the
`4dgs.dev` domain, so the package page carries the domain rather than an individual account. That is
a separate pub.dev setting from automated publishing and gates nothing above; it can be done before
or after step 2.

## Pre-1.0

While the spec is a draft, minor versions may change the wire format. Once version 1 is declared
stable, the compatibility rules in the spec apply and the frozen records are frozen for good.
