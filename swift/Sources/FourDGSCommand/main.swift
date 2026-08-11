// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The process, and nothing else.
///
/// Everything the tool does lives in `FourDGSTool.run`, which takes its arguments as strings and
/// prints to sinks the caller supplies — so the unit tests drive the whole tool, exit code and
/// output together, without spawning a process.

import FourDGSTool
import Foundation

exit(run(Array(CommandLine.arguments.dropFirst()), out: StandardStream.out, err: StandardStream.err))
