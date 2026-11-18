#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh --universal
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
package="Extract-IPs-$version-macOS-universal"
staging=$(mktemp -d "$PWD/.build/package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto 'dist/Extract IPs.app' "$staging/Extract IPs.app"
cp README.md README.ru.md DISCLAIMER.md "$staging/"
ditto docs "$staging/docs"
ln -s /Applications "$staging/Applications"
ditto -c -k --sequesterRsrc --keepParent 'dist/Extract IPs.app' "dist/$package.zip"
hdiutil create -volname 'Extract IPs' -srcfolder "$staging" -ov -format UDZO "dist/$package.dmg"
(
  cd dist
  shasum -a 256 "$package.zip" "$package.dmg" > SHA256SUMS.txt
)
echo "Packaged: dist/$package.zip and dist/$package.dmg"
