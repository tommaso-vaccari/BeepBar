#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/linux-core-tests.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/repo/scripts" "$fixture/bin" "$fixture/tmp"
cp "$script" "$fixture/repo/scripts/"
git -C "$fixture/repo" init -q
printf 'indexed lockfile\n' > "$fixture/repo/Package.resolved"
git -C "$fixture/repo" add Package.resolved
git -C "$fixture/repo" show :Package.resolved > "$fixture/index"
cat > "$fixture/bin/swift" <<'SWIFT'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGUMENTS"
printf 'Linux resolution\n' > Package.resolved
case "$OUTCOME" in
    success) exit 0 ;;
    failure) exit 42 ;;
    HUP|INT|TERM) kill -s "$OUTCOME" "$PPID"; exit 0 ;;
esac
SWIFT
chmod +x "$fixture/bin/swift"
for state in present absent; do
    for outcome in success failure HUP INT TERM; do
        printf 'unstaged lockfile\n\000exact bytes' > "$fixture/original"
        if [ "$state" = present ]; then
            cp "$fixture/original" "$fixture/repo/Package.resolved"
        else
            rm -f "$fixture/repo/Package.resolved"
        fi
        status=0
        PATH="$fixture/bin:$PATH" TMPDIR="$fixture/tmp" ARGUMENTS="$fixture/arguments" OUTCOME="$outcome" \
            bash "$fixture/repo/scripts/linux-core-tests.sh" --filter CourseImageTests > "$fixture/output" 2>&1 || status=$?
        case "$outcome" in
            success) expected=0 ;;
            failure) expected=42 ;;
            HUP) expected=129 ;;
            INT) expected=130 ;;
            TERM) expected=143 ;;
        esac
        [ "$status" = "$expected" ] || { cat "$fixture/output"; echo "$state/$outcome: status $status, expected $expected" >&2; exit 1; }
        if [ "$state" = present ]; then
            cmp "$fixture/original" "$fixture/repo/Package.resolved"
        else
            [ ! -e "$fixture/repo/Package.resolved" ] || { echo "$outcome: recreated absent lockfile" >&2; exit 1; }
        fi
        git -C "$fixture/repo" show :Package.resolved > "$fixture/current-index"
        cmp "$fixture/index" "$fixture/current-index"
        [ -z "$(ls -A "$fixture/tmp")" ]
    done
done
python3 - "$fixture/arguments" <<'PYTHON'
import pathlib
import re
import sys

arguments = pathlib.Path(sys.argv[1]).read_text().splitlines()
assert arguments[0:2] == ["test", "--skip"]
assert arguments[3:] == ["--filter", "CourseImageTests"]
skip = re.compile(arguments[2])
for test in ("theCourseListCarriesThePicture", "anOddPictureFieldNeverBreaksTheList",
             "thePictureIsFetchedWithTheToken", "badAnswersAreErrors"):
    assert skip.search("BeepbarCoreTests.CourseImageTests/" + test + "()"), test
for test in ("theUploadedPictureWins", "aBrowserAddressBecomesTheWebServiceOne",
             "unacceptableAddressesAreDropped", "nonPictureOverviewFilesAreSkipped",
             "refusedAddressesAreNeverRequested", "aListSavedBeforeThePictureExistedStillLoads",
             "thePictureRoundTripsAndIsOmittedWhenAbsent"):
    assert not skip.search("BeepbarCoreTests.CourseImageTests/" + test + "()"), test
PYTHON
printf 'Linux wrapper regression passed (10 restoration cases and selective network exclusions).\n'
