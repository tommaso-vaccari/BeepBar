#!/bin/bash
# Checks scripts/release-notes.sh, the release gate for the changelog (issue #210), on fixtures:
# the notes it prints for a valid changelog, and that it refuses every changelog it must block.
set -euo pipefail

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
script="$(dirname "$0")/release-notes.sh"
export GITHUB_REPOSITORY=example/BeepBar

# Valid: an empty Unreleased on top, then the newest dated section with highlights.
cat > "$fixture/changelog" <<'NOTES'
# Changelog

## Unreleased

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
cp "$fixture/changelog" "$fixture/valid"
bash "$script" "$fixture/changelog" > "$fixture/notes"
cat > "$fixture/expected" <<'NOTES'
- Open documents from Activity.
- Cancel returns to Sync now.

**After updating:** A login-item notice may appear.

[Read the full changelog](https://github.com/example/BeepBar/blob/main/CHANGELOG.md#2026-10-01).
NOTES
diff -u "$fixture/expected" "$fixture/notes"

# Each changelog below must be refused. The second and third ones guard against the stale-notes
# release of issue #210: entries left under Unreleased while an older dated section would pass.
for invalid in \
  $'# Changelog\n## Unreleased\n### Release highlights\n- Future feature.\n' \
  $'# Changelog\n## Unreleased\n### New\n- Future feature.\n## 2026-10-01\n### Release highlights\n- Old change.\n' \
  $'# Changelog\n\n## Unreleased\n\n- Loose entry.\n\n## 2026-10-01\n### Release highlights\n- Old change.\n' \
  $'## 2026-10-01\n### Release highlights\n\n## 2026-09-28\n### Release highlights\n- Older change.\n' \
  $'## 2026-10-01\n### New\n- Detailed explanation.\n## 2026-09-28\n### Release highlights\n- Older change.\n' \
  $'## 2026-10-01\n### Release highlights\n**After updating:** Notice only.\n'; do
  printf '%s' "$invalid" > "$fixture/changelog"
  if bash "$script" "$fixture/changelog" > "$fixture/notes" 2> /dev/null; then
    printf 'release-notes.sh accepted an invalid changelog:\n%s\n' "$invalid" >&2
    exit 1
  fi
done

# Previous release's changelog: identical notes are refused (nothing new was dated since then)...
if bash "$script" "$fixture/valid" "$fixture/valid" > "$fixture/notes" 2> /dev/null; then
  echo 'release-notes.sh accepted the same notes as the previous release' >&2
  exit 1
fi
# ...even when the previous release itself still had entries under Unreleased: those must not
# make its notes unreadable and so silently skip the comparison.
{ printf '# Changelog\n## Unreleased\n- Pending then.\n'; tail -n +4 "$fixture/valid"; } > "$fixture/previous"
if bash "$script" "$fixture/valid" "$fixture/previous" > "$fixture/notes" 2> /dev/null; then
  echo 'release-notes.sh skipped the comparison with a previous changelog that had Unreleased entries' >&2
  exit 1
fi
# ...a previous release with older notes passes...
printf '## 2026-09-28\n### Release highlights\n- Older change.\n' > "$fixture/previous"
bash "$script" "$fixture/valid" "$fixture/previous" > "$fixture/notes"
cat > "$fixture/expected" <<'NOTES'
- Open documents from Activity.
- Cancel returns to Sync now.

**After updating:** A login-item notice may appear.

[Read the full changelog](https://github.com/example/BeepBar/blob/main/CHANGELOG.md#2026-10-01).
NOTES
diff -u "$fixture/expected" "$fixture/notes"
# ...and so does one in an older format, whose notes can't be extracted (no highlights).
printf '# Changelog\n## Unreleased\n- Old pending entry.\n## 2026-09-28\n### New\n- Older change.\n' > "$fixture/previous"
bash "$script" "$fixture/valid" "$fixture/previous" > "$fixture/notes"
diff -u "$fixture/expected" "$fixture/notes"

printf '## 2026-10-01\n### Release highlights\n- First release.\n' > "$fixture/changelog"
bash "$script" "$fixture/changelog" > "$fixture/notes"
cat > "$fixture/expected" <<'NOTES'
- First release.

[Read the full changelog](https://github.com/example/BeepBar/blob/main/CHANGELOG.md#2026-10-01).
NOTES
diff -u "$fixture/expected" "$fixture/notes"
