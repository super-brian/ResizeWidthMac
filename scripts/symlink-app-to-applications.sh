#!/bin/bash
set -euo pipefail

# Point /Applications at the just-built .app so Login Items stay on a stable path.
SRC="${BUILT_PRODUCTS_DIR:?}/${FULL_PRODUCT_NAME:?}"
DEST="/Applications/ResizeWidthMac.app"

if [[ ! -e "$SRC" ]]; then
  echo "error: built app not found at $SRC" >&2
  exit 1
fi

if [[ -e "$DEST" && ! -L "$DEST" ]]; then
  echo "error: $DEST exists and is not a symlink; refusing to overwrite" >&2
  exit 1
fi

# Drop older Downloads-era links from earlier builds.
rm -f \
  "${HOME}/Downloads/ResizeWidthMac.app" \
  "${HOME}/Downloads/ResizeWidthMac-Xcode.app" \
  "${HOME}/Downloads/toResizeWidthMac.lnk"

ln -sfn "$SRC" "$DEST"
echo "Symlinked $DEST -> $SRC"
