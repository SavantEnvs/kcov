#!/usr/bin/env bash
#
# mayhem/test.sh — RUN kcov's upstream functional test suite (built by mayhem/build.sh).
#
# This is the suite upstream CI runs (.github/workflows/ci-run-tests.sh): the python
# libkcov runner over build/src/kcov + the compiled test programs in build-tests/.
# Each test asserts concrete coverage results (cobertura hits-per-line, kcov output),
# so a sabotaged/no-op kcov fails it. The C++ unit tests (tests/unit-tests) are NOT run:
# they require crpcut, which is unavailable and not run by upstream CI either.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

[ -x build/src/kcov ] || { echo "build/src/kcov missing — mayhem/build.sh bug" >&2; exit 1; }
[ -d build-tests ]    || { echo "build-tests/ missing — mayhem/build.sh bug" >&2; exit 1; }

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

log=/tmp/kcov-test-run.log

# LD_PRELOAD shim: docker's default seccomp blocks personality(ADDR_NO_RANDOMIZE),
# which kcov requires before ptrace-attaching — see mayhem/personality_shim.c.
export LD_PRELOAD="/mayhem/libpersonality_shim.so${LD_PRELOAD:+:$LD_PRELOAD}"
export PYTHONPATH="$SRC/tests/tools"

# The suite is timing-sensitive (ptrace/daemon/signal tests); a handful of tests
# flake under the docker-build sandbox. One retry of the FULL suite on failure;
# the second result decides. A sabotaged kcov fails deterministically both times.
for attempt in 1 2; do
  outbase=$(mktemp -d /tmp/kcov-tests.XXXXXX)
  python3 -m libkcov build/src/kcov "$outbase" build-tests "$SRC" -v >"$log" 2>&1
  suite_rc=$?
  grep -E -A12 '^(FAIL|ERROR):' "$log" | head -120
  tail -5 "$log"
  [ "$suite_rc" -eq 0 ] && break
  echo "--- suite failed (attempt $attempt) ---"
done

# Parse the unittest TextTestRunner summary:
#   Ran N tests in Xs
#   OK (skipped=S, expected failures=E)  |  FAILED (failures=F, errors=R, ...)
read -r ran failures errors skipped <<<"$(python3 - "$log" <<'PY'
import re, sys
text = open(sys.argv[1], errors="replace").read()
m = re.search(r"Ran (\d+) tests?", text)
ran = int(m.group(1)) if m else 0
def grab(key):
    m = re.search(r"(?<!expected )" + key + r"=(\d+)", text)
    return int(m.group(1)) if m else 0
print(ran, grab("failures"), grab("errors"), grab("skipped"))
PY
)"

if [ "$ran" -eq 0 ]; then
  echo "test runner produced no results (see $log)" >&2
  emit_ctrf "kcov-libkcov" 0 1 0
  exit 1
fi

failed=$(( failures + errors ))
# unittest exits non-zero on any failure; trust the exit code if parsing missed something.
if [ "$suite_rc" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi
passed=$(( ran - failed - skipped ))

emit_ctrf "kcov-libkcov" "$passed" "$failed" "$skipped"
