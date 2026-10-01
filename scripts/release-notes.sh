#!/bin/bash
set -euo pipefail

awk '
  /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ { if (found) exit; found = 1; next }
  /^## / { if (found) exit }
  found { print; if ($0 ~ /[^[:space:]]/) content = 1 }
  END { if (!content) exit 1 }
' "${1:-CHANGELOG.md}"
