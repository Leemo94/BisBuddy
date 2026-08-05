#!/bin/bash
# Build BisBuddy zips from the local BisBuddy/ folder.
#
#   • DEV build  -> .toc Version keeps a "-dev" suffix -> SILENT: never broadcasts
#     its version, so your own testing never nags the guild "you're out of date".
#   • RELEASE build -> "-dev" stripped -> broadcasts normally (the DBM-style nudge
#     so guildies on an older build get told to update).
#
# The ONLY difference between the two is that .toc Version suffix. Run this whenever
# you want a guild release; test with the -dev zip (or your local folder) first.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/BisBuddy"
[ -f "$SRC/BisBuddy.toc" ] || { echo "error: no BisBuddy/BisBuddy.toc next to this script"; exit 1; }

DEVVER="$(grep -i '^## Version:' "$SRC/BisBuddy.toc" | head -1 | sed 's/.*: *//' | tr -d '[:space:]')"
RELVER="${DEVVER%-dev}"; RELVER="${RELVER%-DEV}"
case "$DEVVER" in *-dev|*-DEV) ;; *) DEVVER="${RELVER}-dev" ;; esac   # always give the dev zip a -dev tag

build() {  # $1 = version to stamp into the zip's .toc ; $2 = output zip path
  local tmp; tmp="$(mktemp -d)"
  cp -R "$SRC" "$tmp/BisBuddy"
  sed -i '' "s/^## Version:.*/## Version: $1/" "$tmp/BisBuddy/BisBuddy.toc"
  rm -f "$2"
  ( cd "$tmp" && zip -qr "$2" BisBuddy -x '*.DS_Store' '*/.git/*' )
  rm -rf "$tmp"
}

build "$DEVVER" "$HERE/BisBuddy-${RELVER}-dev.zip"
build "$RELVER" "$HERE/BisBuddy-${RELVER}.zip"

echo "Built two zips in $HERE :"
echo "  • BisBuddy-${RELVER}-dev.zip   (## Version: ${DEVVER})  ->  SILENT  - for your own testing"
echo "  • BisBuddy-${RELVER}.zip       (## Version: ${RELVER})  ->  RELEASE - broadcasts its version"
echo
echo "Give the guild ONLY BisBuddy-${RELVER}.zip. Keep testing with the -dev one."
