#!/usr/bin/env bash
# Install this fork into Transport Fever 2's local mods folder as bus_line_tool_fixed_1.
# Override the destination root with TPF2_LOCAL_MODS=/path/to/local/mods.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODS="${TPF2_LOCAL_MODS:-$HOME/.local/share/Steam/userdata/204184616/1066780/local/mods}"
DEST="$MODS/bus_line_tool_fixed_1"
mkdir -p "$DEST"
rsync -a --delete \
  --exclude .git --exclude docs --exclude test --exclude install.sh \
  --exclude README.md --exclude .gitignore --exclude workshop_fileid.txt \
  "$SRC/" "$DEST/"
echo "installed to $DEST"
