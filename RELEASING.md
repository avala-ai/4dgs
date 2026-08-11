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
releases/corpus/vX.Y.Z
vX.Y.Z                        # Swift, and only Swift — see below
```

for example `releases/python/v0.2.0` or `releases/typescript/core/v0.2.0`. Languages that ship one
package do not repeat its name in the tag; TypeScript ships four, so it does.

`releases/corpus/vX.Y.Z` is not a package. It publishes the conformance corpus as a downloadable
archive, and it has its own namespace because the corpus changes when variants are added — which has
nothing to do with any SDK's version, and would be misrepresented by borrowing one.

Swift is the exception, and it is not a style choice — see
[Swift tags look repository-wide and are not](#swift-tags-look-repository-wide-and-are-not).

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
| Tag        | the release tag exactly as pushed, `releases/python/v0.1.0` — or `v0.1.0` for Swift            |
| Name       | `fourdgs (Python) 0.1.0`, `fourdgs (Rust) 0.1.0`, `fourdgs (Swift) 0.1.0`, `@4dgs/core 0.1.0`  |
| Body       | `## What's changed`, that version's changelog section, then the install line and registry link |
| Prerelease | set while the major version is `0`, because the wire format may still change                   |
| Assets     | none — the artifact of record is on the registry, published with its provenance attestation    |

**A missing changelog section fails the release.** `scripts/changelog_section.py` runs before the
build, so a version nobody wrote notes for never reaches a registry; a release with an empty body is
the drift this rule exists to prevent, and it is easier to refuse the tag than to fix it afterwards.

## The conformance corpus

The corpus is released like a package and is not one. It publishes to no registry, so the release
_is_ the publication and the assets on it are the artifact of record — the one job here that
attaches anything, for exactly the reason the others attach nothing.

| Field      | Value                                                                                            |
| ---------- | ------------------------------------------------------------------------------------------------ |
| Tag        | `releases/corpus/vX.Y.Z`                                                                         |
| Version    | `CORPUS_VERSION` in [`scripts/pack_corpus.py`](scripts/pack_corpus.py), asserted against the tag |
| Changelog  | [`tests/conformance/CHANGELOG.md`](tests/conformance/CHANGELOG.md)                               |
| Name       | `Conformance corpus 0.1.0`                                                                       |
| Assets     | `4dgs-conformance-corpus-X.Y.Z.tar.gz` and its `.sha256`                                         |
| Prerelease | set while the major version is `0`, as for every package                                         |

To cut one:

1. Add variants, regenerate, and let `generate.py --verify` and the conformance suite go green on
   `main` — the corpus is published from `main` like everything else.
2. Bump `CORPUS_VERSION` and write the section in `tests/conformance/CHANGELOG.md`. That file says
   what a major, minor and patch bump each mean here; the short version is that a major changes the
   archive's shape, a minor changes which variants are in it, and a patch repacks the same bytes.
3. Read what the release will say, then tag:

   ```sh
   python scripts/changelog_section.py tests/conformance/CHANGELOG.md 0.1.0
   python3 tests/conformance/generate.py && python3 scripts/pack_corpus.py --out dist --check /tmp/corpus
   ```

   The second command is what the job runs: it builds the archive, unpacks it somewhere else, and
   verifies every checksum in its manifest. Build it locally before tagging and you will know what
   the release page is going to carry.

4. Push the tag. The job regenerates and verifies the corpus, builds the archive, unpacks it, scores
   the reference implementation **against the unpacked copy**, and only then creates the release. An
   archive nobody has decoded from is unverified, so that step is a gate rather than a nicety.
5. Add the line to the release log in [CHANGELOG.md](CHANGELOG.md), as for a package.

The version starts at **0.1.0** rather than 1.0.0 because the corpus is a rendering of a draft wire
format: its bytes are determined by a specification whose minor versions may still change, so it
cannot promise more stability than the thing it encodes. It goes to 1.0.0 when version 1 of the
specification is declared stable.

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

## Swift tags look repository-wide and are not

**Swift releases are tagged `vX.Y.Z` on this repository, with no package name in the tag. That tag
means the Swift package's version. It means nothing about any other package here.**

There is no Swift registry to publish to. SwiftPM resolves a package straight from a Git URL, and it
reads versions only from plain SemVer tags — `1.2.3` or `v1.2.3`. A `releases/swift/v0.1.0` tag
offers it no versions at all, so a dependency on this repository could pin a branch or a revision
and never a version. The tag has to take the one shape SwiftPM reads, on the one repository SwiftPM
is pointed at, which is this one. `Package.swift` is at the root for the same reason: SwiftPM looks
for a manifest at the top of whatever it clones.

The trap this creates is worth naming, because it will be read wrong by someone eventually. On a
repository holding six languages, a bare `v0.4.0` sitting beside `releases/python/v0.3.0` and
`releases/rust/v0.4.0` **reads like a version of 4dgs** — of the format, of the repository, of all
of it. There is no such thing: packages here are versioned independently and always have been, the
specification is versioned separately from every package, and a bare tag is simply the only tag
shape one consumer's package manager can see. So:

- The GitHub Release for a bare tag is titled `fourdgs (Swift) X.Y.Z`, like every other release
  here, and its body is `swift/CHANGELOG.md`'s section for that version. The title is the thing that
  disambiguates the tag on the releases page, so it is not optional.
- The bare tag's version sequence belongs to the Swift package alone. It does not have to match
  Python's, Rust's or TypeScript's, and matching by coincidence should not be read as meaning.
- Never cut a bare tag for anything other than Swift. A second consumer of the bare namespace would
  make both ambiguous, and the ambiguity would be permanent — a published tag is not retractable.

**Linking, which is not solved.** The package is a binding, so it needs the core's staticlib on the
linker's search path — today that is `-Xlinker -L…` on the command line, deliberately not an
`unsafeFlags` entry in `Package.swift`, because that would make the package undependable as a
versioned dependency. A consumer who resolves the package from its URL has no `target/release` and
nothing to point `-L` at, so **the package resolves and does not link out of tree**; `Package.swift`
emits a warning naming exactly that when it finds no built core. The fix is a `binaryTarget`
pointing at a prebuilt `.xcframework` attached to the GitHub Release with its checksum, built for
the platforms the manifest declares (visionOS 1, iOS 17, macOS 14). Until that exists, a bare tag
buys resolution and a readable diagnostic, not a build.

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
