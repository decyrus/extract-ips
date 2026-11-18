#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
source='docs/app-icon.png'
iconset='.build/AppIcon.iconset'
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
echo 'Built: Resources/AppIcon.icns'
