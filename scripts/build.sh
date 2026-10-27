#!/bin/bash
set -euo pipefail
ORBIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORBIT_BUILD="$ORBIT_ROOT/.build"
ORBIT_APP="$ORBIT_ROOT/dist/Codex Orbit.app"
ORBIT_SDK="$(xcrun --sdk macosx --show-sdk-path)"
ORBIT_ARCH="$(uname -m)"
mkdir -p "$ORBIT_BUILD/module-cache" "$ORBIT_APP/Contents/MacOS" "$ORBIT_APP/Contents/Resources"
xcrun swiftc -swift-version 5 -parse-as-library -O \
  -target "${ORBIT_ARCH}-apple-macosx13.0" -sdk "$ORBIT_SDK" \
  -module-cache-path "$ORBIT_BUILD/module-cache" \
  -module-name CodexOrbit -lsqlite3 \
  "$ORBIT_ROOT"/Sources/CodexOrbit/*.swift \
  -o "$ORBIT_APP/Contents/MacOS/CodexOrbit"
cp "$ORBIT_ROOT/Resources/Info.plist" "$ORBIT_APP/Contents/Info.plist"
ditto "$ORBIT_ROOT/Resources/ProviderAssets" "$ORBIT_APP/Contents/Resources/ProviderAssets"
xcrun swiftc -swift-version 5 -module-cache-path "$ORBIT_BUILD/module-cache" \
  "$ORBIT_ROOT/scripts/MakeIcon.swift" -o "$ORBIT_BUILD/MakeIcon"
"$ORBIT_BUILD/MakeIcon" "$ORBIT_BUILD/AppIcon.iconset"
iconutil -c icns "$ORBIT_BUILD/AppIcon.iconset" -o "$ORBIT_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$ORBIT_APP"
codesign --verify --deep --strict "$ORBIT_APP"
printf 'Built: %s\n' "$ORBIT_APP"
