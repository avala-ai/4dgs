# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Print one version's section from a Keep a Changelog file.

The release workflow runs this before it builds anything, so a version with no section in
its package changelog stops the release while the release can still be abandoned, rather
than reaching the releases page with an empty body. Run it before tagging to read exactly
what the release notes will say:

    python scripts/changelog_section.py python/CHANGELOG.md 0.1.0
"""

from __future__ import annotations

import argparse
import re
import sys

# `## [0.1.0] - 2026-07-28`, `## [0.1.0]` and `## 0.1.0` all name the same version: the
# brackets and the date are conventions rather than requirements, so neither is insisted
# on here. Anything else at this level ends the section.
HEADING = re.compile(r"^##\s+\[?(?P<version>[^\]\s]+)\]?(?:\s+-\s+\S+)?\s*$")


def section(text: str, version: str) -> str | None:
    """The body under `version`'s heading, or None if there is no such heading."""
    lines = text.splitlines()
    start: int | None = None
    for i, line in enumerate(lines):
        match = HEADING.match(line)
        if match is None:
            continue
        if start is not None:
            return "\n".join(lines[start:i]).strip("\n")
        if match.group("version") == version:
            start = i + 1
    if start is None:
        return None
    return "\n".join(lines[start:]).strip("\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Print one version's section from a changelog.")
    parser.add_argument("changelog", help="path to a Keep a Changelog file")
    parser.add_argument("version", help="version to extract, without a leading v")
    args = parser.parse_args(argv)

    try:
        with open(args.changelog, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        print(f"::error::cannot read {args.changelog}: {exc}", file=sys.stderr)
        return 1

    body = section(text, args.version)
    if body is None:
        print(
            f"::error::{args.changelog} has no section for {args.version}. A release without notes "
            "is exactly the drift this gate exists to catch: write the section, then tag.",
            file=sys.stderr,
        )
        return 1
    if not body.strip():
        print(
            f"::error::the {args.version} section of {args.changelog} is empty.",
            file=sys.stderr,
        )
        return 1

    print(body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
