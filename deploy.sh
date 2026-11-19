#!/usr/bin/env bash
# Copies addons/<Name>/ into the WoW Forever AddOns folder. Usage: ./deploy.sh [AddonName ...]
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/addons"
DEST="${WOW_ADDONS:-/mnt/t/World of Warcraft/_forever_/Interface/AddOns}"
[ -d "$DEST" ] || { echo "AddOns folder not found: $DEST" >&2; exit 1; }
names=("$@")
[ ${#names[@]} -gt 0 ] || names=($(ls "$SRC"))
for name in "${names[@]}"; do
  [ -f "$SRC/$name/$name.toc" ] || { echo "skip $name (no $name.toc)" >&2; continue; }
  if command -v luac5.1 >/dev/null; then
    find "$SRC/$name" -name '*.lua' -print0 | xargs -0 -r luac5.1 -p
  fi
  rsync -a --delete "$SRC/$name/" "$DEST/$name/"
  echo "deployed $name -> $DEST/$name"
done
