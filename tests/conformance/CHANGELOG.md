# Changelog

All notable changes to the published conformance corpus are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This is the changelog of the **corpus as a download**, not of the conformance suite as a whole. It
is versioned on its own tag, `releases/corpus/vX.Y.Z`, because the set of variants changes when
variants are added and that has nothing to do with any SDK's version. The release job reads the
section matching the tag and refuses to publish a version nothing is written about.

What each part of the version means here:

- **Major** — the archive's own shape changes: a directory moves, `MANIFEST.json` gains a meaning a
  consumer cannot ignore, or a variant is removed. A runner scored against the previous corpus may
  no longer be scored against this one without a change.
- **Minor** — variants are added, or the wire format the corpus encodes changes and every `.4dgs` is
  regenerated. Scores are comparable in kind but not in denominator.
- **Patch** — the same variants, repacked: a fix to the archive's metadata, its README, or its
  manifest, with every `.4dgs` byte-identical to the release before it.

## [Unreleased]

## [0.1.0] - 2026-08-10

The first publication of the corpus. Until now the only route to the `.4dgs` files was cloning the
repository and running a Python generator, which made "prove your decoder correct" a thing only the
six SDKs in this repository could do.

**0.1.0 rather than 1.0.0** because the corpus is a rendering of a draft wire format. Its bytes are
determined by a specification whose minor versions may still change the format, so the corpus cannot
promise more stability than the thing it encodes; a 1.0.0 would claim a stability nothing behind it
has. The archive is marked prerelease on the releases page for the same reason every 0.x package
release here is. The corpus becomes 1.0.0 when version 1 of the specification is declared stable.

### Added

- **`4dgs-conformance-corpus-X.Y.Z.tar.gz`**, attached to the `releases/corpus/vX.Y.Z` release with
  its SHA-256 beside it. 60 variants — 46 valid, 4 keyframe-delta, 3 object-layer, 7 that must be
  refused — each as a `.4dgs` and the `.json` a correct decoder must produce from it. 519 KiB
  packed.

- **`corpus/` is byte-for-byte `tests/conformance/data`.** The same names, the same subdirectories,
  the same `CHECKSUMS.txt`. An unpacked corpus is a drop-in replacement for a generated one, so the
  harness in this repository can be pointed at a download rather than at the generator.

- **`corpus/CHECKSUMS.txt`**, the manifest committed in git, packed verbatim. Its format is already
  `sha256sum`'s, so `sha256sum -c CHECKSUMS.txt` verifies the download, and the digests can be
  checked against the repository at the tag without trusting the archive.

- **`MANIFEST.json`**, a machine-readable index: the corpus version, the commit it was generated
  from, and per variant its paths, both SHA-256s, its byte length, its temporal model, whether a
  runner reading through the chunk index may be asked it, and — for an invalid variant — the refusal
  identifier a conforming reader must produce. Enough for a harness that is not `run.py` to score a
  runner without reading any Python.

- **The archive is reproducible.** Fixed mtime, uid, gid and mode on every member, sorted order, and
  a gzip header with no timestamp, so two builds of the same corpus produce the same bytes and the
  digest on the release page is re-derivable rather than something to be trusted.

- **A licence position, stated in the archive and on the download page.** Apache-2.0, and nothing
  else to clear: every scene is synthetic from a fixed seed, every audio payload is a generated sine
  sweep, and there is no captured data of any kind. The corpus is redistributable by construction
  rather than by permission.
