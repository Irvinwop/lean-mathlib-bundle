#!/usr/bin/env bash
# Reassemble the Lean + Mathlib bundle from downloaded parts.
#
# Usage:
#   1. Download bundle-manifest, then every bundle-part-N artifact (or the single
#      bundle-all-parts artifact) into one directory.
#   2. Unzip each artifact so the bundle.tar.zst.partNN files sit side by side.
#   3. bash reassemble.sh [target_dir]        # default: $HOME/lean-bundle
#
# Afterwards:
#   export PATH="<target>/.elan/bin:$PATH"
#   cd <your lean project> && lake env lean YourFile.lean
set -euo pipefail

TARGET="${1:-$HOME/lean-bundle}"

shopt -s nullglob
PARTS=(bundle.tar.zst.part*)
if [ ${#PARTS[@]} -eq 0 ]; then
  echo "error: no bundle.tar.zst.part* files in $(pwd)" >&2
  exit 1
fi
echo "found ${#PARTS[@]} part(s)"

if [ -f MANIFEST.txt ]; then
  echo "verifying parts against MANIFEST.txt"
  fail=0
  while read -r name bytes sha; do
    case "$name" in bundle.tar.zst.part*) ;; *) continue ;; esac
    [ -f "$name" ] || { echo "  MISSING $name"; fail=1; continue; }
    got_b=$(stat -c%s "$name" 2>/dev/null || stat -f%z "$name")
    got_s=$(sha256sum "$name" | cut -d' ' -f1)
    if [ "$got_b" != "$bytes" ] || [ "$got_s" != "$sha" ]; then
      echo "  CORRUPT $name"; fail=1
    else
      echo "  ok $name"
    fi
  done < MANIFEST.txt
  [ "$fail" -eq 0 ] || { echo "error: part verification failed" >&2; exit 1; }

  want_total=$(awk -F': ' '/^bundle_sha256/{print $2}' MANIFEST.txt)
else
  echo "warning: no MANIFEST.txt; skipping verification" >&2
  want_total=""
fi

mkdir -p "$TARGET"
echo "extracting into $TARGET"
cat bundle.tar.zst.part* > bundle.tar.zst

if [ -n "$want_total" ]; then
  got_total=$(sha256sum bundle.tar.zst | cut -d' ' -f1)
  [ "$got_total" = "$want_total" ] || { echo "error: whole-bundle sha256 mismatch" >&2; exit 1; }
  echo "whole-bundle sha256 verified"
fi

zstd -d -c bundle.tar.zst | tar -x -C "$TARGET"
rm -f bundle.tar.zst

echo
echo "done. Enable it with:"
echo "  export PATH=\"$TARGET/.elan/bin:\$PATH\""
echo "  lean --version"
echo
echo "The .lake directory in $TARGET holds prebuilt Mathlib oleans for"
echo "toolchain $(cat "$TARGET/lean-toolchain" 2>/dev/null || echo '?')."
echo "Copy or symlink it into your Lean project so lake finds the packages."
