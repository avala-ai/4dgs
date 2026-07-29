// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

// Prints the canonical JSON for a scene built from a fixed seed, with no decoding
// involved. `swift/conformance/selftest.py` builds the same scene and runs it through
// `tests/conformance/canonical.py`; CI asserts the two parse equal.
//
// This exists so that the first disagreement between Swift and Python is about one thing
// at a time. Once the C ABI lands, a mismatch in the suite means the decode is wrong,
// because this says the JSON is not.
import ConformanceSupport

let (scene, gaussians, intervals) = Synthetic.scene()
print(
    Summary.build(
        scene: scene, gaussians: gaussians, chunkIntervals: intervals,
        summaryChecksumVerified: scene.summaryChecksumVerified
    ).serialized())
