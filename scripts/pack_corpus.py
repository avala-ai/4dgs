#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Pack the generated conformance corpus into a release tarball.

    python3 tests/conformance/generate.py          # write the corpus first
    python3 scripts/pack_corpus.py --out dist      # dist/4dgs-conformance-corpus-X.Y.Z.tar.gz
    python3 scripts/pack_corpus.py --version       # print the version and stop

The corpus is generated rather than committed, which is right for this repository and
wrong for everybody else: an outside implementer's only route to the `.4dgs` files is a
clone and a Python generator. This script is the other route. It takes what
`generate.py` wrote and turns it into one file somebody can download, verify and point a
runner at without reading any source in this repository.

Two properties are load-bearing.

**The unpacked `corpus/` directory is byte-for-byte `tests/conformance/data`.** Not a
rearrangement of it — the same names, the same subdirectories, the same `CHECKSUMS.txt`.
So an unpacked corpus is a drop-in replacement for the generated one, and the harness in
this repository can be pointed at a download with a symlink and nothing else.

**The tarball is reproducible.** Every member is written with a fixed mtime, uid, gid and
mode, in sorted order, and gzipped with no timestamp — so two builds of the same corpus
at the same version produce the same bytes, and the digest on the release page is a
statement anyone can re-derive rather than a number they have to trust.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
DATA = os.path.join(ROOT, "tests", "conformance", "data")
CHECKSUMS = os.path.join(DATA, "CHECKSUMS.txt")

#: The corpus's version, and the only place it is written. The release job asserts the tag
#: `releases/corpus/vX.Y.Z` against this string before it builds anything, exactly as every
#: package job asserts its own version constant — a version and a tag that disagree is the
#: one mistake a release cannot take back.
#:
#: 0.1.0 because this is the first publication, and 0.x because the corpus is a rendering
#: of a draft wire format: the bytes change when the format changes, so the corpus cannot
#: promise more stability than the specification it encodes. Like every 0.x release here,
#: the GitHub Release is marked prerelease.
CORPUS_VERSION = "0.1.0"

#: What the tarball and its root directory are called. The version is in both, so two
#: downloads never unpack over each other.
NAME = "4dgs-conformance-corpus"

#: A fixed timestamp for every member, so the archive is a function of its contents alone.
#: Zero rather than a build date: a date is the one field that would make two identical
#: corpora produce two different digests.
EPOCH = 0

#: Bumped when the shape of MANIFEST.json changes in a way a consumer must notice. The
#: corpus version says which files are inside; this says how to read the index of them.
MANIFEST_SCHEMA = 1


def variants() -> list[tuple[str, str]]:
    """Every variant as `(name, relative directory)`, sorted, discovered from disk.

    Walked rather than enumerated so this script carries no knowledge of the corpus's
    shape. `data/keyframe/`, `data/object/` and `data/invalid/` are families the generator
    decided on, and a family added tomorrow is packed without editing this file.
    """
    found = []
    for dirpath, dirnames, filenames in os.walk(DATA):
        dirnames.sort()
        rel = os.path.relpath(dirpath, DATA)
        rel = "" if rel == "." else rel.replace(os.sep, "/")
        for filename in sorted(filenames):
            if filename.endswith(".4dgs"):
                found.append((filename[: -len(".4dgs")], rel))
    return sorted(found, key=lambda pair: (pair[1], pair[0]))


def committed_checksums() -> dict[str, str]:
    """`CHECKSUMS.txt` as a mapping, keyed the way the file names a variant."""
    out: dict[str, str] = {}
    with open(CHECKSUMS, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("#") or not line.strip():
                continue
            digest, name = line.split()
            out[name] = digest
    return out


def sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def describe(name: str, directory: str, path: str, expectation_path: str) -> dict:
    """One entry in `MANIFEST.json`.

    Everything here is derived from the corpus itself, and everything here is something a
    harness would otherwise have to learn by reading `run.py`: which read paths may be
    asked for this variant, which temporal model it uses, and — for an invalid variant —
    which refusal identifier a conforming reader must produce.
    """
    qualified = f"{directory}/{name}" if directory else name
    invalid = directory == "invalid"
    refusal = None
    if invalid:
        with open(expectation_path, encoding="utf-8") as handle:
            refusal = json.load(handle).get("refused")
    return {
        "name": qualified,
        "file": f"corpus/{qualified}.4dgs",
        "expectation": f"corpus/{qualified}.json",
        "family": directory or "valid",
        "bytes": os.path.getsize(path),
        "sha256": sha256(path),
        "expectationSha256": sha256(expectation_path),
        "temporalModel": "keyframe-delta" if directory == "keyframe" else "gaussian-birth",
        # Whether a runner that reads through the chunk index may be asked this variant. A
        # file written without an index cannot be read that way at all; the invalid corpus
        # is the exception, cut from a base that carries one precisely so both read paths
        # can be asked to refuse it. This mirrors `supports()` in the harness, and it is
        # here so an out-of-tree harness does not have to reimplement that rule by reading
        # Python.
        "indexed": invalid or "UseChunkIndex" in name,
        # `null` for a valid variant: it must decode. For an invalid one this is the whole
        # expectation — the identifier of the rule a conforming reader refuses it under.
        "refusal": refusal,
    }


def manifest(entries: list[dict]) -> dict:
    families: dict[str, int] = {}
    for entry in entries:
        families[entry["family"]] = families.get(entry["family"], 0) + 1
    return {
        "corpus": NAME,
        "version": CORPUS_VERSION,
        "manifestSchema": MANIFEST_SCHEMA,
        "repository": "https://github.com/avala-ai/4dgs",
        "tag": f"releases/corpus/v{CORPUS_VERSION}",
        "license": "Apache-2.0",
        "counts": {"variants": len(entries), **{k: families[k] for k in sorted(families)}},
        "variants": entries,
    }


README = """\
# 4dgs conformance corpus {version}

Every `.4dgs` file the 4dgs conformance suite decodes, the JSON each one must decode to, and the
SHA-256 of every file. Downloaded rather than generated: in the repository these `.4dgs` files are
rebuilt from a Python generator on every run and never committed, and this archive is what makes
them usable by somebody who has not cloned it.

- Repository: <https://github.com/avala-ai/4dgs>
- Tag: `releases/corpus/v{version}`
- Documentation: <https://4dgs.dev/docs/reference/conformance>

## Layout

```
{name}-{version}/
  README.md          this file
  LICENSE            Apache-2.0
  NOTICE
  MANIFEST.json      machine-readable index of every variant
  corpus/            byte-for-byte `tests/conformance/data` in the repository
    CHECKSUMS.txt    SHA-256 per .4dgs, `sha256sum -c` compatible
    <variant>.4dgs   the file
    <variant>.json   exactly what a correct decoder must produce from it
    keyframe/        the keyframe-delta temporal model
    object/          the object layer: an Object Table and SE(3) tracks
    invalid/         files a conforming reader must refuse
```

{counts}

## Verify it

```sh
cd {name}-{version}/corpus && sha256sum -c CHECKSUMS.txt
```

`CHECKSUMS.txt` is committed in the repository at `tests/conformance/data/CHECKSUMS.txt`, byte for
byte the file in this archive. So the digests can be checked against git at the tag without trusting
this download, and a corpus that verifies here is the same corpus CI verifies there.

`MANIFEST.json` carries the same digests plus one for every expectation, which `CHECKSUMS.txt` does
not cover.

## Run a decoder against it

A runner is a command-line program that takes one `.4dgs` path and prints one JSON document on
stdout. Score it by diffing that document against the variant's `.json`, parsed rather than as
text:

```sh
for f in corpus/*.4dgs corpus/*/*.4dgs; do
  actual=$(your-runner "$f")
  expected=$(cat "${{f%.4dgs}}.json")
  python3 -c 'import json,sys; sys.exit(json.loads(sys.argv[1]) != json.loads(sys.argv[2]))' \\
    "$actual" "$expected" || echo "FAIL $f"
done
```

`MANIFEST.json` says which variants a runner may skip and why: `indexed` is false for a variant no
index-reading runner can answer, and `refusal` is non-null for a file that must be refused — for
those the document to print is `{{"refused": "<identifier>"}}` and the exit status is still 0,
because a refusal is a result rather than a crash.

The full contract — invocation, stdout, exit codes, the canonical JSON rules — is at
<https://4dgs.dev/docs/reference/conformance>.

## Licence

Apache-2.0, the same as the repository, and there is nothing else to clear. Every scene in this
corpus is synthetic, generated from a fixed seed; every audio payload is a generated sine sweep;
there is no captured data of any kind — no scan, no recording, no photograph, no third-party asset.
The corpus is redistributable by construction rather than by permission, so it may be vendored into
another project's test suite, mirrored, or shipped inside a product's CI image.
"""


def readme(entries: list[dict]) -> str:
    counts: dict[str, int] = {}
    for entry in entries:
        counts[entry["family"]] = counts.get(entry["family"], 0) + 1
    described = ", ".join(f"{counts[family]} {family}" for family in sorted(counts))
    line = f"{len(entries)} variants in this release: {described}."
    return README.format(version=CORPUS_VERSION, name=NAME, counts=line)


def build(out_dir: str) -> str:
    """Write the tarball and its `.sha256`, and return the tarball's path."""
    if not os.path.isdir(DATA) or not os.path.exists(CHECKSUMS):
        print(
            "::error::there is no generated corpus. Run `python3 tests/conformance/generate.py` first — "
            "this script packs what the generator wrote and does not generate anything itself.",
            file=sys.stderr,
        )
        raise SystemExit(1)

    found = variants()
    committed = committed_checksums()
    entries: list[dict] = []
    # Paths are the small archive index; file contents are never retained here.
    # `tarfile.addfile` consumes each handle before the next one is opened.
    path_members: list[tuple[str, str]] = []
    failures: list[str] = []

    for name, directory in found:
        qualified = f"{directory}/{name}" if directory else name
        path = os.path.join(DATA, *(directory.split("/") if directory else []), f"{name}.4dgs")
        expectation_path = path[: -len(".4dgs")] + ".json"
        if not os.path.exists(expectation_path):
            failures.append(f"{qualified}: no expectation beside the file")
            continue
        entry = describe(name, directory, path, expectation_path)
        # Refuse to pack a corpus whose bytes do not match what is committed. `generate.py
        # --verify` asserts the same thing, and this asserts it again over the exact bytes
        # about to be archived: the failure this guards against is a tarball built from a
        # stale or half-regenerated data/ directory, which would publish a corpus that
        # disagrees with the CHECKSUMS.txt packed beside it.
        expected = committed.get(f"{qualified}.4dgs")
        if expected is None:
            failures.append(f"{qualified}: no committed checksum")
        elif expected != entry["sha256"]:
            failures.append(f"{qualified}: {entry['sha256'][:16]}… != committed {expected[:16]}…")
        entries.append(entry)
        path_members.append((entry["file"], path))
        path_members.append((entry["expectation"], expectation_path))

    for name in committed:
        if name not in {entry["file"][len("corpus/") :] for entry in entries}:
            failures.append(f"{name}: committed checksum has no file")

    if failures:
        print("::error::the corpus does not match CHECKSUMS.txt, so it will not be packed", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        print("\nregenerate with `python3 tests/conformance/generate.py` and try again", file=sys.stderr)
        raise SystemExit(1)

    path_members.append(("corpus/CHECKSUMS.txt", CHECKSUMS))
    for source, target in (("LICENSE", "LICENSE"), ("NOTICE", "NOTICE")):
        path_members.append((target, os.path.join(ROOT, source)))
    # These two members are bounded by the small corpus index, not by scene
    # contents. Keeping them in memory lets their exact byte length be declared
    # before the streaming tar writer consumes them.
    generated_members = [
        ("MANIFEST.json", (json.dumps(manifest(entries), indent=2, sort_keys=False) + "\n").encode()),
        ("README.md", readme(entries).encode()),
    ]

    os.makedirs(out_dir, exist_ok=True)
    stem = f"{NAME}-{CORPUS_VERSION}"
    tarball = os.path.join(out_dir, f"{stem}.tar.gz")

    member_names = [name for name, _ in path_members] + [name for name, _ in generated_members]
    directories: set[str] = set()
    for member_name in sorted(member_names):
        parts = member_name.split("/")[:-1]
        for depth in range(len(parts)):
            directories.add("/".join(parts[: depth + 1]))

    # Write gzip, tar framing and each member in one forward-only pipeline.
    # `w|` never seeks and `addfile` reads one source handle at a time, so peak
    # memory is independent of both an individual scene's size and the total
    # corpus size. `filename=""` also keeps the output path out of gzip's header.
    with open(tarball, "wb") as handle:
        with gzip.GzipFile(filename="", fileobj=handle, mode="wb", compresslevel=9, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w|") as archive:
                for directory in sorted(directories):
                    info = tarfile.TarInfo(f"{stem}/{directory}")
                    info.type = tarfile.DIRTYPE
                    info.mode = 0o755
                    info.mtime = EPOCH
                    archive.addfile(info)
                for member_name, source_path in sorted(path_members):
                    info = tarfile.TarInfo(f"{stem}/{member_name}")
                    info.size = os.path.getsize(source_path)
                    info.mode = 0o644
                    info.mtime = EPOCH
                    # uid/gid/uname/gname default to 0 and the empty string on a TarInfo
                    # built by hand, so the archive does not record who built it.
                    with open(source_path, "rb") as payload:
                        archive.addfile(info, payload)
                for member_name, payload in sorted(generated_members):
                    info = tarfile.TarInfo(f"{stem}/{member_name}")
                    info.size = len(payload)
                    info.mode = 0o644
                    info.mtime = EPOCH
                    archive.addfile(info, io.BytesIO(payload))

    digest = sha256(tarball)
    with open(tarball + ".sha256", "w", encoding="utf-8") as handle:
        handle.write(f"{digest}  {stem}.tar.gz\n")

    print(f"{tarball}  {os.path.getsize(tarball) / 1024:.0f} KiB")
    print(f"{len(entries)} variants, {len(path_members) + len(generated_members)} files, sha256 {digest}")
    return tarball


def unpack_and_check(tarball: str, into: str) -> None:
    """Unpack somewhere else and verify every checksum from the manifest.

    Run by the release job before the release is created, so that the thing checked is the
    artifact rather than the directory it was built from. An archive nobody has unpacked is
    an archive whose contents are a hope.
    """
    # `into` is caller-owned. Removing it would both destroy unrelated files and,
    # when it is the output directory or an ancestor, delete the tarball we are
    # about to check. A release check always gets a fresh RUNNER_TEMP path; a
    # local caller gets a controlled refusal instead of a recursive deletion.
    if os.path.lexists(into):
        raise SystemExit(f"::error::the check directory already exists: {into}")
    os.makedirs(into)
    with tarfile.open(tarball) as archive:
        for member in archive.getmembers():
            if not member.isfile() and not member.isdir():
                raise SystemExit(f"::error::{member.name} is neither a file nor a directory")
            if member.name.startswith("/") or ".." in member.name.split("/"):
                raise SystemExit(f"::error::{member.name} escapes the archive root")
        archive.extractall(into)

    stem = f"{NAME}-{CORPUS_VERSION}"
    root = os.path.join(into, stem)
    with open(os.path.join(root, "MANIFEST.json"), encoding="utf-8") as handle:
        index = json.load(handle)
    if index["version"] != CORPUS_VERSION:
        raise SystemExit(f"::error::the manifest says {index['version']}, not {CORPUS_VERSION}")

    failures = []
    for entry in index["variants"]:
        for key, digest_key in (("file", "sha256"), ("expectation", "expectationSha256")):
            path = os.path.join(root, *entry[key].split("/"))
            if not os.path.exists(path):
                failures.append(f"{entry[key]}: missing from the archive")
                continue
            actual = sha256(path)
            if actual != entry[digest_key]:
                failures.append(f"{entry[key]}: {actual[:16]}… != manifest {entry[digest_key][:16]}…")
    if failures:
        print("::error::the unpacked corpus does not match its manifest", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        raise SystemExit(1)
    print(f"unpacked {root}: {len(index['variants'])} variants, every checksum matches")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="pack the generated conformance corpus for release")
    parser.add_argument("--out", default="dist", help="directory to write the tarball into (default: dist)")
    parser.add_argument("--version", action="store_true", help="print the corpus version and exit")
    parser.add_argument("--check", metavar="DIR", help="also unpack into DIR and verify every checksum")
    args = parser.parse_args(argv)

    if args.version:
        print(CORPUS_VERSION)
        return 0

    tarball = build(args.out)
    if args.check:
        unpack_and_check(tarball, args.check)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
