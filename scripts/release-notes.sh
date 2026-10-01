#!/bin/bash
set -euo pipefail

awk -v repository="${GITHUB_REPOSITORY:-tommaso-vaccari/BeepBar}" '
  /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ { if (found) exit; found = 1; date = $2; next }
  /^## / { if (found) exit }
  found && /^### Release highlights$/ { summary = 1; next }
  summary && /^### / { exit }
  summary { print; if ($0 ~ /^- /) highlights = 1 }
  END {
    if (!highlights) exit 1
    print "\n[Read the full changelog](https://github.com/" repository "/blob/main/CHANGELOG.md#" date ")."
  }
' "${1:-CHANGELOG.md}"
