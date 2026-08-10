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

# The seam, resolved: with a core header the binding calls the ABI, without one it refuses
# every call with kNotImplemented. Both configurations build, and both are honest — the
# package never links against a decoder it does not have.
if(EXISTS "${FOURDGS_CORE_HEADER_DIR}/fourdgs.h" AND EXISTS
                                                    "${CMAKE_CURRENT_SOURCE_DIR}/src/backend_capi.cpp")
  set(FOURDGS_HAVE_CORE ON)
  set(FOURDGS_BACKEND_SOURCE src/backend_capi.cpp)
elseif(EXISTS "${FOURDGS_CORE_HEADER_DIR}/fourdgs.h")
  # The core landed and the binding has not been written against it yet. Refusing every call
  # is the honest configuration; silently linking nothing is not.
  set(FOURDGS_HAVE_CORE OFF)
  set(FOURDGS_BACKEND_SOURCE src/backend_unavailable.cpp)
  message(WARNING "fourdgs: a core header exists but src/backend_capi.cpp does not; "
                  "building the binding without a decoder")
else()
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
  set(FOURDGS_HAVE_CORE OFF)
  set(FOURDGS_BACKEND_SOURCE src/backend_unavailable.cpp)
  message(STATUS "fourdgs: no core header at ${FOURDGS_CORE_HEADER_DIR}/fourdgs.h; "
                 "building the binding without a decoder")
endif()

add_library(fourdgs-cpp STATIC src/scene.cpp src/model.cpp src/readable.cpp src/result.cpp
                               src/writer.cpp ${FOURDGS_BACKEND_SOURCE})
add_library(fourdgs::cpp ALIAS fourdgs-cpp)

target_include_directories(
  fourdgs-cpp
  PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include> $<INSTALL_INTERFACE:include>
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)

if(MSVC)
  target_compile_options(fourdgs-cpp PRIVATE /W4)
else()
  target_compile_options(fourdgs-cpp PRIVATE -Wall -Wextra -Wpedantic)
endif()

if(FOURDGS_HAVE_CORE)
  target_include_directories(fourdgs-cpp PRIVATE ${FOURDGS_CORE_HEADER_DIR})
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
    if(NOT FOURDGS_CORE_FOUND_LIBRARY)
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
          "'Consuming this package from another project'.")
    endif()
    set(FOURDGS_CORE_LIBRARY "${FOURDGS_CORE_FOUND_LIBRARY}")
  endif()
  message(STATUS "fourdgs: linking the core from ${FOURDGS_CORE_LIBRARY}")
  target_link_libraries(fourdgs-cpp PUBLIC "${FOURDGS_CORE_LIBRARY}")
  # A Rust staticlib brings its own runtime requirements; these are what it needs on the
  # platforms this package is built for. The archive does not record them, so a consumer
  # that omits them gets a page of unresolved symbols with no hint of where they came
  # from. `cargo rustc -p fourdgs --crate-type staticlib -- --print native-static-libs`
  # prints the authoritative list per target if this ever needs revisiting.
  #
  # macOS needs nothing named: its equivalents are all in libSystem, which is linked
  # already, and asking for them by name is an error rather than a no-op.
  if(WIN32)
    target_link_libraries(fourdgs-cpp PUBLIC ws2_32 userenv ntdll bcrypt advapi32 kernel32)
  elseif(UNIX AND NOT APPLE)
    target_link_libraries(fourdgs-cpp PUBLIC pthread dl m)
  endif()
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
  # runner re-encodes a variant's gaussians and writes a file the encode gate diffs.
  foreach(runner decode_streamed decode_indexed encode_roundtrip)
    add_executable(${runner} conformance/${runner}.cpp)
    target_link_libraries(${runner} PRIVATE fourdgs-canonical)
    fourdgs_pin_runtime_output(${runner} ${CMAKE_BINARY_DIR}/conformance)
  endforeach()
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

install(
  TARGETS fourdgs-cpp
  EXPORT fourdgs-cpp-targets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(DIRECTORY include/fourdgs DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
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
  INSTALL_DESTINATION ${FOURDGS_INSTALL_CMAKEDIR})

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
