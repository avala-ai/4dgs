# 4dgs — C++

A C++17 binding over the Rust core's C ABI, for engine, DCC and native-viewer integrators. Not a
second decoder: the bytes are parsed once, in one place, so two implementations cannot drift apart
on what a file means. Decode only at v1; rendering is out of scope for this repository.

|          |                                                                                      |
| -------- | ------------------------------------------------------------------------------------ |
| Standard | C++17, no third-party dependencies                                                   |
| Build    | `cmake -S cpp -B cpp/build && cmake --build cpp/build && ctest --test-dir cpp/build` |
| Headers  | [`include/fourdgs/`](include/fourdgs/)                                               |
| Target   | `fourdgs::cpp` (static), installs a CMake package                                    |
| Runners  | [`conformance/`](conformance/)                                                       |

```cpp
auto file = fourdgs::FileReadable::open("scene.4dgs");
auto reader = fourdgs::IndexedReader::open(**file).value();
for (const auto* entry : reader->chunksFor(2.5)) {          // spec §8, the whole seek
  auto chunk = reader->readChunk(*entry, /*maxShBand=*/1);  // bands above 1 never transfer
  auto state = fourdgs::stateAt(fourdgs::GaussianView(*chunk), 0, 2.5, reader->header().cutoff);
}
```

## Errors are returned, not thrown

Every fallible call returns `fourdgs::Result<T>` — `std::expected` in the subset C++17 allows —
carrying an `ErrorCode` and the sentence the core wrote. The C ABI cannot throw, integrators
routinely build with `-fno-exceptions`, and a truncated download is expected control flow rather
than an exceptional condition. `Result::value()` throws `fourdgs::Exception` for callers who prefer
the other style, so the choice stays theirs. `kUnsupported` (a legal file this build cannot decode)
and `kMalformed` (a bad file) are separate codes, because the fix is different.

## Status

The API is complete and the decoder behind it is not. Until the core lands this builds without one:
every call returns `ErrorCode::kNotImplemented`, `fourdgs::backendAvailable()` returns `false`, and
nothing claims a `Yes` in the [feature matrix](../website/docs/reference/index.md). CMake compiles
the binding against the ABI instead when `../rust/fourdgs/include/fourdgs.h` exists and the crate
has been built with `cargo build -p fourdgs --release`.
