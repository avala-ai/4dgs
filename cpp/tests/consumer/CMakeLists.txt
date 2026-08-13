# Copyright 2026 Avala AI
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.20)
project(fourdgs-consumer LANGUAGES CXX)

option(FOURDGS_USE_INSTALLED_PACKAGE "Use find_package instead of fetching the source" OFF)

if(FOURDGS_USE_INSTALLED_PACKAGE)
  find_package(fourdgs-cpp CONFIG REQUIRED)
else()
  include(FetchContent)

set(FOURDGS_GIT_REPOSITORY
    "https://github.com/avala-ai/4dgs.git"
    CACHE STRING "Repository used for the out-of-tree consumer test")
set(FOURDGS_GIT_TAG
    "main"
    CACHE STRING "Revision used for the out-of-tree consumer test")
set(FOURDGS_SOURCE_DIR
    ""
    CACHE PATH "Existing source tree used instead of cloning the consumer test revision")

  if(FOURDGS_SOURCE_DIR)
    FetchContent_Declare(fourdgs SOURCE_DIR "${FOURDGS_SOURCE_DIR}" SOURCE_SUBDIR cpp)
  else()
    FetchContent_Declare(
      fourdgs
      GIT_REPOSITORY "${FOURDGS_GIT_REPOSITORY}"
      GIT_TAG "${FOURDGS_GIT_TAG}"
      GIT_SHALLOW OFF
      SOURCE_SUBDIR cpp)
  endif()
  FetchContent_MakeAvailable(fourdgs)
endif()

add_executable(fourdgs-consumer main.cpp)
target_link_libraries(fourdgs-consumer PRIVATE fourdgs::cpp)

enable_testing()
add_test(NAME fourdgs-consumer COMMAND fourdgs-consumer)
