#!/bin/sh
# Prints the version of the next release: MAJOR.MINOR.PATCH, from the project's MARKETING_VERSION
# (MAJOR.MINOR) and the tag of the last published release (vMAJOR.MINOR.PATCH).
#
# - A base above the last release's MAJOR.MINOR starts a new line at PATCH 0: base 3.0 after
#   v2.2.35 is 3.0.0.
# - The same MAJOR.MINOR moves PATCH up by one: base 3.0 after v3.0.0 is 3.0.1.
# - A base below the last release fails, since Sparkle would not offer it as an update.
#
# Versions only ever grow from one release to the next, which is what Sparkle needs. The script
# reads no git state: CI looks up the previous tag and passes it in, so it can be tested anywhere.
#
# usage: build-version.sh <MARKETING_VERSION, e.g. 3.0> <previous release tag, e.g. v2.2.35>
set -eu

if [ $# -ne 2 ]; then
  echo "usage: build-version.sh <MAJOR.MINOR> <vMAJOR.MINOR.PATCH>" >&2
  exit 1
fi
base=$1
previous=$2

is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

case "$base" in *.*.*) echo "invalid base version: $base (expected MAJOR.MINOR)" >&2; exit 1 ;; *.*) ;; *) echo "invalid base version: $base (expected MAJOR.MINOR)" >&2; exit 1 ;; esac
major=${base%%.*}
minor=${base#*.}
if ! is_number "$major" || ! is_number "$minor"; then
  echo "invalid base version: $base" >&2; exit 1
fi

case "$previous" in v*) ;; *) echo "invalid previous release tag: '$previous' (expected vMAJOR.MINOR.PATCH)" >&2; exit 1 ;; esac
rest=${previous#v}
case "$rest" in *.*.*.*) echo "invalid previous release tag: $previous" >&2; exit 1 ;; *.*.*) ;; *) echo "invalid previous release tag: $previous" >&2; exit 1 ;; esac
prev_major=${rest%%.*}
rest=${rest#*.}
prev_minor=${rest%%.*}
prev_patch=${rest#*.}
if ! is_number "$prev_major" || ! is_number "$prev_minor" || ! is_number "$prev_patch"; then
  echo "invalid previous release tag: $previous" >&2; exit 1
fi

# Drop leading zeros so $(( )) never reads a number as octal.
decimal() { n=$(echo "$1" | sed 's/^0*//'); echo "${n:-0}"; }
major=$(decimal "$major"); minor=$(decimal "$minor")
prev_major=$(decimal "$prev_major"); prev_minor=$(decimal "$prev_minor"); prev_patch=$(decimal "$prev_patch")
if [ "$major" -gt "$prev_major" ] || { [ "$major" -eq "$prev_major" ] && [ "$minor" -gt "$prev_minor" ]; }; then
  echo "$major.$minor.0"
elif [ "$major" -eq "$prev_major" ] && [ "$minor" -eq "$prev_minor" ]; then
  echo "$major.$minor.$((prev_patch + 1))"
else
  echo "base version $base is below the last release $previous" >&2
  exit 1
fi
