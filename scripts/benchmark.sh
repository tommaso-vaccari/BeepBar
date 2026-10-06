#!/bin/zsh
# Builds beepbar-bench in release mode for arm64 and runs it (docs/benchmarks.md).
#   scripts/benchmark.sh                    every scenario, report in PerformanceReports/
#   scripts/benchmark.sh unchanged --files 15000
# Only synthetic data in a temporary folder and an in-process mock Moodle: it never launches the
# app, and never reads the user's account, database, preferences or sync folder.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --arch arm64 --product beepbar-bench
bench="$(swift build -c release --arch arm64 --show-bin-path)/beepbar-bench"

commit="$(git rev-parse --short HEAD)"
extra=(--commit "$commit")
# Tracked changes only: untracked notes don't change what is measured.
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || extra+=(--dirty)

power="$(pmset -g batt | head -1)"
print -u2 "commit $commit${extra[(r)--dirty]:+ (uncommitted changes)} · $power"
[[ "$power" == *"AC Power"* ]] || print -u2 "warning: on battery; AGENTS.md compares numbers on the same power source"

(( $# )) || set -- baseline
exec "$bench" "$@" "${extra[@]}"
