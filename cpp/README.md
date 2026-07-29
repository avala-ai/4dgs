# 4dgs — C++

A C++17 binding over the Rust core's C ABI, for engine, DCC and native-viewer integrators. Not a
second decoder: the bytes are parsed once, in one place, so two implementations cannot drift apart
on what a file means. Decode only at v1; rendering is out of scope for this repository.

|          |                                                                                                 |
| -------- | ----------------------------------------------------------------------------------------------- |
| Standard | C++17, no third-party dependencies                                                              |
| Build    | `cargo build -p fourdgs --release`, then `cmake -S cpp -B cpp/build && cmake --build cpp/build` |
| Test     | `ctest --test-dir cpp/build`, or `make -C cpp test`                                             |
| Headers  | [`include/fourdgs/`](include/fourdgs/)                                                          |
| Target   | `fourdgs::cpp` (static), installs a CMake package                                               |
| Example  | [`examples/decode_summary.cpp`](examples/decode_summary.cpp), run in CI                         |
| Runners  | [`conformance/`](conformance/)                                                                  |

```cpp
auto opened = fourdgs::Scene::openPath("scene.4dgs");
if (!opened) return std::fprintf(stderr, "%s\n", opened.error().toString().c_str());
fourdgs::Scene& scene = **opened;

auto state = scene.stateAt(2.5, /*maxShBand=*/1);   // seeks, and skips the bands above 1
for (std::size_t i = 0; i < state->count(); ++i) {
  std::uint32_t g = state->indices()[i];            // into scene.gaussians()
  // state->centers()[3 * i ...], state->opacity()[i]
}
```

A scene has a working set: `loadAll()` fills it with every chunk, `loadAt(t, cap)` with only the
chunks that instant needs, and `gaussians()` views it. The views point into the decoder's memory and
are invalidated by the next load, so a caller who wants to keep them copies them. `Scene::open`
takes any `Readable`, which is where an HTTP range reader or a cache plugs in.

## Errors are returned, not thrown

Every fallible call returns `fourdgs::Result<T>` — `std::expected` in the subset C++17 allows —
carrying an `ErrorCode` and the sentence the core wrote. The C ABI cannot throw, integrators
routinely build with `-fno-exceptions`, and a truncated download is expected control flow rather
than an exceptional condition. `Result::value()` throws `fourdgs::Exception` for callers who prefer
the other style, so the choice stays theirs. `kUnsupported` (a legal file this build cannot decode)
and `kMalformed` (a bad file) are separate codes, because the fix is different.

## Two builds, and both are supported

With the core, this is a decoder. Without it — before anyone has run `cargo build -p fourdgs` — the
package still compiles and every call returns `ErrorCode::kNotImplemented` with a sentence naming
the fix, while `fourdgs::backendAvailable()` returns `false`. CI builds and tests both, because both
are what somebody gets.

## Status

Decoding works: across the conformance corpus the binding reproduces the reference implementation's
canonical JSON exactly for every gaussian-derived value — the sample, the aggregates, the spherical
harmonic digest, the chunk intervals, the audio digest. It does not yet reproduce the summary's
non-gaussian records — `temporalModel`, header attributes, metadata, attachments, camera,
statistics, summary offsets and the summary CRC — because the C ABI does not expose them yet. Until
it does, no C++ cell in the [feature matrix](../website/docs/reference/index.md) moves off `Planned`
and the `conformance-cpp` job stays disabled: the suite is what promotes a cell, and it has not
passed.
