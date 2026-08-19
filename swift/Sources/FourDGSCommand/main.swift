// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The process, and nothing else.
///
/// Everything the tool does lives in `FourDGSTool.run`, which takes its arguments as strings and
/// prints to sinks the caller supplies — so the unit tests drive the whole tool, exit code and
/// output together, without spawning a process.

import FourDGSTool
import Foundation

let out = StandardStream.out
let err = StandardStream.err
let code = run(Array(CommandLine.arguments.dropFirst()), out: out, err: err)
exit(processExit(code, out: out, err: err))
