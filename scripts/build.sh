#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
app='dist/Extract IPs.app'
mkdir -p .build/module-cache "$app/Contents/MacOS" "$app/Contents/Resources"
architectures=("$(uname -m)")
if [[ "${1:-}" == '--universal' ]]; then
  architectures=(arm64 x86_64)
elif [[ $# -gt 0 ]]; then
  echo 'Usage: scripts/build.sh [--universal]' >&2
  exit 2
fi
for architecture in "${architectures[@]}"; do
  xcrun swiftc -swift-version 5 -O -module-cache-path .build/module-cache \
    -target "$architecture-apple-macosx13.0" \
    build/DesignTokens.swift Sources/*.swift -o ".build/ExtractIPs-$architecture"
done
if [[ ${#architectures[@]} == 2 ]]; then
  xcrun lipo -create .build/ExtractIPs-arm64 .build/ExtractIPs-x86_64 -output "$app/Contents/MacOS/ExtractIPs"
else
  cp ".build/ExtractIPs-${architectures[1]}" "$app/Contents/MacOS/ExtractIPs"
fi
cp Info.plist "$app/Contents/Info.plist"
cp -R Resources/. "$app/Contents/Resources/"
cp DISCLAIMER.md "$app/Contents/Resources/"
codesign --force --sign - "$app"
echo "Built: $PWD/dist/Extract IPs.app"
