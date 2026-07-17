#!/bin/bash
set -euo pipefail

# macOS symlinks have no special extension (unlike Windows .lnk).
# Keep a ".app" suffix so Finder launches it; use a distinct name so it's obvious.
SRC="${BUILT_PRODUCTS_DIR:?}/${FULL_PRODUCT_NAME:?}"
DEST="${HOME}/Downloads/ResizeWidthMac-Xcode.app"

if [[ ! -e "$SRC" ]]; then
  echo "error: built app not found at $SRC" >&2
  exit 1
fi

# Remove older link/copy names and the current destination.
rm -rf \
  "${HOME}/Downloads/ResizeWidthMac.app" \
  "${HOME}/Downloads/toResizeWidthMac.lnk" \
  "$DEST"

ln -s "$SRC" "$DEST"
echo "Symlinked $DEST -> $SRC"
