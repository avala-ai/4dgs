// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

// Reads the Footer and the index, then only the chunks the index names — the same JSON as
// the streamed runner, derived from the same expectation by a different access pattern.
// `run.py` runs this one only on variants whose name carries `UseChunkIndex`.
import ConformanceSupport

Runner.main(.indexed)
