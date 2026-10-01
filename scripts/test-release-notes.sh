#!/bin/bash
set -euo pipefail

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
script="$(dirname "$0")/release-notes.sh"
cat > "$fixture/changelog" <<'EOF'
# Changelog
## Unreleased
- Future feature.
## 2026-10-01
### New
- Open documents from Activity.
### Fixed
- Cancel returns to Sync now.
## 2026-09-28
- Older change.
EOF
bash "$script" "$fixture/changelog" > "$fixture/notes"
cat > "$fixture/expected" <<'EOF'
### New
- Open documents from Activity.
### Fixed
- Cancel returns to Sync now.
EOF
diff -u "$fixture/expected" "$fixture/notes"
printf '# Changelog\n## Unreleased\n- Future feature.\n' > "$fixture/changelog"
if bash "$script" "$fixture/changelog"; then exit 1; fi
printf '## 2026-10-01\n\n## 2026-09-28\n- Older change.\n' > "$fixture/changelog"
if bash "$script" "$fixture/changelog"; then exit 1; fi
printf '## 2026-10-01\n- First release.\n' > "$fixture/changelog"
bash "$script" "$fixture/changelog" > "$fixture/notes"
printf '%s\n' '- First release.' > "$fixture/expected"
diff -u "$fixture/expected" "$fixture/notes"
