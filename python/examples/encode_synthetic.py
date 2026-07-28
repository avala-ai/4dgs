#!/usr/bin/env python3
# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

"""Encode a synthetic scene, then read back what is visible at an instant.

Runnable and run in CI, so it cannot rot into a snippet that no longer compiles.
"""

from __future__ import annotations

import io

import numpy as np

import fourdgs

rng = np.random.default_rng(1)
n, windows, duration = 5000, 4, 8.0
slot = np.arange(n) % windows
window_len = duration / windows

rotations = rng.normal(0, 1, (n, 4))
rotations /= np.linalg.norm(rotations, axis=1, keepdims=True)

gaussians = fourdgs.GaussianSet(
    positions=rng.normal(0, 0.5, (n, 3)).astype(np.float32),
    scales=np.exp(rng.normal(-7, 0.4, (n, 3))).astype(np.float32),
    rotations=rotations.astype(np.float32),
    colors=rng.uniform(0, 1, (n, 4)).astype(np.float32),
    motions=rng.normal(0, 0.05, (n, 3)).astype(np.float32),
    mu_t=(slot * window_len + rng.uniform(0, window_len, n)).astype(np.float32),
    sigma_t=np.exp(rng.normal(-2, 0.6, n)).astype(np.float32),
    win_lo=(slot * window_len).astype(np.float32),
    win_hi=((slot + 1) * window_len).astype(np.float32),
)

buffer = io.BytesIO()
fourdgs.write(buffer, gaussians, duration)
data = buffer.getvalue()
print(f"encoded {n:,} gaussians over {duration:g}s into {len(data) / 1024:.1f} KiB")

scene = fourdgs.read(data)
state = scene.gaussians.state_at(3.0)
print(f"at t=3.0s: {len(state['indices']):,} of {scene.gaussians.count:,} gaussians are visible")
print("decoding ends here — the centers and opacities above are what a renderer would take")
