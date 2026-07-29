# Decode in C++

For engine, DCC and native-viewer integrators. The C++ package is a thin binding over the Rust
core's C ABI rather than a second decoder, so the bytes are parsed once, in one place. See the
[feature matrix](../../reference/index.md) for what the conformance suite proves today.

## Build

The core first, then the binding:

```sh
cargo build -p fourdgs --release
cmake -S cpp -B cpp/build && cmake --build cpp/build
```

CMake finds the core beside the crate; `-DFOURDGS_CORE_LIBRARY=` points it elsewhere. The package
installs a CMake target, `fourdgs::cpp`. It is C++17 and has no third-party dependencies.

## Decode

```cpp
#include "fourdgs/fourdgs.hpp"

auto opened = fourdgs::Scene::openPath("scene.4dgs");
if (!opened) return std::fprintf(stderr, "%s\n", opened.error().toString().c_str());
fourdgs::Scene& scene = **opened;

auto state = scene.stateAt(2.5, /*maxShBand=*/3);
for (std::size_t i = 0; i < state->count(); ++i) {
  std::uint32_t g = state->indices()[i];   // indexes scene.gaussians()
  // state->centers()[3 * i ...], state->opacity()[i]
}
```

A scene has a working set: `loadAll()` fills it with every chunk, `loadAt(t, cap)` with only the
chunks that instant needs, and `gaussians()` views it without copying. `bytesForTime(t, cap)` says
what a seek will transfer before you pay for it — seek cost is a property of the content, not of the
container. `maxShBand` caps spherical harmonics, and the bands above it are never transferred.

Errors are returned rather than thrown, because the ABI cannot throw and integrators routinely build
with `-fno-exceptions`; `Result::value()` throws for callers who prefer that.
`ErrorCode::kUnsupported` — a legal file this build cannot decode — and `kMalformed` — a bad file —
are separate codes, because the fix is different.

## Your own transport

The decoder reads through one abstraction, so an HTTP range reader or a cache is a subclass of
`fourdgs::Readable` and nothing else changes:

```cpp
class HttpRange : public fourdgs::Readable {
  fourdgs::Result<std::uint64_t> size() override;
  fourdgs::Result<std::size_t> read(std::uint64_t offset, fourdgs::Span<std::uint8_t> into) override;
};
```

Then `fourdgs::Scene::open(transport)`. A short read at the end of a resource is truncation, which
the decoder recovers from, rather than an error the transport should raise.

## Where decoding ends

At reconstructed gaussian state at time `t`. Ordering, culling, level of detail and anything
touching a GPU belong to whatever draws the splats, which is not this repository.

[`cpp/examples/decode_summary.cpp`](https://github.com/avala-ai/4dgs/blob/main/cpp/examples/decode_summary.cpp)
is the whole of the above in one file, and CI runs it.
