#!/bin/bash
set -euo pipefail
for variable in $(git rev-parse --local-env-vars); do
    unset "$variable"
done

script="$(cd "$(dirname "$0")" && pwd -P)/mutate.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fixture=$(cd "$fixture" && pwd -P)
repo="$fixture/repo"
export BEEPBAR_MUTATION_CACHE="$fixture/external cache"
export RUNS="$fixture/runs"
export SWIFT_PID="$fixture/swift-pid"
mkdir -p "$repo" "$fixture/bin" "$fixture/patches"
export PATH="$fixture/bin:$PATH"
git -C "$repo" init -q
printf 'base\n' > "$repo/source"
printf '.build/\n' > "$repo/.gitignore"
git -C "$repo" add .
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm base

# A patch adds a file as well as editing one. Both must be restored.
printf 'first\n' > "$repo/source"
printf 'added\n' > "$repo/added"
git -C "$repo" add source added
git -C "$repo" diff --cached > "$fixture/patches/01-first.patch"
git -C "$repo" reset --hard -q HEAD
printf 'second\n' > "$repo/source"
git -C "$repo" diff > "$fixture/patches/02-second.patch"
git -C "$repo" reset --hard -q HEAD
printf 'local edit\n' > "$repo/source"
printf 'untracked local file\n' > "$repo/keep"

cat > "$fixture/bin/swift" <<'SWIFT'
#!/bin/bash
set -eu
printf '%s|%s|%s\n' "$(pwd -P)" "$(cat source)" "$*" >> "$RUNS"
case "$1" in
    build)
        mkdir -p .build
        if [ -f .build/marker ]; then printf 'warm\n' >> "$RUNS"; fi
        touch .build/marker
        [ "${MODE:-}" != compile ]
        ;;
    test)
        [ "$2" = --skip-build ] && [ "$3" = --filter ] && [ "$#" = 4 ]
        case "${MODE:-}" in
            INT|TERM)
                printf '%s\n' "$$" > "$SWIFT_PID"
                kill -s "$MODE" "$PPID"
                sleep 20
                exit 99
                ;;
            early)
                echo 'Test run started.'
                exit 0
                ;;
            runner)
                echo 'error: runner unavailable'
                exit 1
                ;;
            none)
                echo 'Test run started.'
                echo 'Test run with 0 tests in 0 suites passed'
                ;;
            xctest)
                echo "Test Suite 'Selected tests' started at 00:00."
                echo "Test Suite 'Selected tests' failed at 00:00."
                echo 'Executed 1 test, with 1 failure (0 unexpected)'
                exit 1
                ;;
            *)
                echo 'Test run started.'
                if [ "$4" = survives ] || [ "$(cat source)" = second ]; then
                    echo 'Test run with 1 test in 1 suite passed'
                else
                    echo 'Test run with 1 test in 1 suite failed'
                    exit 1
                fi
                ;;
        esac
        ;;
    *) exit 99 ;;
esac
SWIFT
chmod +x "$fixture/bin/swift"

key=$(printf '%s' "$repo/.git" | git hash-object --stdin)
tree="$BEEPBAR_MUTATION_CACHE/$key"
patch="$fixture/patches/01-first.patch"
trap 'cat "$fixture/output" >&2' ERR

run_mutations() {
    local expected=$1 actual=0
    shift
    (cd "$repo" && bash "$script" "$@") > "$fixture/output" 2>&1 || actual=$?
    [ "$actual" = "$expected" ]
}

assert_restored() {
    [ -z "$(git -C "$tree" status --porcelain)" ]
    [ "$(cat "$tree/source")" = base ]
    [ ! -e "$tree/added" ]
    [ ! -e "$tree.lock" ]
    [ "$(cat "$repo/source")" = 'local edit' ]
    [ "$(cat "$repo/keep")" = 'untracked local file' ]
    [ -z "$(git -C "$repo" diff --cached)" ]
}

# The second patch sees a clean source tree, reuses the build, and survives.
run_mutations 1 --filter example "$fixture/patches"
grep -Fq 'Summary: 1 detected, 1 NOT detected, 0 does not compile, 0 inconclusive' "$fixture/output"
grep -Fxq "$tree|first|build --build-tests" "$RUNS"
grep -Fxq "$tree|second|build --build-tests" "$RUNS"
grep -Fxq warm "$RUNS"
assert_restored
if git -C "$tree" symbolic-ref --quiet HEAD; then exit 1; fi

# A passing second filter keeps a patch from counting as proven.
run_mutations 1 --filter 'would fail' --filter survives "$patch"
grep -Fxq "$tree|first|test --skip-build --filter would fail" "$RUNS"
assert_restored

# Compiler errors and missing/aborted test runs must never count as detection.
MODE=compile run_mutations 2 --filter example "$patch"
grep -Fq '1 does not compile, 0 inconclusive' "$fixture/output"
assert_restored
for mode in early runner none; do
    MODE=$mode run_mutations 2 --filter example "$patch"
    grep -Fq '0 does not compile, 1 inconclusive' "$fixture/output"
    assert_restored
done
MODE=xctest run_mutations 0 --filter example "$patch"
assert_restored

# A rejected patch leaves the worktree clean and the next patch still runs.
printf 'invalid patch\n' > "$fixture/invalid.patch"
run_mutations 2 --filter example "$fixture/invalid.patch" "$patch"
grep -Fq 'Summary: 1 detected, 0 NOT detected, 0 does not compile, 1 inconclusive' "$fixture/output"
assert_restored

# The Swift stand-in signals only the script and keeps running until it is stopped.
MODE=INT run_mutations 130 --filter example "$patch"
if kill -0 "$(cat "$SWIFT_PID")" 2>/dev/null; then exit 1; fi
assert_restored
MODE=TERM run_mutations 143 --filter example "$patch"
if kill -0 "$(cat "$SWIFT_PID")" 2>/dev/null; then exit 1; fi
assert_restored

# Refuse the dedicated checkout itself and a launching checkout nested inside it.
for launching_checkout in "$tree" "$tree/nested"; do
    if [ "$launching_checkout" != "$tree" ]; then
        git -C "$repo" -c core.hooksPath=/dev/null worktree add --quiet --detach "$launching_checkout" HEAD
    fi
    actual=0
    (cd "$launching_checkout" && bash "$script" --filter example "$patch") > "$fixture/output" 2>&1 || actual=$?
    [ "$actual" = 2 ]
    grep -Fq 'overlaps the launching checkout' "$fixture/output"
done
git -C "$repo" worktree remove "$tree/nested"
assert_restored

BEEPBAR_MUTATION_CACHE="$repo/nested-cache" run_mutations 2 --filter example "$patch"
[ ! -e "$repo/nested-cache" ]
mkdir "$tree.lock"
run_mutations 2 --filter example "$patch"
grep -Fq 'is locked or unavailable' "$fixture/output"
rmdir "$tree.lock"

# Moving to a new commit must retain the warm build and leave the caller untouched.
first_commit=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm next
run_mutations 0 --filter example "$patch"
[ "$(git -C "$tree" rev-parse HEAD)" = "$(git -C "$repo" rev-parse HEAD)" ]
[ "$(git -C "$tree" rev-parse HEAD)" != "$first_commit" ]
[ -f "$tree/.build/marker" ]
assert_restored

# Recreate an evicted cache directory even if Git still registers the worktree.
mv "$tree" "$fixture/evicted"
run_mutations 0 --filter example "$patch"
assert_restored

printf 'Mutation runner regression tests passed.\n'
