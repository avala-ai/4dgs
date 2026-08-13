# Changelog

Packages here are versioned and released independently, so there is no single version of 4dgs and no
single list of changes. The notes live next to the code they describe; this file is the index and
the release log.

| Package                                                                    | Changelog                                                        | Registry                                              |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------- |
| Python — `fourdgs`                                                         | [python/CHANGELOG.md](python/CHANGELOG.md)                       | [PyPI](https://pypi.org/project/fourdgs/)             |
| TypeScript — `@4dgs/core`, `@4dgs/browser`, `@4dgs/nodejs`, `@4dgs/codecs` | [typescript/CHANGELOG.md](typescript/CHANGELOG.md)               | [npm](https://www.npmjs.com/package/@4dgs/core)       |
| Rust — `fourdgs`                                                           | [rust/CHANGELOG.md](rust/CHANGELOG.md)                           | [crates.io](https://crates.io/crates/fourdgs)         |
| Dart — `fourdgs`                                                           | [dart/fourdgs/CHANGELOG.md](dart/fourdgs/CHANGELOG.md)           | not yet published                                     |
| Swift — `FourDGS`                                                          | [swift/CHANGELOG.md](swift/CHANGELOG.md)                         | no registry; resolved from this repository's URL      |
| Conformance corpus                                                         | [tests/conformance/CHANGELOG.md](tests/conformance/CHANGELOG.md) | [releases](https://github.com/avala-ai/4dgs/releases) |

The conformance corpus in that table is not a package. It is the corpus itself, published as a
downloadable archive on its own `releases/corpus/vX.Y.Z` tag, because it changes when variants are
added and that is independent of every SDK's version.

The specification is versioned separately from every package: a package release does not imply a
wire-format change, and a wire-format change is recorded in the
[specification](website/docs/spec/index.md) rather than here.

## Release log

Every release is a tag, and every tag leaves a
[GitHub Release](https://github.com/avala-ai/4dgs/releases) whose body is that version's changelog
section — the releases page and its [Atom feed](https://github.com/avala-ai/4dgs/releases.atom) are
the record, and they are produced by the release workflow rather than by hand. The table below is a
hand-kept index of the same thing, so that the log is readable without leaving the repository;
[RELEASING.md](RELEASING.md) makes adding a line part of cutting a release.

| Date       | Package          | Version | Release                                                                                            |
| ---------- | ---------------- | ------- | -------------------------------------------------------------------------------------------------- |
| 2026-07-28 | Python `fourdgs` | 0.1.0   | [releases/python/v0.1.0](https://github.com/avala-ai/4dgs/releases/tag/releases%2Fpython%2Fv0.1.0) |
| 2026-07-29 | Rust `fourdgs`   | 0.1.0   | [releases/rust/v0.1.0](https://github.com/avala-ai/4dgs/releases/tag/releases%2Frust%2Fv0.1.0)     |
| 2026-07-29 | Python `fourdgs` | 0.2.0   | [releases/python/v0.2.0](https://github.com/avala-ai/4dgs/releases/tag/releases%2Fpython%2Fv0.2.0) |
| 2026-07-29 | Rust `fourdgs`   | 0.2.0   | [releases/rust/v0.2.0](https://github.com/avala-ai/4dgs/releases/tag/releases%2Frust%2Fv0.2.0)     |

`fourdgs 0.0.1` on PyPI, `fourdgs 0.0.1` on crates.io and `@4dgs/core`, `@4dgs/browser`,
`@4dgs/nodejs` and `@4dgs/codecs` at `0.0.1` on npm are name reservations, published by hand before
the release workflow existed. They contain no implementation, have no tag and no release, and
nothing should depend on them.

The TypeScript packages are at 0.5.0 in this repository and have written 0.1.0 through 0.5.0
changelog sections, and are absent from the log above because nothing beyond the 0.0.1 name
reservation has been published: the release job's OIDC exchange has no trusted publisher to exchange
with on npm. The tag will be pushed when it can publish, which is the only thing that puts a line
here. Python 0.4.0 and Rust 0.5.0 follow the same rule — version constants and changelog sections
land on `main` first; tags and registry lines come after.

Dart is at 0.1.0 and has the same shape of wait for a different reason: pub.dev will not accept an
automated publish for a package that does not exist, so `fourdgs` has to be claimed once by hand
before its tag can mean anything. The release workflow's `dart` job is disabled deliberately and
says so, with the two manual steps written where whoever does them will be standing.

Swift is at 0.1.0 and is the one package whose tag *is* the publication — there is no Swift
registry, so consumers resolve it from this repository's URL and a bare `vX.Y.Z` tag is what they
resolve. Nothing has to be configured anywhere for that tag to work.

Swift 0.1.0 has a version constant and a changelog section on `main` and no tag yet. When it is cut
it will be **`v0.1.0`, with no package name in it**, because SwiftPM reads versions only from plain
SemVer tags and there is no registry between it and this repository. That bare tag is the Swift
package's version and not this repository's — the reasoning, and the rule that nothing else may ever
use that tag shape, are in [RELEASING.md](RELEASING.md#swift-tags-look-repository-wide-and-are-not).
