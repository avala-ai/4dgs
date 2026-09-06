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

### Added

- Two valid, indexed optional-identity witnesses under `identity/`, one per temporal model. Together
  they pin zero for omitted `source_group`, `source_index` and `object_id`, exact signed and
  same-bit unsigned labels, absent-to-present zero materialization, omitted-update carry,
  omitted-birth zero suffixes, absolute update replacement and complete-keyframe reset. The
  generator tests their physical stream omission, index provenance and deterministic checksums
  independently of any SDK.

- The all-or-none `optionalIdentityDefaults` runner capability and downloadable-manifest marker. The
  shared layer claims no built-in SDK; each language must pass both witnesses on both maintained
  read paths before entering the capability set.

- Eighteen streamed-only `late-front-matter-record` refusal variants: one for every defined
  front-matter opcode under `gaussian-birth`, plus Quantization, Window Table and Object Track
  through the independent `keyframe-delta` loop. Each expectation includes the exact physical late
  record and first state record opcodes and byte offsets.

- The optional `lateFrontMatterRecords` runner capability. It activates the whole structured family
  only for streamed readers and requires the existing `refusals` capability; indexed readers retain
  spec §4's exemption from scanning beyond the first state record. The independent-results catalog
  preserves and validates the same capability in published runner evidence.

- Two valid gaussian-birth Chunk/window-intersection witnesses. Both store one never-fading gaussian
  with Window `[0, 3)` in a Chunk `[1, 2)` and query before, inside, exactly at `t1` and after the
  Chunk. The indexed form is eligible for both read paths; its paired no-index form proves the
  streamed path reads the Chunk gate from the record itself.

- The optional `gaussianBirthChunkWindowIntersection` runner capability and its explicit
  `--gaussian-birth-state-times` invocation. It activates the whole witness family, keeps the
  no-index exemption for indexed readers, and directly compares streamed/indexed instant verdicts
  when both paths are available. No built-in SDK claims it in the shared layer.

### Changed

- The keyframe-delta optional-identity witness now stores `mu_t` as bins at its effective 1/32 s
  pitch. Later keyframes and births reconstruct at their state-record timestamps instead of treating
  those timestamps as raw bins and triggering `keyframe-mu-t-mismatch` before the identity behavior
  could be tested.

- Release manifests now use the same streamed-only registry as the live harness, and correctly
  identify invalid witnesses cut from keyframe-delta bases.

- Release manifest entries now identify an optional `requiredCapability` and the `runnerArguments`
  inserted before a capability-gated file path.

## [0.1.0] - 2026-09-05

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
  its SHA-256 beside it. 74 variants — 48 valid, 5 keyframe-delta, 10 object-layer, 11 that must be
  refused — each as a `.4dgs` and the `.json` a correct decoder must produce from it. 564 KiB
  packed.

- **`corpus/` is byte-for-byte `tests/conformance/data`.** The same names, the same subdirectories,
  the same `CHECKSUMS.txt`. An unpacked corpus is a drop-in replacement for a generated one, so the
  harness in this repository can be pointed at a download rather than at the generator.

- **`corpus/CHECKSUMS.txt`**, the manifest committed in git, packed verbatim. Its format is already
  `sha256sum`'s, so `sha256sum -c CHECKSUMS.txt` verifies the download, and the digests can be
  checked against the repository at the tag without trusting the archive. It covers both each
  `.4dgs` and its `.json` expectation, so a source-archive rebuild cannot bless expectations that
  changed during generation.

- **`MANIFEST.json`**, a machine-readable index: the corpus version and release tag, and per variant
  its paths, both SHA-256s, its byte length, its temporal model, whether a runner reading through
  the chunk index may be asked it, and — for an invalid variant — the refusal identifier a
  conforming reader must produce. Enough for a harness that is not `run.py` to score a runner
  without reading any Python.

- **The archive is reproducible.** Fixed mtime, uid, gid and mode on every member, sorted order, and
  a gzip header with no timestamp, so two builds of the same corpus produce the same bytes and the
  digest on the release page is re-derivable rather than something to be trusted.

- **A licence position, stated in the archive and on the download page.** Apache-2.0, and nothing
  else to clear: every scene is synthetic from a fixed seed, every audio payload is a generated sine
  sweep, and there is no captured data of any kind. The corpus is redistributable by construction
  rather than by permission.
