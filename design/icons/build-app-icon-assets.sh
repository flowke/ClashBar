#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/design/icons/app-icon-large-face-1024.png"
ASSETS="$ROOT/Sources/ClashBar/Resources/Assets.xcassets"
ICONSET="$ROOT/design/icons/ClashBar.iconset"

# The confirmed large-face source is shared by AppKit, actool and packaging.
test -f "$SOURCE"
cp "$SOURCE" "$ASSETS/BrandAppIcon.imageset/app-icon.png"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((size * scale))
    suffix=""
    if [ "$scale" = 2 ]; then suffix="@2x"; fi
    filename="icon_${size}x${size}${suffix}.png"
    if [ "$pixels" = 1024 ]; then
      cp "$SOURCE" "$ICONSET/$filename"
    else
      sips -z "$pixels" "$pixels" "$SOURCE" --out "$ICONSET/$filename" >/dev/null
    fi
    cp "$ICONSET/$filename" "$ASSETS/AppIcon.appiconset/$filename"
  done
done

iconutil --convert icns "$ICONSET" --output "$ROOT/design/icons/ClashBar.icns"
echo "Prepared BrandAppIcon, all AppIcon slots and ClashBar.icns from app-icon-large-face-1024.png"
