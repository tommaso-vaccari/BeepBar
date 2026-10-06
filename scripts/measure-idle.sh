#!/bin/zsh
# Watches the installed Beepbar at rest, passively, for 30 minutes by default (docs/benchmarks.md):
#   scripts/measure-idle.sh [minutes]
# It only reads the kernel's accounting for that process (proc_pid_rusage, nettop): no signals,
# no debugger, no change to the app or its data. Close BeepBar's window first and leave the Mac
# alone; a scheduled automatic check during the window is expected and shows up as one burst.
set -euo pipefail
cd "${0:A:h}/.."

minutes="${1:-30}"
binary="/Applications/Beepbar.app/Contents/MacOS/Beepbar"
pid="$(pgrep -f "^$binary" | head -1 || true)"
[[ -n "$pid" ]] || { print -u2 "Beepbar isn't running from /Applications"; exit 1; }

swift build -c release --arch arm64 --product beepbar-bench
bench="$(swift build -c release --arch arm64 --show-bin-path)/beepbar-bench"

# nettop lists each process's network bytes; a process with no traffic may be missing (= 0).
# Best effort: the difference of two snapshots, by pid.
network() {
    nettop -P -L 1 -J bytes_in,bytes_out -x 2>/dev/null | awk -F, -v p=".$pid" 'index($1, p) && substr($1, length($1) - length(p) + 1) == p { i += $2; o += $3 } END { print (i + 0), (o + 0) }'
}

mkdir -p PerformanceReports
report="PerformanceReports/idle-$(date +%Y-%m-%dT%H-%M-%S).json"
print -u2 "pid $pid · $(pmset -g batt | head -1)"
read in_before out_before <<< "$(network)"
"$bench" idle --pid "$pid" --minutes "$minutes" --json "$report"
read in_after out_after <<< "$(network)"
print "network          $(( in_after - in_before )) bytes in, $(( out_after - out_before )) bytes out (nettop, best effort)"
print "JSON: $report"
