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

# Network: one nettop sample of the process's open connections every second for the whole window,
# in the background. Two snapshots would not do: nettop forgets a connection once it closes, so a
# check that opens and closes its connections inside the window would read as 0 bytes. Each
# connection counts its highest byte count seen, minus what it had already moved when the window
# started. A connection that opens and closes between two samples is missed, so the result is a
# lower bound; the number of connections seen is printed next to it. One short nettop per sample
# rather than one long-running nettop: its output to a file is block-buffered and lost when it is
# stopped.
flows="$(mktemp -t beepbar-idle-nettop)"
(
    while kill -0 "$pid" 2>/dev/null; do
        nettop -p "$pid" -L 1 -x -n -J bytes_in,bytes_out 2>/dev/null || true
        sleep 1
    done
) > "$flows" &
sampler_pid=$!
trap 'kill $sampler_pid 2>/dev/null; rm -f "$flows"' EXIT

mkdir -p PerformanceReports
report="PerformanceReports/idle-$(date +%Y-%m-%dT%H-%M-%S).json"
print -u2 "pid $pid · $(pmset -g batt | head -1)"
"$bench" idle --pid "$pid" --minutes "$minutes" --json "$report"
kill $sampler_pid 2>/dev/null || true
wait $sampler_pid 2>/dev/null || true

# Each sample starts with a ",bytes_in,bytes_out," header, printed even with no connections;
# connection rows start with tcp or udp.
awk -F, '
    /^,bytes_in/ { sample++; next }
    /^(tcp|udp)/ {
        key = $1; i = $2 + 0; o = $3 + 0
        if (!(key in max_in)) { start_in[key] = (sample == 1 ? i : 0); start_out[key] = (sample == 1 ? o : 0); max_in[key] = 0; max_out[key] = 0 }
        if (i > max_in[key]) max_in[key] = i
        if (o > max_out[key]) max_out[key] = o
    }
    END {
        for (key in max_in) { tin += max_in[key] - start_in[key]; tout += max_out[key] - start_out[key]; n++ }
        if (sample < 2) { print "network          not measured (nettop produced no samples)"; exit }
        printf "network          ≥ %d bytes in, ≥ %d bytes out over %d connections (%d nettop samples, lower bound)\n", tin, tout, n, sample
    }' "$flows"
print "JSON: $report"
