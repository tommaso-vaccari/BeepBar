#!/bin/bash
# Reads a `swift test` log and fails unless every test run that started also printed its passing
# summary. `swift test` alone is not enough: a test process that ends early exits with status 0
# and prints no failure. That happened on `dev`: a simulated click stopped the main run loop,
# which in the test process is the end of the program, and the app tests ended after 853 of 971
# with a green gate (issue #243).
set -u
# The optional second argument is the least number of runs expected (one per test target), so a
# process that ends before its run even starts is caught too.
log=${1:?usage: check-test-run-complete.sh <swift-test-log> [minimum-runs]}
minimum=${2:-1}
[ -r "$log" ] || { echo "Test log not readable: $log" >&2; exit 2; }

started=$(grep -ac 'Test run started\.' "$log")
passed=$(grep -acE 'Test run with [0-9]+ tests?( in [0-9]+ suites?)? passed' "$log")
if [ "$started" -lt "$minimum" ]; then
    echo "Only $started test runs started, at least $minimum expected: a test process did not run." >&2; exit 1
fi
if [ "$started" -ne "$passed" ]; then
    echo "Incomplete test run: $started started, $passed finished with a passing summary." >&2
    echo "A test process ended early or failed; its exit status alone does not show it." >&2
    exit 1
fi
echo "Test runs complete: $passed of $started."
