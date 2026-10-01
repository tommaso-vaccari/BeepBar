#!/bin/bash
set -euo pipefail

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
script="$(dirname "$0")/release-notes.sh"
export GITHUB_REPOSITORY=example/BeepBar
cat > "$fixture/changelog" <<'NOTES'
# Changelog
## Unreleased
### Release highlights
- Future feature.
## 2026-10-01
### Release highlights
- Open documents from Activity.
- Cancel returns to Sync now.

**After updating:** A login-item notice may appear.
### New
- Detailed explanation.
## 2026-09-28
### Release highlights
- Older change.
NOTES
bash "$script" "$fixture/changelog" > "$fixture/notes"
cat > "$fixture/expected" <<'NOTES'
- Open documents from Activity.
- Cancel returns to Sync now.

**After updating:** A login-item notice may appear.

[Read the full changelog](https://github.com/example/BeepBar/blob/main/CHANGELOG.md#2026-10-01).
NOTES
diff -u "$fixture/expected" "$fixture/notes"
for invalid in \
  $'# Changelog\n## Unreleased\n### Release highlights\n- Future feature.\n' \
  $'## 2026-10-01\n### Release highlights\n\n## 2026-09-28\n### Release highlights\n- Older change.\n' \
  $'## 2026-10-01\n### New\n- Detailed explanation.\n## 2026-09-28\n### Release highlights\n- Older change.\n' \
  $'## 2026-10-01\n### Release highlights\n**After updating:** Notice only.\n'; do
  printf '%s' "$invalid" > "$fixture/changelog"
  if bash "$script" "$fixture/changelog" > "$fixture/notes"; then exit 1; fi
done
printf '## 2026-10-01\n### Release highlights\n- First release.\n' > "$fixture/changelog"
bash "$script" "$fixture/changelog" > "$fixture/notes"
cat > "$fixture/expected" <<'NOTES'
- First release.

[Read the full changelog](https://github.com/example/BeepBar/blob/main/CHANGELOG.md#2026-10-01).
NOTES
diff -u "$fixture/expected" "$fixture/notes"
