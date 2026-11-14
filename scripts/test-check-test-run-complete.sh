#!/bin/bash
# Checks scripts/check-test-run-complete.sh against the shapes a `swift test` log can take. Guards
# against the gate going green on a test process that ended early with status 0 (issue #243).
set -u
script="$(dirname "$0")/check-test-run-complete.sh"
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
failures=0

# $1: expected exit status, $2: what the case stands for; the log comes on stdin.
expect() {
    cat > "$dir/log"
    bash "$script" "$dir/log" >/dev/null 2>&1; local got=$?
    if [ "$got" -ne "$1" ]; then
        echo "FAIL: $2 -> exit $got, expected $1"; failures=$((failures + 1))
    fi
}

expect 0 "every run finished" <<'EOF'
◇ Test run started.
✔ Test run with 690 tests in 64 suites passed after 16.038 seconds.
◇ Test run started.
✔ Test run with 1 test in 1 suite passed after 0.100 seconds.
EOF
# The failure this guards against: the last process stops mid-run and prints nothing more.
expect 1 "a run that ended early" <<'EOF'
◇ Test run started.
✔ Test run with 690 tests in 64 suites passed after 16.038 seconds.
◇ Test run started.
◇ Test aFailedPictureKeepsTheTitleAndCourse() started.
EOF
expect 1 "a run that failed" <<'EOF'
◇ Test run started.
✘ Test run with 963 tests in 65 suites failed after 53.510 seconds with 1 issue.
EOF
expect 1 "no run at all" <<'EOF'
Build complete!
EOF
if bash "$script" "$dir/missing" >/dev/null 2>&1; then
    echo "FAIL: a missing log should fail"; failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] || exit 1
echo "check-test-run-complete: ok"
