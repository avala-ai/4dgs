# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.20)
project(
  fourdgs-cpp
  VERSION 0.0.0
  DESCRIPTION "C++ binding for the 4dgs container format"
  LANGUAGES CXX)

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

option(FOURDGS_BUILD_TESTS "Build the unit tests" ON)
option(FOURDGS_BUILD_CONFORMANCE "Build the conformance runners" ON)
option(FOURDGS_ASAN "Build with the address and undefined-behaviour sanitizers" OFF)

# Where the Rust core's C ABI lives. The header is committed by the core; the library is a
# build artifact, so it is looked for where cargo puts it and can be pointed elsewhere.
set(FOURDGS_CORE_HEADER_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../rust/fourdgs/include"
    CACHE PATH "Directory containing fourdgs.h from the Rust core")
set(FOURDGS_CORE_LIBRARY
    ""
    CACHE FILEPATH "The Rust core's C-linkable library; searched for when empty")

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
  set(FOURDGS_HAVE_CORE OFF)
  set(FOURDGS_BACKEND_SOURCE src/backend_unavailable.cpp)
  message(STATUS "fourdgs: no core header at ${FOURDGS_CORE_HEADER_DIR}/fourdgs.h; "
                 "building the binding without a decoder")
endif()

add_library(fourdgs-cpp STATIC src/scene.cpp src/model.cpp src/readable.cpp src/result.cpp
                               ${FOURDGS_BACKEND_SOURCE})
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
    find_library(
      FOURDGS_CORE_FOUND_LIBRARY
      NAMES libfourdgs.a fourdgs
      HINTS "${CMAKE_CURRENT_SOURCE_DIR}/../target/release"
            "${CMAKE_CURRENT_SOURCE_DIR}/../target/debug")
    if(NOT FOURDGS_CORE_FOUND_LIBRARY)
      message(
        FATAL_ERROR
          "fourdgs: found ${FOURDGS_CORE_HEADER_DIR}/fourdgs.h but no library to link. "
          "Build it with `cargo build -p fourdgs --release`, or set -DFOURDGS_CORE_LIBRARY=...")
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
  # fixed place it can name in one line.
  foreach(runner decode_streamed decode_indexed)
    add_executable(${runner} conformance/${runner}.cpp)
    target_link_libraries(${runner} PRIVATE fourdgs-canonical)
    fourdgs_pin_runtime_output(${runner} ${CMAKE_BINARY_DIR}/conformance)
  endforeach()
endif()

option(FOURDGS_BUILD_EXAMPLES "Build the examples" ON)

if(FOURDGS_BUILD_EXAMPLES)
  # Built and run in CI, so an example cannot rot into a snippet that no longer compiles.
  add_executable(decode_summary examples/decode_summary.cpp)
  target_link_libraries(decode_summary PRIVATE fourdgs-cpp)
  fourdgs_pin_runtime_output(decode_summary ${CMAKE_BINARY_DIR}/examples)
endif()

if(FOURDGS_BUILD_TESTS)
  enable_testing()
  foreach(test test_model test_result test_readable test_seam test_decode)
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
install(
  TARGETS fourdgs-cpp
  EXPORT fourdgs-cpp-targets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(DIRECTORY include/fourdgs DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(
  EXPORT fourdgs-cpp-targets
  FILE fourdgs-cpp-targets.cmake
  NAMESPACE fourdgs::
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/fourdgs-cpp)
