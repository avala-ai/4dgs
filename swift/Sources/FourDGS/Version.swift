// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The version of this package, as one constant.
///
/// SwiftPM has no version field in `Package.swift` — a Swift package's version is the Git tag it
/// was resolved at, and nothing inside the package states it. That leaves nothing for a release
/// to be checked against, so this constant is it: the release workflow asserts it against the tag
/// before it builds anything, exactly as the other packages here assert theirs.
///
/// It is also the answer to "which 4dgs is linked into this app?" from inside a shipped binary,
/// where the tag is no longer around to read.
public let fourdgsPackageVersion = "0.2.0"
