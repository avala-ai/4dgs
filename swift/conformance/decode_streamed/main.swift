// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

// Reads the file front to back, no seeking, and prints the canonical JSON of everything
// it found. Declares support for every variant: streaming is the path that works on a
// file with no index.
import ConformanceSupport

Runner.main(.streamed)
