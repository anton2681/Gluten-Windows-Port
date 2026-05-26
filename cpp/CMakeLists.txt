# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

cmake_minimum_required(VERSION 3.16)
message(STATUS "Building using CMake version: ${CMAKE_VERSION}")

# vcpkg x64-windows-static triplet ships everything with /MT (static CRT).
# gluten itself must match or libprotobuf/arrow/folly link with LNK2038
# 'RuntimeLibrary' mismatch. CMP0091 must be NEW BEFORE project().
if(WIN32)
  cmake_policy(SET CMP0091 NEW)
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# The set(CACHE) command does not remove any normal variable of the same name
# from the current scope https://cmake.org/cmake/help/latest/policy/CMP0126.html
if(POLICY CMP0126)
  cmake_policy(SET CMP0126 NEW)
endif()

if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.24.0")
  cmake_policy(SET CMP0135 NEW)
endif()

if(NOT DEFINED CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE
      Release
      CACHE STRING "Choose the type of build to Release.")
endif()

set(CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/CMake" ${CMAKE_MODULE_PATH})
set(CMAKE_EXPORT_COMPILE_COMMANDS
    ON
    CACHE INTERNAL "")

project(gluten)

option(BUILD_VELOX_BACKEND "Build Velox backend" ON)
option(BUILD_TESTS "Build Tests" OFF)
option(BUILD_EXAMPLES "Build Examples" OFF)
option(BUILD_BENCHMARKS "Build Benchmarks" OFF)
option(BUILD_TEST_UTILS "Build utils for tests/benchmarks" OFF)
option(ENABLE_JEMALLOC_STATS "Prints Jemalloc stats for debugging" OFF)
option(BUILD_GLOG "Build Glog from Source" OFF)
option(ENABLE_QAT "Enable QAT for de/compression" OFF)
option(ENABLE_GCS "Enable GCS" OFF)
option(ENABLE_S3 "Enable S3" OFF)
option(ENABLE_HDFS "Enable HDFS" OFF)
option(ENABLE_ORC "Enable ORC" OFF)
option(ENABLE_ABFS "Enable ABFS" OFF)
option(ENABLE_GPU "Enable GPU" OFF)
option(ENABLE_ENHANCED_FEATURES "Enable enhanced features" OFF)

set(root_directory ${PROJECT_BINARY_DIR})
get_filename_component(GLUTEN_HOME ${CMAKE_SOURCE_DIR} DIRECTORY)

if(NOT DEFINED VELOX_HOME)
  set(VELOX_HOME ${GLUTEN_HOME}/ep/build-velox/build/velox_ep)
  message(STATUS "Set VELOX_HOME to ${VELOX_HOME}")
endif()

if(NOT DEFINED ARROW_HOME)
  if(${CMAKE_BUILD_TYPE} STREQUAL "Debug")
    set(ARROW_HOME
        ${VELOX_HOME}/_build/debug/CMake/resolve_dependency_modules/arrow/arrow_ep/
    )
  else()
    set(ARROW_HOME
        ${VELOX_HOME}/_build/release/CMake/resolve_dependency_modules/arrow/arrow_ep
    )
  endif()
  message(STATUS "Set ARROW_HOME to ${ARROW_HOME}")
else()
  message(STATUS "Using provided ARROW_HOME: ${ARROW_HOME}")
endif()

include(ResolveDependency)

#
# Compiler flags
#

if("${CMAKE_CXX_COMPILER_ID}" STREQUAL "MSVC")
  # MSVC: use /Od for debug, NDEBUG already set via CMAKE_BUILD_TYPE handling
  if(${CMAKE_BUILD_TYPE} STREQUAL "Debug")
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} /Od /Zi")
    message(STATUS "CMAKE_CXX_FLAGS_DEBUG=${CMAKE_CXX_FLAGS_DEBUG}")
  else()
    add_definitions(-DNDEBUG)
    message(STATUS "Add definition NDEBUG")
  endif()
  # Windows macro hygiene — match velox's MSVC config so glog/folly/boost
  # headers parse correctly:
  #   GLOG_NO_ABBREVIATED_SEVERITIES — avoid clash with Win32 ERROR macro
  #   NOMINMAX                       — avoid windows.h min/max macros
  #   WIN32_LEAN_AND_MEAN            — shrink windows.h surface
  #   NO_FIXED_STR_UDL               — disable folly FixedString _fs UDL (MSVC won't parse)
  #   _USE_MATH_DEFINES              — make M_PI etc. available from <cmath>
  add_definitions(-DGLOG_NO_ABBREVIATED_SEVERITIES -DNOMINMAX -DWIN32_LEAN_AND_MEAN -DNO_FIXED_STR_UDL -D_USE_MATH_DEFINES)
else()
  if(${CMAKE_BUILD_TYPE} STREQUAL "Debug")
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -ggdb -O0")
    message(STATUS "CMAKE_CXX_FLAGS_DEBUG=${CMAKE_CXX_FLAGS_DEBUG}")
  else()
    add_definitions(-DNDEBUG)
    message(STATUS "Add definition NDEBUG")
  endif()
endif()

if("${CMAKE_CXX_COMPILER_ID}" STREQUAL "MSVC")
  # MSVC does not use GCC-style warning flags; use permissive mode suppression.
  # /Zc:preprocessor enables the conforming preprocessor required for
  # ##__VA_ARGS__ elision (used in velox/common/base/Exceptions.h macros).
  set(KNOWN_WARNINGS "/W3 /wd4018 /wd4146 /wd4244 /wd4267 /wd4305 /wd4800 /wd4996 /Zc:preprocessor")
else()
  set(KNOWN_WARNINGS
      "-Wall \
         -Wno-sign-compare \
         -Wno-comment \
         -Werror \
         -Wno-error=parentheses \
         -Wno-error=unused-function \
         -Wno-error=unused-variable \
         -Wno-error=uninitialized \
         -Wno-error=maybe-uninitialized \
         -Wno-unknown-warning-option \
         -Wno-strict-aliasing \
         -Wno-ignored-qualifiers \
         -Wno-deprecated-declarations \
         -Wno-attributes")
endif()

if("${CMAKE_CXX_COMPILER_ID}" STREQUAL "GNU")
  set(KNOWN_WARNINGS "-Wno-error=unused-but-set-variable \
      ${KNOWN_WARNINGS}")
  if(CMAKE_CXX_COMPILER_VERSION VERSION_LESS 11)
    set(KNOWN_WARNINGS "-Wno-error=maybe-uninitialized \
      ${KNOWN_WARNINGS}")
  endif()
elseif("${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang")
  # Experimental
  set(KNOWN_WARNINGS
      "-Wno-implicit-int-float-conversion \
      -Wno-nullability-completeness \
      -Wno-mismatched-tags \
      ${KNOWN_WARNINGS}")
elseif("${CMAKE_CXX_COMPILER_ID}" STREQUAL "AppleClang")
  # Experimental
  set(KNOWN_WARNINGS
      "-Wno-implicit-int-float-conversion \
      -Wno-nullability-completeness \
      -Wno-mismatched-tags \
      -Wno-error=unused-private-field \
      -Wno-error=pessimizing-move \
      ${KNOWN_WARNINGS}")
elseif("${CMAKE_CXX_COMPILER_ID}" STREQUAL "MSVC")
  # MSVC warning flags already set above; nothing extra needed here
else()
  message(FATAL_ERROR "Unsupported compiler ID: ${CMAKE_CXX_COMPILER_ID}")
endif()

# see https://issues.apache.org/jira/browse/ARROW-4665
if(${CMAKE_SYSTEM_NAME} MATCHES "Darwin")
  set(KNOWN_WARNINGS
      "-Wno-macro-redefined \
      -Wno-nullability-completeness \
      -Wno-pessimizing-move \
      -Wno-mismatched-tags \
      ${KNOWN_WARNINGS}")
  # Specific definition for an issue with boost/stacktrace when building on
  # macOS. See https://github.com/boostorg/stacktrace/issues/88 and comments
  # therein.
  add_compile_definitions(_GNU_SOURCE)
endif()

if("${CMAKE_CXX_COMPILER_ID}" STREQUAL "GNU")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-class-memaccess")
endif()

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${KNOWN_WARNINGS}")

# Keep same compile option with Velox.
# On Windows/MSVC, skip the bash script (not available); use empty flags.
if(NOT "${CMAKE_CXX_COMPILER_ID}" STREQUAL "MSVC" AND NOT WIN32)
  execute_process(
    COMMAND
      bash -c
      "( source ${VELOX_HOME}/scripts/setup-helper-functions.sh && echo -n $(get_cxx_flags $ENV{CPU_TARGET}))"
    OUTPUT_VARIABLE SCRIPT_CXX_FLAGS
    RESULT_VARIABLE COMMAND_STATUS)
  if(COMMAND_STATUS EQUAL "1")
    message(FATAL_ERROR "Unable to determine compiler flags!")
  endif()
else()
  set(SCRIPT_CXX_FLAGS "")
  set(COMMAND_STATUS 0)
endif()

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${SCRIPT_CXX_FLAGS}")

#
# Dependencies
#

include(ConfigArrow)

set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

find_package(JNI REQUIRED)

find_package(glog REQUIRED)

if(BUILD_TESTS)
  set(GLUTEN_GTEST_MIN_VERSION "1.13.0")
  find_package(GTest ${GLUTEN_GTEST_MIN_VERSION} CONFIG)
  if(NOT GTest_FOUND)
    include(BuildGTest)
  endif()
  include(GoogleTest)
  enable_testing()
endif()

function(ADD_TEST_CASE TEST_NAME)
  set(options)
  set(one_value_args)
  set(multi_value_args SOURCES EXTRA_LINK_LIBS EXTRA_INCLUDES
                       EXTRA_DEPENDENCIES)

  cmake_parse_arguments(ARG "${options}" "${one_value_args}"
                        "${multi_value_args}" ${ARGN})

  if(ARG_SOURCES)
    set(SOURCES ${ARG_SOURCES})
  else()
    message(FATAL_ERROR "No sources specified for test ${TEST_NAME}")
  endif()

  add_executable(${TEST_NAME} ${SOURCES})
  target_link_libraries(${TEST_NAME} gluten google::glog GTest::gtest
                        GTest::gtest_main Threads::Threads)
  target_include_directories(${TEST_NAME} PRIVATE ${CMAKE_SOURCE_DIR}/core)

  if(ARG_EXTRA_LINK_LIBS)
    target_link_libraries(${TEST_NAME} ${ARG_EXTRA_LINK_LIBS})
  endif()

  if(ARG_EXTRA_INCLUDES)
    target_include_directories(${TEST_NAME} SYSTEM PUBLIC ${ARG_EXTRA_INCLUDES})
  endif()

  if(ARG_EXTRA_DEPENDENCIES)
    add_dependencies(${TEST_NAME} ${ARG_EXTRA_DEPENDENCIES})
  endif()

  gtest_discover_tests(${TEST_NAME})
endfunction()

if(BUILD_TESTS OR BUILD_BENCHMARKS)
  set(GLUTEN_GBENCHMARKS_MIN_VERSION "1.6.0")
  find_package(benchmark ${GLUTEN_GBENCHMARK_MIN_VERSION} CONFIG)
  if(NOT benchmark_FOUND)
    include(BuildGoogleBenchmark)
  endif()
endif()

if(ENABLE_QAT)
  add_definitions(-DGLUTEN_ENABLE_QAT)
endif()

if(ENABLE_GPU)
  add_definitions(-DGLUTEN_ENABLE_GPU)
endif()

if(ENABLE_ENHANCED_FEATURES)
  add_definitions(-DGLUTEN_ENABLE_ENHANCED_FEATURES)
endif()

# Subdirectories
add_subdirectory(core)

if(BUILD_VELOX_BACKEND)
  add_subdirectory(velox)
endif()
