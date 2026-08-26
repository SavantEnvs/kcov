#!/usr/bin/env bash
#
# mayhem/build.sh — build kcov's fuzz harness (line2addr) + the upstream test suite.
#
# line2addr is upstream's ELF/DWARF line-to-address lookup tool built on kcov's file-parser
# stack (src/parsers/*) — the historical Mayhem target for this repo. We build it from
# mayhem/line2addr_harness.cc, an additive copy of tools/line2addr.cc with the two setup
# fixes the upstream demo omits (a non-NULL IFilter, and parse-solibs=0 so PIE/ET_DYN inputs
# are actually parsed); see the comment block at the top of that file. tools/CMakeLists.txt
# hard-sets CMAKE_CXX_FLAGS, so we compile the source list directly with $CC/$CXX to get
# sanitizers + DWARF-3 into the fuzzed code.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Fuzz target: line2addr — kcov's parser stack + the harness, sanitized + DWARF-3.
#    Source list mirrors tools/CMakeLists.txt (${LINE2ADDR}_SRCS), with our harness
#    replacing tools/line2addr.cc.
$CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS -Wall -D_GLIBCXX_USE_NANOSLEEP \
    -DKCOV_LIBRARY_PREFIX=/tmp \
    -Isrc/include \
    src/capabilities.cc \
    src/configuration.cc \
    src/filter.cc \
    src/parsers/dwarf.cc \
    src/parsers/elf-parser.cc \
    src/parsers/elf.cc \
    src/parsers/dummy-disassembler.cc \
    src/parser-manager.cc \
    src/utils.cc \
    mayhem/line2addr_harness.cc \
    -o /mayhem/line2addr \
    -ldw -lelf -lcurl -lz -ldl -lpthread -lm

# 2) Test suite (NORMAL flags, independent of the sanitized build above):
#    upstream's own recipe (.github/workflows/generic-build.sh + ci-run-tests.sh):
#    build kcov in build/, the test programs in build-tests/; test.sh runs the
#    python libkcov suite against build/src/kcov.
cmake -B build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build -j"$MAYHEM_JOBS"

cmake -S tests -B build-tests
cmake --build build-tests -j"$MAYHEM_JOBS"

# personality() shim for the test run — see mayhem/personality_shim.c.
$CC -O2 -fPIC -shared mayhem/personality_shim.c -o /mayhem/libpersonality_shim.so
