# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.20)
project(
  fourdgs-cpp
  VERSION 0.1.0
  DESCRIPTION "C++ binding for the 4dgs container format"
  LANGUAGES CXX)

# This project is consumed two ways and they want different defaults. In this repository it
# is the top-level project and everything it can build should build: the tests, the
# conformance runners and the examples are what CI checks. Fetched into somebody else's
# build — by CPM, FetchContent or a plain add_subdirectory — it is a dependency, and a
# dependency that adds ten targets, an `enable_testing()` and a test that reads a corpus
# from a directory the consumer does not have is a dependency that made their build worse.
#
# PROJECT_IS_TOP_LEVEL says exactly this, and arrived in CMake 3.21; this project supports
# 3.20, so the one line it would be is spelled out here instead.
if(CMAKE_CURRENT_SOURCE_DIR STREQUAL CMAKE_SOURCE_DIR)
  set(FOURDGS_IS_TOP_LEVEL ON)
else()
  set(FOURDGS_IS_TOP_LEVEL OFF)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT DEFINED CMAKE_POSITION_INDEPENDENT_CODE)
  set(CMAKE_POSITION_INDEPENDENT_CODE ON)
endif()

# Multi-config generators — Visual Studio is the one that matters here — append the
# configuration name to every output directory, so a runner the harness expects at
# build/conformance/decode_streamed lands at build/conformance/Release/decode_streamed.exe
# instead. Setting the per-configuration property as well as the plain one pins the
# output back to a single place on every generator, which is what lets the conformance
# harness name these paths in one line rather than guessing at a configuration.
function(fourdgs_pin_runtime_output target directory)
  set_target_properties(${target} PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${directory}")
  foreach(config IN LISTS CMAKE_CONFIGURATION_TYPES)
    string(TOUPPER "${config}" config_upper)
    set_target_properties(${target} PROPERTIES RUNTIME_OUTPUT_DIRECTORY_${config_upper}
                                               "${directory}")
  endforeach()
endfunction()

option(FOURDGS_BUILD_TESTS "Build the unit tests" ${FOURDGS_IS_TOP_LEVEL})
option(FOURDGS_BUILD_CONFORMANCE "Build the conformance runners" ${FOURDGS_IS_TOP_LEVEL})
option(FOURDGS_ASAN "Build with the address and undefined-behaviour sanitizers" OFF)

# Where the Rust core's C ABI lives. The header is committed by the core; the library is a
# build artifact, so it is looked for where cargo puts it and can be pointed elsewhere.
set(FOURDGS_CORE_HEADER_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../rust/fourdgs/include"
    CACHE PATH "Directory containing fourdgs.h from the Rust core")
set(FOURDGS_CORE_LIBRARY
    ""
    CACHE FILEPATH "The Rust core's C-linkable library; searched for when empty")

# Whether a build with no core is a configuration or a mistake depends on who is building,
# so the question is answered before it is asked.
#
# Somebody working in a checkout of avala-ai/4dgs, with this as their top-level project,
# gets the no-core build: the core is one `cargo build -p fourdgs --release` away, and
# building before that is a supported configuration CI exercises on every platform — it is
# what an integrator gets before they have built the crate, and its tests assert that every
# call refuses with kNotImplemented rather than quietly decoding nothing.
#
# Anyone else is consuming this package: CPM, FetchContent, add_subdirectory, or a copy of
# this directory on its own. They asked for a decoder, and handing them a library that
# refuses every call — announced in a STATUS line among a hundred others — is a failure
# they find much later and from the wrong end. They get a fatal error naming what to
# supply, and -DFOURDGS_ALLOW_NO_CORE=ON if the stub is what they actually want.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../rust/fourdgs/Cargo.toml")
  set(FOURDGS_IN_REPOSITORY ON)
else()
  set(FOURDGS_IN_REPOSITORY OFF)
endif()
if(FOURDGS_IS_TOP_LEVEL AND FOURDGS_IN_REPOSITORY)
  set(FOURDGS_ALLOW_NO_CORE_DEFAULT ON)
else()
  set(FOURDGS_ALLOW_NO_CORE_DEFAULT OFF)
endif()
option(FOURDGS_ALLOW_NO_CORE
       "Configure without a decoder rather than failing when the core cannot be found"
       ${FOURDGS_ALLOW_NO_CORE_DEFAULT})

# A fetched checkout contains the Rust crate but not its build artifact. In that shape the
# least surprising package is one that asks Cargo to produce the core as part of the CMake
# build: the consumer stated the toolchain requirement by choosing the source distribution,
# and should not have to discover and reproduce this repository's cargo command themselves.
#
# Keep the repository's top-level default unchanged. Its explicit no-core build is a tested
# development configuration, and its ordinary with-core build already runs Cargo first. An
# out-of-tree CPM/FetchContent/add_subdirectory consumer gets source-building by default; an
# explicitly supplied archive always wins, and an intentional no-core consumer can disable
# this option while enabling FOURDGS_ALLOW_NO_CORE.
if(FOURDGS_IN_REPOSITORY AND NOT FOURDGS_IS_TOP_LEVEL AND NOT FOURDGS_ALLOW_NO_CORE)
  set(FOURDGS_BUILD_CORE_FROM_SOURCE_DEFAULT ON)
else()
  set(FOURDGS_BUILD_CORE_FROM_SOURCE_DEFAULT OFF)
endif()
option(FOURDGS_BUILD_CORE_FROM_SOURCE
       "Build the Rust core with Cargo when no prebuilt FOURDGS_CORE_LIBRARY is supplied"
       ${FOURDGS_BUILD_CORE_FROM_SOURCE_DEFAULT})

if(FOURDGS_BUILD_CORE_FROM_SOURCE AND FOURDGS_ALLOW_NO_CORE)
  message(
    FATAL_ERROR
      "FOURDGS_BUILD_CORE_FROM_SOURCE and FOURDGS_ALLOW_NO_CORE are mutually exclusive: "
      "choose a decoder built by Cargo, or the deliberate no-decoder binding")
endif()

# Define the core build before resolving the backend so the generated archive is a normal
# build dependency even though it does not exist at configure time. The output is isolated
# under this CMake build tree: two consumers at different revisions cannot share or overwrite
# a repository-level target/ directory.
set(FOURDGS_BUILD_CORE_FROM_SOURCE_ACTIVE OFF)
if(FOURDGS_BUILD_CORE_FROM_SOURCE AND FOURDGS_CORE_LIBRARY STREQUAL "")
  if(NOT FOURDGS_IN_REPOSITORY)
    message(
      FATAL_ERROR
        "FOURDGS_BUILD_CORE_FROM_SOURCE requires the repository checkout containing "
        "rust/fourdgs/Cargo.toml; either fetch avala-ai/4dgs rather than cpp/ alone, or set "
        "FOURDGS_CORE_HEADER_DIR and FOURDGS_CORE_LIBRARY to a prebuilt core")
  endif()

  find_program(FOURDGS_CARGO_EXECUTABLE cargo REQUIRED)
  set(FOURDGS_CORE_SOURCE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/..")
  set(FOURDGS_CORE_TARGET_DIR "${CMAKE_CURRENT_BINARY_DIR}/rust-core")
  if(MSVC)
    set(FOURDGS_GENERATED_CORE_LIBRARY "${FOURDGS_CORE_TARGET_DIR}/release/fourdgs.lib")
  else()
    set(FOURDGS_GENERATED_CORE_LIBRARY "${FOURDGS_CORE_TARGET_DIR}/release/libfourdgs.a")
  endif()

  file(GLOB_RECURSE FOURDGS_CORE_RUST_SOURCES CONFIGURE_DEPENDS
       "${FOURDGS_CORE_SOURCE_ROOT}/rust/fourdgs/src/*.rs")
  add_custom_command(
    OUTPUT "${FOURDGS_GENERATED_CORE_LIBRARY}"
    COMMAND
      # Make/NMake jobserver descriptors are not portable through a custom-command shell;
      # clearing their hint lets Cargo manage its own parallelism instead of warning that
      # CMake advertised file descriptors it could not inherit. Ninja does not set it.
      "${CMAKE_COMMAND}" -E env "CARGO_TARGET_DIR=${FOURDGS_CORE_TARGET_DIR}" "MAKEFLAGS="
      "${FOURDGS_CARGO_EXECUTABLE}" build --manifest-path
      "${FOURDGS_CORE_SOURCE_ROOT}/Cargo.toml" --package fourdgs --release
    DEPENDS
      "${FOURDGS_CORE_SOURCE_ROOT}/Cargo.toml"
      "${FOURDGS_CORE_SOURCE_ROOT}/rust/fourdgs/Cargo.toml"
      ${FOURDGS_CORE_RUST_SOURCES}
    WORKING_DIRECTORY "${FOURDGS_CORE_SOURCE_ROOT}"
    COMMENT "Building the 4dgs Rust core"
    VERBATIM
    USES_TERMINAL)
  add_custom_target(fourdgs-core-build DEPENDS "${FOURDGS_GENERATED_CORE_LIBRARY}")
  set(FOURDGS_CORE_LIBRARY "${FOURDGS_GENERATED_CORE_LIBRARY}")
  set(FOURDGS_BUILD_CORE_FROM_SOURCE_ACTIVE ON)
endif()

# The seam, resolved: with a core the binding calls the ABI, without one it refuses every
# call with kNotImplemented. Both configurations build, and both are honest — the package
# never links against a decoder it does not have.
#
# A core is a header AND a library, and this asks for both before choosing a backend. It
# used to choose on the header alone and look for the library afterwards, where a miss
# could only be fatal — so in a fresh checkout, where `rust/fourdgs/include/fourdgs.h` is
# committed and `target/release/libfourdgs.a` is not, `cmake -S cpp -B cpp/build` before
# `cargo build` failed outright and `-DFOURDGS_ALLOW_NO_CORE=ON` could not rescue it. That
# is exactly the configuration the option exists for, and exactly the order somebody
# arriving at this repository does things in.
set(FOURDGS_HAVE_CORE OFF)
set(FOURDGS_BACKEND_SOURCE src/backend_unavailable.cpp)

if(NOT EXISTS "${FOURDGS_CORE_HEADER_DIR}/fourdgs.h")
  if(NOT FOURDGS_ALLOW_NO_CORE)
    message(
      FATAL_ERROR
        "fourdgs: no core header at ${FOURDGS_CORE_HEADER_DIR}/fourdgs.h.\n"
        "This package is a binding over the Rust core's C ABI, not a second decoder, so it "
        "needs that core's header and library. Both are produced by a checkout of "
        "avala-ai/4dgs and neither is fetched with this directory, which is why a build "
        "outside that repository has to say where they are:\n"
        "  -DFOURDGS_CORE_HEADER_DIR=<directory containing fourdgs.h>   (rust/fourdgs/include)\n"
        "  -DFOURDGS_CORE_LIBRARY=<path to libfourdgs.a or fourdgs.lib> (cargo build -p fourdgs --release)\n"
        "See cpp/README.md, 'Consuming this package from another project', for what a "
        "consumer supplies today and what is planned instead.\n"
        "To build the binding with no decoder on purpose — it compiles, and every call "
        "returns kNotImplemented — pass -DFOURDGS_ALLOW_NO_CORE=ON.")
  endif()
  message(STATUS "fourdgs: no core header at ${FOURDGS_CORE_HEADER_DIR}/fourdgs.h; "
                 "building the binding without a decoder")
elseif(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/src/backend_capi.cpp")
  # The core landed and the binding has not been written against it yet. Refusing every call
  # is the honest configuration; silently linking nothing is not.
  message(WARNING "fourdgs: a core header exists but src/backend_capi.cpp does not; "
                  "building the binding without a decoder")
else()
  if(FOURDGS_CORE_LIBRARY STREQUAL "")
    # The static library first. The crate builds a cdylib too, and linking that would make
    # every consumer's binary need it on their loader path at run time — a surprise for an
    # integrator who asked for one static archive.
    #
    # Saying that is not enough on Windows. Cargo writes both `fourdgs.lib` (the staticlib)
    # and `fourdgs.dll.lib` (the cdylib's import library) into the same directory, and
    # CMake's MSVC suffix list puts `.dll.lib` ahead of `.lib` — so the default search
    # returns the DLL, which is the outcome the paragraph above rules out. It is not a
    # theoretical preference: an executable that references any fourdgs_* symbol then gets
    # a load-time dependency on fourdgs.dll, and with the DLL absent from the loader path
    # the process does not start. Narrowing the suffix list for this one search asks for
    # the archive the comment says it wants.
    set(FOURDGS_SAVED_FIND_SUFFIXES ${CMAKE_FIND_LIBRARY_SUFFIXES})
    if(MSVC)
      set(CMAKE_FIND_LIBRARY_SUFFIXES ".lib")
    endif()
    find_library(
      FOURDGS_CORE_FOUND_LIBRARY
      NAMES libfourdgs.a fourdgs
      HINTS "${CMAKE_CURRENT_SOURCE_DIR}/../target/release"
            "${CMAKE_CURRENT_SOURCE_DIR}/../target/debug")
    set(CMAKE_FIND_LIBRARY_SUFFIXES ${FOURDGS_SAVED_FIND_SUFFIXES})
    if(FOURDGS_CORE_FOUND_LIBRARY)
      set(FOURDGS_CORE_LIBRARY "${FOURDGS_CORE_FOUND_LIBRARY}")
    else()
      # `find_library` caches its answer, including NOTFOUND. Left cached, the very next
      # thing a reader does — run `cargo build -p fourdgs --release` and reconfigure the
      # same build directory — would find nothing and keep the build with no decoder, which
      # is a much worse failure now that this branch is survivable rather than fatal.
      unset(FOURDGS_CORE_FOUND_LIBRARY CACHE)
    endif()
  endif()

  if(FOURDGS_BUILD_CORE_FROM_SOURCE_ACTIVE OR EXISTS "${FOURDGS_CORE_LIBRARY}")
    set(FOURDGS_HAVE_CORE ON)
    set(FOURDGS_BACKEND_SOURCE src/backend_capi.cpp)
  elseif(NOT FOURDGS_CORE_LIBRARY STREQUAL "")
    message(
      FATAL_ERROR
        "fourdgs: FOURDGS_CORE_LIBRARY names ${FOURDGS_CORE_LIBRARY}, but that file does not exist")
  elseif(NOT FOURDGS_ALLOW_NO_CORE)
    # The header is committed and the library is not, so this is the message a consumer
    # who fetched this package sees: everything the fetch brought is here except the one
    # thing cargo has to produce. It names the directories that were searched, because
    # "no library to link" against a source tree that visibly contains a Rust crate is a
    # sentence somebody re-reads three times before checking `target/`.
    message(
      FATAL_ERROR
        "fourdgs: found ${FOURDGS_CORE_HEADER_DIR}/fourdgs.h but no library to link.\n"
        "Searched ${CMAKE_CURRENT_SOURCE_DIR}/../target/release and "
        "${CMAKE_CURRENT_SOURCE_DIR}/../target/debug.\n"
        "The core is a Rust crate, and its library is a build artifact rather than "
        "something this directory carries: run `cargo build -p fourdgs --release` in the "
        "checkout above, or point at an archive built elsewhere with "
        "-DFOURDGS_CORE_LIBRARY=<path to libfourdgs.a or fourdgs.lib>.\n"
        "A build outside this repository has to do one of those itself — see cpp/README.md, "
        "'Consuming this package from another project'.\n"
        "To build the binding with no decoder on purpose — it compiles, and every call "
        "returns kNotImplemented — pass -DFOURDGS_ALLOW_NO_CORE=ON.")
  else()
    message(
      STATUS
        "fourdgs: found ${FOURDGS_CORE_HEADER_DIR}/fourdgs.h but no library to link; "
        "building the binding without a decoder. Run `cargo build -p fourdgs --release` "
        "and configure again to link it.")
  endif()
endif()

add_library(fourdgs-cpp STATIC src/scene.cpp src/model.cpp src/readable.cpp src/result.cpp
                               src/writer.cpp ${FOURDGS_BACKEND_SOURCE})
add_library(fourdgs::cpp ALIAS fourdgs-cpp)

# `fourdgs::version()` is compiled from this, so the number an application prints at run
# time is the number its build resolved. A literal in `result.cpp` would be a second copy
# of a version, which is the one thing this repository keeps exactly one of per package.
target_compile_definitions(fourdgs-cpp PRIVATE FOURDGS_CPP_VERSION="${PROJECT_VERSION}")

target_include_directories(
  fourdgs-cpp
  PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include> $<INSTALL_INTERFACE:include>
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
# A consumer compiles these public headers too. Setting CMAKE_CXX_STANDARD above controls
# this directory's targets, but it does not tell a FetchContent or installed-package
# consumer which language level the headers require.
target_compile_features(fourdgs-cpp PUBLIC cxx_std_17)

if(MSVC)
  target_compile_options(fourdgs-cpp PRIVATE /W4)
else()
  target_compile_options(fourdgs-cpp PRIVATE -Wall -Wextra -Wpedantic)
endif()

if(FOURDGS_HAVE_CORE)
  target_include_directories(fourdgs-cpp PRIVATE ${FOURDGS_CORE_HEADER_DIR})
  message(STATUS "fourdgs: linking the core from ${FOURDGS_CORE_LIBRARY}")
  # The build links the selected archive directly. The install copies that archive into the
  # package and its config adds the relocatable installed path; keeping this path inside a
  # BUILD_INTERFACE prevents an exported target from remembering a temporary build tree.
  target_link_libraries(fourdgs-cpp PUBLIC "$<BUILD_INTERFACE:${FOURDGS_CORE_LIBRARY}>")
  if(TARGET fourdgs-core-build)
    add_dependencies(fourdgs-cpp fourdgs-core-build)
  endif()
  # A Rust staticlib brings its own runtime requirements; these are what it needs on the
  # platforms this package is built for. The archive does not record them, so a consumer
  # that omits them gets a page of unresolved symbols with no hint of where they came
  # from. `cargo rustc -p fourdgs --crate-type staticlib -- --print native-static-libs`
  # prints the authoritative list per target if this ever needs revisiting.
  #
  # macOS needs nothing named: its equivalents are all in libSystem, which is linked
  # already, and asking for them by name is an error rather than a no-op.
  if(WIN32)
    set(FOURDGS_CORE_NATIVE_LIBRARIES ws2_32 userenv ntdll bcrypt advapi32 kernel32)
  elseif(UNIX AND NOT APPLE)
    set(FOURDGS_CORE_NATIVE_LIBRARIES pthread dl m)
  else()
    set(FOURDGS_CORE_NATIVE_LIBRARIES "")
  endif()
  # Installed consumers get these from the imported core target in the package config.
  # Keeping them in BUILD_INTERFACE avoids exporting them before that archive: static
  # linkers resolve left-to-right, so the archive must precede the native libraries whose
  # symbols its objects introduce.
  foreach(native_library IN LISTS FOURDGS_CORE_NATIVE_LIBRARIES)
    target_link_libraries(fourdgs-cpp PUBLIC "$<BUILD_INTERFACE:${native_library}>")
  endforeach()
else()
  set(FOURDGS_CORE_NATIVE_LIBRARIES "")
endif()

if(FOURDGS_ASAN)
  # Not a default: the sanitizers are how the open/decode/close cycle is checked for leaks and
  # for reads past the end of a buffer the ABI handed over.
  target_compile_options(fourdgs-cpp PUBLIC -fsanitize=address,undefined -fno-omit-frame-pointer
                                            -g)
  target_link_options(fourdgs-cpp PUBLIC -fsanitize=address,undefined)
endif()

if(FOURDGS_BUILD_CONFORMANCE)
  add_library(fourdgs-canonical STATIC conformance/canonical.cpp)
  target_include_directories(fourdgs-canonical PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/conformance)
  target_link_libraries(fourdgs-canonical PUBLIC fourdgs-cpp)

  # The harness invokes a runner as a subprocess with a path, so the entry points live at a
  # fixed place it can name in one line. The decode runners print canonical JSON; the encode
  # runner re-encodes a variant's gaussians and writes a file the encode gate diffs; the
  # keyframe-delta one synthesizes a sample sequence, because the model is a whole-file format
  # with no decoded samples to hand back to a writer.
  foreach(runner decode_streamed decode_indexed encode_roundtrip encode_keyframe_delta)
    add_executable(${runner} conformance/${runner}.cpp)
    target_link_libraries(${runner} PRIVATE fourdgs-canonical)
    fourdgs_pin_runtime_output(${runner} ${CMAKE_BINARY_DIR}/conformance)
  endforeach()

  # `cpp/keyframe-delta-roundtrip.sh` requires the file this runner writes to equal, byte for
  # byte, the one the Rust reference writer produces from the same synthesized samples. Both
  # runners compute those samples from the same integer generator with IEEE double arithmetic,
  # which is reproducible — unless the compiler contracts `a + b * c` into a fused multiply-add,
  # which GCC does by default for C++ and which rounds once instead of twice. Off here, so the
  # comparison is a statement about the binding rather than about a compiler's defaults.
  if(NOT MSVC)
    target_compile_options(encode_keyframe_delta PRIVATE -ffp-contract=off)
  endif()
endif()

option(FOURDGS_BUILD_TOOL "Build the 4dgs command-line tool" ${FOURDGS_IS_TOP_LEVEL})

if(FOURDGS_BUILD_TOOL)
  # A library plus a three-line `main`, rather than one executable: the tool's tests drive
  # `fourdgs::tool::run` directly with argument strings and a pair of streams, so they check the
  # exit code and the printed output together without spawning a process — which is what makes
  # them work the same on Windows as on Linux.
  add_library(fourdgs-tool STATIC tools/cli.cpp tools/inspect.cpp tools/validate.cpp
                                  tools/walk.cpp)
  target_include_directories(fourdgs-tool PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/tools)
  target_link_libraries(fourdgs-tool PUBLIC fourdgs-cpp)
  target_compile_definitions(fourdgs-tool PRIVATE FOURDGS_TOOL_VERSION="${PROJECT_VERSION}")
  if(MSVC)
    target_compile_options(fourdgs-tool PRIVATE /W4)
  else()
    target_compile_options(fourdgs-tool PRIVATE -Wall -Wextra -Wpedantic)
  endif()

  add_executable(fourdgs-cli tools/main.cpp)
  target_link_libraries(fourdgs-cli PRIVATE fourdgs-tool)
  # The name a shell types. The target cannot be called `4dgs` — a CMake target starting with a
  # digit is not portable across generators — but the binary can.
  set_target_properties(fourdgs-cli PROPERTIES OUTPUT_NAME 4dgs)
  fourdgs_pin_runtime_output(fourdgs-cli ${CMAKE_BINARY_DIR}/tools)
endif()

option(FOURDGS_BUILD_EXAMPLES "Build the examples" ${FOURDGS_IS_TOP_LEVEL})

if(FOURDGS_BUILD_EXAMPLES)
  # Built and run in CI, so an example cannot rot into a snippet that no longer compiles.
  add_executable(decode_summary examples/decode_summary.cpp)
  target_link_libraries(decode_summary PRIVATE fourdgs-cpp)
  fourdgs_pin_runtime_output(decode_summary ${CMAKE_BINARY_DIR}/examples)
endif()

if(FOURDGS_BUILD_TESTS)
  enable_testing()
  foreach(test test_model test_result test_readable test_seam test_decode test_writer)
    add_executable(${test} tests/${test}.cpp)
    target_link_libraries(${test} PRIVATE fourdgs-cpp)
    target_include_directories(${test} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/tests)
    add_test(NAME ${test} COMMAND ${test})
  endforeach()

  # The corpus is generated, not committed, and it lives outside this project. Baking its
  # absolute path in means the test finds it however it was launched; FOURDGS_CORPUS still
  # overrides for a corpus somewhere else.
  target_compile_definitions(
    test_decode PRIVATE
    FOURDGS_CORPUS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../tests/conformance/data")

  if(FOURDGS_BUILD_TOOL)
    add_executable(test_tool tests/test_tool.cpp)
    target_link_libraries(test_tool PRIVATE fourdgs-tool)
    target_include_directories(test_tool PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/tests)
    # The invalid corpus already knows which rule each of its files breaks, so the tool's
    # expectations are read out of it rather than restated here. Baking the absolute path in means
    # the test finds it however it was launched.
    target_compile_definitions(
      test_tool PRIVATE
      FOURDGS_CORPUS_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../tests/conformance/data")
    add_test(NAME test_tool COMMAND test_tool)
  endif()

  if(FOURDGS_BUILD_CONFORMANCE)
    add_executable(test_canonical tests/test_canonical.cpp)
    target_link_libraries(test_canonical PRIVATE fourdgs-canonical)
    target_include_directories(test_canonical PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/tests)
    add_test(NAME test_canonical COMMAND test_canonical)
  endif()
endif()

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

set(FOURDGS_INSTALL_CMAKEDIR ${CMAKE_INSTALL_LIBDIR}/cmake/fourdgs-cpp)
set(FOURDGS_INSTALL_COREDIR ${CMAKE_INSTALL_LIBDIR}/fourdgs-cpp/core)
# An absolute Windows GNUInstallDirs value can arrive as `D:\path`. That spelling is
# accepted as an install destination, but embedding it in the generated config turns
# sequences such as `\a` into invalid CMake escapes. PATH_VARS handles absolute versus
# prefix-relative placement; give it CMake's portable slash spelling to embed.
file(TO_CMAKE_PATH "${FOURDGS_INSTALL_COREDIR}" FOURDGS_INSTALL_COREDIR)

if(FOURDGS_BUILD_TOOL)
  install(TARGETS fourdgs-cli RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
endif()

install(
  TARGETS fourdgs-cpp
  EXPORT fourdgs-cpp-targets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(DIRECTORY include/fourdgs DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
if(FOURDGS_HAVE_CORE)
  get_filename_component(FOURDGS_CORE_LIBRARY_FILENAME "${FOURDGS_CORE_LIBRARY}" NAME)
  install(FILES "${FOURDGS_CORE_LIBRARY}" DESTINATION ${FOURDGS_INSTALL_COREDIR})
else()
  set(FOURDGS_CORE_LIBRARY_FILENAME "")
endif()
install(
  EXPORT fourdgs-cpp-targets
  FILE fourdgs-cpp-targets.cmake
  NAMESPACE fourdgs::
  DESTINATION ${FOURDGS_INSTALL_CMAKEDIR})

# The targets file above is only half a package: `find_package(fourdgs-cpp)` looks for a
# config file and never for a targets file, so an install without these two is a set of
# rules that produce something no consumer can find.
configure_package_config_file(
  cmake/fourdgs-cpp-config.cmake.in "${CMAKE_CURRENT_BINARY_DIR}/fourdgs-cpp-config.cmake"
  INSTALL_DESTINATION ${FOURDGS_INSTALL_CMAKEDIR}
  PATH_VARS FOURDGS_INSTALL_COREDIR)

# SameMinorVersion, because the major version is 0: while it is, SemVer puts the
# compatibility promise on the minor, so a consumer asking for 0.1.0 must not be handed
# 0.2.0. This becomes SameMajorVersion at 1.0.0, which is the point of saying so here.
write_basic_package_version_file(
  "${CMAKE_CURRENT_BINARY_DIR}/fourdgs-cpp-config-version.cmake"
  VERSION ${PROJECT_VERSION}
  COMPATIBILITY SameMinorVersion)

install(FILES "${CMAKE_CURRENT_BINARY_DIR}/fourdgs-cpp-config.cmake"
              "${CMAKE_CURRENT_BINARY_DIR}/fourdgs-cpp-config-version.cmake"
        DESTINATION ${FOURDGS_INSTALL_CMAKEDIR})
