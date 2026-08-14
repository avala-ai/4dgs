# 4dgs — C++

<!-- cspell:ignore rustc -->

A C++17 binding over the Rust core's C ABI, for engine, DCC and native-viewer integrators. Not a
second decoder: the bytes are parsed once, in one place, so two implementations cannot drift apart
on what a file means. Decode only at v1; rendering is out of scope for this repository.

|          |                                                                                                 |
| -------- | ----------------------------------------------------------------------------------------------- |
| Standard | C++17; a Rust toolchain builds the core for source consumers                                    |
| Build    | `cargo build -p fourdgs --release`, then `cmake -S cpp -B cpp/build && cmake --build cpp/build` |
| Test     | `ctest --test-dir cpp/build`, or `make -C cpp test`                                             |
| Headers  | [`include/fourdgs/`](include/fourdgs/)                                                          |
| Target   | `fourdgs::cpp` (static); installed as the `fourdgs-cpp` CMake package                           |
| Consume  | [CPM, `find_package`, `add_subdirectory`](#consuming-this-package-from-another-project)         |
| Example  | [`examples/decode_summary.cpp`](examples/decode_summary.cpp), run in CI                         |
| Runners  | [`conformance/`](conformance/)                                                                  |
| Tool     | `cpp/build/tools/4dgs inspect\|validate <file>` — see below                                     |

```cpp
auto opened = fourdgs::Scene::openPath("scene.4dgs");
if (!opened) return std::fprintf(stderr, "%s\n", opened.error().toString().c_str());
fourdgs::Scene& scene = **opened;

auto state = scene.stateAt(2.5, /*maxShBand=*/1);   // seeks, and skips the bands above 1
for (std::size_t i = 0; i < state->count(); ++i) {
  std::uint32_t g = state->indices()[i];            // into scene.gaussians()
  // state->centers()[3 * i ...], state->opacity()[i]
}

for (std::uint32_t i = 0; i < scene.audioSourceCount(); ++i) {
  auto source = scene.audioSource(i);               // descriptor only; no payload transfer
  auto sourceState = scene.audioSourceStateAt(i, 2.5);
  if (sourceState && sourceState->active) {
    // Combine sourceState->position/rotation with the player's listener pose.
    // The player owns HRTF/panning, distance attenuation, occlusion and mixing.
  }
}
```

A scene has a working set: `loadAll()` fills it with every chunk, `loadAt(t, cap)` with only the
chunks that instant needs, and `gaussians()` views it. The views point into the decoder's memory and
are invalidated by the next load, so a caller who wants to keep them copies them. `Scene::open`
takes any `Readable`, which is where an HTTP range reader or a cache plugs in.

## Consuming this package from another project

The CMake manifest is `cpp/CMakeLists.txt`, not a `CMakeLists.txt` at the root of the repository —
there is no such file, because this repository holds six SDKs and no build system owns all of them.
Every fetch below therefore has to say which subdirectory the manifest is in, and
[CPM.cmake](https://github.com/cpm-cmake/CPM.cmake) has an argument for exactly that. It is a thin
wrapper over `FetchContent`, so it consumes this repository at a ref and there is nothing to publish
anywhere first.

```cmake
include(cmake/CPM.cmake)

CPMAddPackage(
  NAME fourdgs-cpp
  GITHUB_REPOSITORY avala-ai/4dgs
  GIT_TAG main                  # or a commit SHA; pin one, this is a 0.x wire format
  SOURCE_SUBDIR cpp             # the manifest is cpp/CMakeLists.txt — without this, CPM
                                # looks for a CMakeLists.txt at the repository root, finds
                                # none, and adds nothing at all
)

target_link_libraries(my_app PRIVATE fourdgs::cpp)
```

Plain `FetchContent` is the same two lines with the same argument
(`FetchContent_Declare(... SOURCE_SUBDIR cpp)`), and a git submodule or a vendored copy is
`add_subdirectory(third_party/4dgs/cpp)`. All three go through the same manifest, and all three
build the library alone: the tests, the conformance runners and the examples default to on only when
this is the top-level project, so consuming the package does not add ten targets and an
`enable_testing()` to your build. When no prebuilt core is named, CMake finds Cargo and builds the
Rust core into that dependency's CMake build directory. A missing Rust toolchain is therefore a
configure-time error with its name, not an unresolved symbol at the end of a C++ link.

Against an installed copy — `cmake --install <build dir> --prefix <prefix>` — it is `find_package`:

```cmake
find_package(fourdgs-cpp 0.1 REQUIRED)      # configure with -DCMAKE_PREFIX_PATH=<prefix>
target_link_libraries(my_app PRIVATE fourdgs::fourdgs-cpp)
```

The install carries a config file and a version file, so a version range is a supported request;
while the major version is 0 the minor is the compatibility boundary, so a build asking for 0.1 is
not handed 0.2. The exported target is `fourdgs::fourdgs-cpp` and `fourdgs::cpp` is defined beside
it, so either name links whichever way the package arrived. The installed package includes the
static Rust core it was built against; downstream `find_package` consumers need neither this source
tree nor Cargo, and the core path stays valid if the install prefix moves. If a prebuilt core was
named through a symbolic link, installation copies the target archive rather than exporting a link
whose relative target exists only in the build tree.

### How the core is obtained

This package is a binding over the Rust core's C ABI rather than a second decoder. A source fetch
contains that crate, and `FOURDGS_BUILD_CORE_FROM_SOURCE` defaults to `ON` for CPM, FetchContent and
`add_subdirectory` consumers. It runs the equivalent of
`cargo rustc -p fourdgs --release --target <triple> --lib --crate-type staticlib` with an isolated
target directory under the CMake build, then makes the C++ library depend on and link the result.
The crate manifest and source are staged under that writable build directory as well, so Cargo's
uncommitted library lockfile never mutates a fetched dependency and read-only source checkouts work.
Selecting only the static library avoids making a cross build link the crate's unrelated `cdylib`
with a Cargo linker configuration the CMake toolchain does not control. A native build derives the
triple from `cargo -vV`; a cross build must name the toolchain's Rust triple with
`FOURDGS_CARGO_TARGET`, so it cannot silently build a host archive for a target linker. The same
requirement applies when `CMAKE_CXX_COMPILER_TARGET`, Visual Studio `-A`, or
`CMAKE_OSX_ARCHITECTURES` selects a target without setting CMake's cross-compiling flag, and when a
compiler mode such as `-m32` changes the detected pointer ABI. A universal macOS build needs a
pre-combined `FOURDGS_CORE_LIBRARY`; one Cargo target can only produce a thin archive. Building the
same checkout at two revisions cannot make them share one `target/` tree.

A consumer that already has a core can skip that build by naming it. The header defaults to the one
in a fetched repository; a vendored copy of `cpp/` alone supplies both paths:

| Variable                  | What it points at                                                          |
| ------------------------- | -------------------------------------------------------------------------- |
| `FOURDGS_CORE_HEADER_DIR` | the directory holding `fourdgs.h`                                          |
| `FOURDGS_CORE_LIBRARY`    | `libfourdgs.a` (or `fourdgs.lib`), from `cargo build -p fourdgs --release` |
| `FOURDGS_CARGO_TARGET`    | Rust target triple matching a cross-compiling CMake toolchain              |

On MSVC the Rust static library uses the dynamic release runtime. The exported CMake target carries
that requirement into Debug consumers too (`/MD`, not `/MDd`), because C++ strings and vectors cross
the binding's public boundary and allocator mismatches are not link-only problems.

`FOURDGS_BUILD_CORE_FROM_SOURCE=OFF` plus `FOURDGS_ALLOW_NO_CORE=ON` remains the deliberate
no-decoder build: it compiles and every decode call returns `kNotImplemented`. Source-building is a
stronger request than the permission to fall back to no core, so the repository's natural top-level
opt-in is just `-DFOURDGS_BUILD_CORE_FROM_SOURCE=ON` even though `FOURDGS_ALLOW_NO_CORE` defaults on
there. A Cargo failure still stops that build; it never silently falls back to the stub.

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

A core is a header and a library, and it can be absent either way: pointed somewhere with no
`fourdgs.h`, or — the ordinary case in a fresh checkout, where the header is committed and the
archive is a build artifact — with the header present and nothing under `target/`. Both are the same
build with no decoder, and configuring again after `cargo build -p fourdgs --release` picks the core
up in the same build directory.

That is the default only in this repository, where the core is one `cargo build` away and building
before it is a normal thing to do. Anywhere else, a library that refuses every call is not what
whoever fetched it asked for, so the build stops instead — `-DFOURDGS_ALLOW_NO_CORE=ON` asks for it
deliberately, which is the only way a consumer should end up with one.

## `4dgs`: inspect and validate

When someone reports a file that will not open, the first question is _where_ it stops being a 4dgs
file. `cpp/build/tools/4dgs` answers it without a Python environment:

```console
$ 4dgs inspect scene.4dgs           # offset, record, content, total, crc — nine bytes per record
$ 4dgs validate scene.4dgs          # every finding, and the rule that refused the file
error: a chunk does not decode: unsupported codec: stream codec 9 is not a codec this build implements
  refusal unknown-stream-codec at byte 659 (the Chunk record at index entry 0)
INVALID
```

The `refusal` line is the identifier from `Error::refusal` and the byte the tool's own framing walk
places it at. `validate` decodes the chunks — one resident at a time on the indexed path — because a
framing walk steps _over_ a chunk rather than into it, and two of the refusals the specification
names fire inside a chunk's streams. Every spherical-harmonic band the file declares is decoded too,
for the same reason one step further in: a band is its own record fetched by byte range, so a scan
capped at band 0 never transfers one, and a refusing band names its own record. A `keyframe-delta`
file is validated against the model its Header declares rather than against the gaussian-birth chunk
shape.

Both commands read ranges rather than files. `inspect` transfers nine bytes per record and the
checksummed region; `validate` opens the scene over the same transport. For `keyframe-delta`, it
passes that reader through `fourdgs_validate_keyframe_delta_reader`, whose indexed and sequential
modes validate the file within their declared bounds without first buffering the whole resource.

Exit codes: **0** fine, **1** refused or invalid, **2** valid with warnings, **3** the tool could
not run — a missing file, an argument it does not understand, or a build with no decoder behind it.
`1` is an answer about the file; `3` is the absence of one, and a pipeline that could not tell them
apart could not tell a corrupt asset from a typo in a path.

Because this package is a binding and not a parser, `validate` checks what needs no record parser —
framing, the records a file must carry, where the chunk index points, the summary checksum — plus
everything the reader itself decides. It reports a subset of what the Python tool's `4dgs validate`
says and never contradicts it.

## Status

Conformance-verified: **79 checks across the 45 valid variants this binding supports**, with the
read path forced at open rather than left to the opener, so the streamed and indexed rows rest on
two paths and not one. The [feature matrix](../website/docs/reference/index.md) records exactly what
that proves. Encode is there too, and in both shapes: `fourdgs::encodeScene` authors a
`gaussian-birth` scene and `fourdgs::encodeKeyframeDeltaSequence` a whole `keyframe-delta` file
(spec §11) from a sequence of populations with `gaussian_id` identity between them. Both are
bindings over the core's writer rather than second encoders, so what their gates prove is that the
gaussians, the samples and the options were wired through — for keyframe-delta, by requiring the
file to be byte for byte the one the Rust reference writer produces from the same input.
