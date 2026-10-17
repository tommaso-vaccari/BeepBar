#!/bin/bash
# Prints the GitHub release notes: the `### Release highlights` block of the newest dated
# (`## YYYY-MM-DD`) section of CHANGELOG.md, followed by a link to that section.
#
# Usage: release-notes.sh [CHANGELOG] [PREVIOUS_CHANGELOG]
#
# It is the release gate for the changelog (issue #210): the release job publishes whatever this
# prints, so it exits non-zero instead of printing stale or empty notes when
#   - `## Unreleased` still holds any line: the release PR was merged without moving its entries
#     under a dated heading, and the notes would otherwise be the previous release's;
#   - the newest dated section has no `### Release highlights` bullet;
#   - PREVIOUS_CHANGELOG (the CHANGELOG.md of the last published release) is given and yields
#     exactly the same notes: nothing new was dated since that release.
# A PREVIOUS_CHANGELOG whose own notes can't be extracted (older format) is not compared.
set -euo pipefail

changelog="${1:-CHANGELOG.md}"
previous="${2:-}"

# Prints the notes of a changelog; with check_unreleased=1 also fails on a non-empty Unreleased.
extract() {
  awk -v repository="${GITHUB_REPOSITORY:-tommaso-vaccari/BeepBar}" -v check_unreleased="$2" '
    /^## Unreleased$/ { if (found) exit; unreleased = 1; next }
    /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ { if (found) exit; unreleased = 0; found = 1; date = $2; next }
    /^## / { if (found) exit; unreleased = 0 }
    unreleased && check_unreleased && /[^[:space:]]/ {
      print "release-notes: \"## Unreleased\" still has entries (line " NR "); move them under a dated heading before releasing." > "/dev/stderr"
      pending = 1; exit
    }
    found && /^### Release highlights$/ { summary = 1; next }
    summary && /^### / { exit }
    summary { print; if ($0 ~ /^- /) highlights = 1 }
    END {
      if (pending) exit 2
      if (!highlights) {
        print "release-notes: the newest dated section has no \"### Release highlights\" bullet." > "/dev/stderr"
        exit 1
      }
      print "\n[Read the full changelog](https://github.com/" repository "/blob/main/CHANGELOG.md#" date ")."
    }
  ' "$1"
}

notes=$(extract "$changelog" 1)
if [ -n "$previous" ] && previous_notes=$(extract "$previous" 0 2>/dev/null) && [ "$notes" = "$previous_notes" ]; then
  echo "release-notes: the notes are the same as the previous release's; add a new dated section." >&2
  exit 3
fi
printf '%s\n' "$notes"
