#!/bin/bash
# Checks scripts/build-version.sh: the next release version from MARKETING_VERSION and the last
# release tag. Run by the CI Test job; needs no git state.
set -u
script="$(dirname "$0")/build-version.sh"
failures=0

expect() {
  local want=$1; shift
  local got
  got=$(sh "$script" "$@" 2>/dev/null) || got="<failed>"
  if [ "$got" != "$want" ]; then
    echo "FAIL: build-version.sh $* -> $got, expected $want"; failures=$((failures + 1))
  fi
}
expect_failure() {
  if sh "$script" "$@" >/dev/null 2>&1; then
    echo "FAIL: build-version.sh $* should fail"; failures=$((failures + 1))
  fi
}

expect 3.0.0 3.0 v2.2.35       # new major starts at patch 0
expect 3.0.1 3.0 v3.0.0        # same line: next patch
expect 3.0.10 3.0 v3.0.9
expect 3.1.0 3.1 v3.0.42       # new minor starts at patch 0
expect 3.0.8 3.0 v3.0.07       # leading zero is decimal, not octal
expect_failure 2.2 v3.0.0      # below the last release
expect_failure 2.9 v3.0.0
expect_failure 3.0 ""          # no previous release
expect_failure 3.0 v3.0        # malformed tags
expect_failure 3.0 3.0.0
expect_failure 3.0 latest
expect_failure 3.0 v3.0.0.1
expect_failure 3.0 v3.x.0
expect_failure 3 v2.2.35       # malformed bases
expect_failure 3.0.0 v2.2.35
expect_failure .0 v2.2.35
expect_failure 3. v2.2.35
expect_failure 3.0                # missing argument

if [ "$failures" -ne 0 ]; then echo "$failures build-version check(s) failed"; exit 1; fi
echo "build-version checks passed"
