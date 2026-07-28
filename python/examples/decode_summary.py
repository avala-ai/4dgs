#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Open a file the way a seeking client does and report what a seek costs."""

from __future__ import annotations

import io
import sys

import numpy as np

import fourdgs
from fourdgs.indexed_reader import open_indexed
from fourdgs.readable import BytesReadable, FileReadable

if len(sys.argv) > 1:
    source = FileReadable(sys.argv[1])
else:
    # No file given: make one, so the example runs anywhere.
    rng = np.random.default_rng(2)
    n = 3000
    slot = np.arange(n) % 3
    rotations = rng.normal(0, 1, (n, 4))
    rotations /= np.linalg.norm(rotations, axis=1, keepdims=True)
    gaussians = fourdgs.GaussianSet(
        positions=rng.normal(0, 0.5, (n, 3)).astype(np.float32),
        scales=np.exp(rng.normal(-7, 0.4, (n, 3))).astype(np.float32),
        rotations=rotations.astype(np.float32),
        colors=rng.uniform(0, 1, (n, 4)).astype(np.float32),
        motions=rng.normal(0, 0.05, (n, 3)).astype(np.float32),
        mu_t=(slot * 2.0 + rng.uniform(0, 2.0, n)).astype(np.float32),
        sigma_t=np.exp(rng.normal(-2, 0.6, n)).astype(np.float32),
        win_lo=(slot * 2.0).astype(np.float32),
        win_hi=((slot + 1) * 2.0).astype(np.float32),
    )
    buffer = io.BytesIO()
    fourdgs.write(buffer, gaussians, 6.0, options=fourdgs.WriteOptions(min_chunk_gaussians=100))
    source = BytesReadable(buffer.getvalue())

scene = open_indexed(source)
print(f"{scene.header.gaussian_count:,} gaussians, {scene.header.duration_sec:g}s, {len(scene.index)} chunks")
print(f"audio: {scene.audio_codec if scene.has_audio else 'none'}")
for t in (0.0, 2.5, 5.0):
    entries = scene.chunks_for_time(t)
    print(f"  t={t:4.1f}s  {len(entries)} ranges, {scene.bytes_for_time(t) / 1024:.1f} KiB")
