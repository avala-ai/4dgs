# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Shared protocol constants for the gaussian-birth Chunk/window gate.

The generated files, live harness, release manifest and future SDK runners must name
one capability and one query identically. Keeping those values here prevents a corpus
that asks one question while the downloadable manifest documents another.
"""

FAMILY = "chunk-window-intersection"
PREFIX = f"{FAMILY}/"
CAPABILITY = "gaussianBirthChunkWindowIntersection"
MARKER = "gaussian-birth-chunk-window-intersection-v1"
STATE_TIMES_ARG = "--gaussian-birth-state-times"
PROBE_TIMES = (0.5, 1.5, 2.0, 2.5)


def runner_arguments() -> tuple[str, str]:
    """Arguments inserted before the path for either generated witness."""
    return STATE_TIMES_ARG, "[0.5,1.5,2.0,2.5]"
