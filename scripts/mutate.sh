#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/mutate.sh --filter REGEX [--filter REGEX ...] [--] PATCH... | DIRECTORY

From the checkout whose committed HEAD you want to test, first verify the
selected tests pass on the intact code. Each patch must apply independently to
that commit. A directory runs its immediate *.patch files in filename order.
For optional PR evidence, bundle numbered .patch files with a README recording
the commit, filters and expected failures.

One regex such as 'firstTest|secondTest' detects a mutation if either test
fails. To require both to fail, pass one --filter per test. Each patch builds
the test targets once and runs each filter separately against that build.

One detached worktree per clone is shared by its branches and linked checkouts.
It keeps .build under ${XDG_CACHE_HOME:-$HOME/.cache}/beepbar/mutations. Set
BEEPBAR_MUTATION_CACHE to use a different external cache. After SIGKILL,
inspect the dedicated worktree and its adjacent .lock before reusing them.

Exit 0 means all patches were detected, 1 means a patch survived, and 2 means
a build, patch application or test run was inconclusive.
Focused tests: bash scripts/test-mutate.sh
USAGE
}

fail() {
    echo "mutate: $*" >&2
    exit 2
}

filters=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --filter)
            [ "$#" -ge 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ] || fail 'expected a filter regex'
            filters+=("$2")
            shift 2
            ;;
        --) shift; break ;;
        -*) fail "unknown option: $1" ;;
        *) break ;;
    esac
done
if [ "${#filters[@]}" -eq 0 ] || [ "$#" -eq 0 ]; then
    usage >&2
    exit 2
fi

# Git hooks can export local variables that override -C even in a different checkout.
for variable in $(git rev-parse --local-env-vars); do
    unset "$variable"
done
checkout=$(git rev-parse --show-toplevel)
checkout=$(cd "$checkout" && pwd -P)
common=$(git rev-parse --path-format=absolute --git-common-dir)
common=$(cd "$common" && pwd -P)
commit=$(git rev-parse --verify HEAD)
launch_directory=$(pwd -P)

if [ "$#" -eq 1 ] && [ -d "$1" ]; then
    shopt -s nullglob
    set -- "${1%/}"/*.patch
    [ "$#" -gt 0 ] || fail 'no .patch files in the directory'
fi
patches=()
for patch in "$@"; do
    [ -f "$patch" ] && [ -r "$patch" ] || fail "unreadable patch: $patch"
    case "$patch" in
        /*) patches+=("$patch") ;;
        *) patches+=("$launch_directory/$patch") ;;
    esac
done

export LC_ALL=C
key=$(printf '%s' "$common" | git hash-object --stdin)
cache=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
    "${BEEPBAR_MUTATION_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/beepbar/mutations}")
tree="$cache/$key"
[ ! -L "$tree" ] || fail "mutation worktree is a symlink: $tree"

contains_directory() {
    local ancestor=$1 directory=$2
    while [ -n "$directory" ]; do
        if [ "$ancestor" = "$directory" ] || [ "$ancestor" -ef "$directory" ]; then
            return 0
        fi
        directory=${directory%/*}
    done
    return 1
}

overlaps_checkout() {
    contains_directory "$1" "$tree" || contains_directory "$tree" "$1"
}

if overlaps_checkout "$checkout"; then
    fail "mutation worktree overlaps the launching checkout: $tree"
fi
registered=false
while IFS= read -r -d '' entry; do
    case "$entry" in
        'worktree '*)
            other=${entry#worktree }
            if [ "$other" = "$tree" ] || [ "$other" -ef "$tree" ]; then
                registered=true
            elif overlaps_checkout "$other"; then
                fail "mutation worktree overlaps another checkout: $other"
            fi
            ;;
    esac
done < <(git worktree list --porcelain -z)

umask 077
mkdir -p "$cache"
lock="$tree.lock"
mkdir "$lock" 2>/dev/null || fail "mutation worktree is locked or unavailable: $lock"
restore_needed=false
child=
log="$lock/swift.log"

in_tree() {
    git -C "$tree" -c core.hooksPath=/dev/null "$@"
}

restore() {
    in_tree reset --hard --quiet "$commit" || return
    restore_needed=false
}

cleanup() {
    local status=$?
    trap '' INT TERM
    if [ -n "$child" ]; then
        kill -TERM -- "-$child" 2>/dev/null || true
        kill -KILL -- "-$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
    if $restore_needed && ! restore; then
        echo "mutate: restoration failed in $tree" >&2
        status=2
    fi
    rm -f "$log" && rmdir "$lock" || status=2
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -e "$tree" ]; then
    if $registered; then
        # Cache eviction can remove the directory while Git still has a record of it.
        git -c core.hooksPath=/dev/null worktree add --force --detach "$tree" "$commit"
    else
        git -c core.hooksPath=/dev/null worktree add --detach "$tree" "$commit"
    fi
else
    $registered && [ -f "$tree/.git" ] || fail "not a registered linked worktree: $tree"
    tree_gitdir=$(in_tree rev-parse --absolute-git-dir)
    [ -f "$tree_gitdir/gitdir" ] && [ "$(cat "$tree_gitdir/gitdir")" -ef "$tree/.git" ] ||
        fail "worktree metadata does not point back to $tree"
    tree_common=$(in_tree rev-parse --path-format=absolute --git-common-dir)
    [ "$tree_common" = "$common" ] || fail "worktree belongs to a different clone: $tree"
    if in_tree symbolic-ref --quiet HEAD >/dev/null; then
        fail "mutation worktree has a branch checked out: $tree"
    fi
    changes=$(in_tree status --porcelain)
    [ -z "$changes" ] || fail "mutation worktree has local changes: $tree"
    if [ "$(in_tree rev-parse HEAD)" != "$commit" ]; then
        in_tree checkout --detach "$commit"
    fi
fi
printf 'Testing %s in %s\n' "$commit" "$tree"

# Job control gives Swift and its descendants their own process group. A signal to this
# script can interrupt wait, stop the group, and only then restore the checkout.
set -m
run_swift() {
    local status=0
    (cd "$tree" && exec swift "$@") > "$log" 2>&1 &
    child=$!
    wait "$child" || status=$?
    child=
    cat "$log"
    return "$status"
}

# The gate also checks completed summaries because SwiftPM can exit successfully after
# zero tests or a test process can stop early. Count Swift Testing and XCTest separately.
test_outcome() {
    local status=$1
    awk -v status="$status" '
        /Test run started\./ { started++ }
        /Test run with [0-9]+ tests?( in [0-9]+ suites?)? (passed|failed)/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "with") { total += $(i+1); break }
            }
            if ($0 ~ /tests?( in [0-9]+ suites?)? failed/) failed++
            finished++
        }
        /Test Suite .* (started|passed|failed) at / {
            if ($0 ~ /Test Suite .(Selected tests|All tests). started/) x_started++
            if ($0 ~ /Test Suite .(Selected tests|All tests). (passed|failed)/) {
                x_finished++
                if ($0 ~ / failed at /) x_failed++
                if (getline > 0 && $1 == "Executed") total += $2
            }
        }
        END {
            if (!total || started != finished || x_started != x_finished) print "test run inconclusive"
            else if (status == 1 && (failed || x_failed)) print "detected"
            else if (status == 0 && !failed && !x_failed) print "NOT detected"
            else print "test run inconclusive"
        }
    ' "$log"
}

detected=0
survived=0
uncompiled=0
inconclusive=0
for patch in "${patches[@]}"; do
    printf '\n=== %s ===\n' "$patch"
    restore_needed=true
    # Let Git finish updating both the index and files before the shell handles a signal.
    if ! (trap '' INT TERM; in_tree apply --index -- "$patch"); then
        outcome='patch did not apply'
    elif ! run_swift build --build-tests; then
        outcome='does not compile (build failed)'
    else
        outcome=detected
        for filter in "${filters[@]}"; do
            printf '\nFilter: %s\n' "$filter"
            status=0
            run_swift test --skip-build --filter "$filter" || status=$?
            result=$(test_outcome "$status")
            printf 'Filter result: %s\n' "$result"
            case "$result" in
                'test run inconclusive') outcome=$result ;;
                'NOT detected')
                    if [ "$outcome" = detected ]; then outcome=$result; fi
                    ;;
            esac
        done
    fi
    restore || fail "could not restore $tree"
    printf '%s: %s\n' "${patch##*/}" "$outcome"
    case "$outcome" in
        detected) detected=$((detected + 1)) ;;
        'NOT detected') survived=$((survived + 1)) ;;
        'does not compile'*) uncompiled=$((uncompiled + 1)) ;;
        *) inconclusive=$((inconclusive + 1)) ;;
    esac
done
printf '\nSummary: %d detected, %d NOT detected, %d does not compile, %d inconclusive\n' \
    "$detected" "$survived" "$uncompiled" "$inconclusive"
if [ "$((uncompiled + inconclusive))" -gt 0 ]; then
    exit 2
fi
[ "$survived" -eq 0 ]
