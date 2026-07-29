# Changelog

All notable changes to the C++ package are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The package: a CMake project (`fourdgs-cpp`, target `fourdgs::cpp`), the public C++17 API over the
  spec's data model, `Result<T>` error handling, `Readable` transports, and the two conformance
  runners.
- Unit tests for the temporal arithmetic of spec §3, the error policy, the transports, and the
  canonical JSON — including the property the whole cross-language comparison rests on, that
  reordering a scene's gaussians cannot change one character of its summary.

### Notes

There is no decoder behind the API yet. A build made without the Rust core's C ABI returns
`ErrorCode::kNotImplemented` from every call and reports `backendAvailable() == false`; the
conformance job is present and disabled, and every C++ cell in the feature matrix stays `Planned`.
Nothing is released from this state.
