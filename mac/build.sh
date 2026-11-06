#!/bin/bash
# Builds build/voxl viewer.app from mac/VoxlViewer.swift with swiftc (no Xcode project).
#
#   mac/build.sh [--universal] [--sign "Developer ID Application: ..."]
#
# --universal  one binary for Apple silicon and Intel (arm64 + x86_64).
# --sign ID    sign with that identity and the hardened runtime, ready to notarize.
#              Without it the app gets an ad-hoc signature.
# VERSION=1.2.3 sets the app's version (default: the latest git tag, else 0.0.0).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
universal=0
identity=""
while [ $# -gt 0 ]; do
  case "$1" in
    --universal) universal=1 ;;
    --sign) identity="${2:?--sign needs an identity}"; shift ;;
    *) echo "usage: mac/build.sh [--universal] [--sign IDENTITY]" >&2; exit 2 ;;
  esac
  shift
done

version="${VERSION:-$(git -C "$root" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
version="${version:-0.0.0}"
app="$root/build/voxl viewer.app"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

archs="$(uname -m)"
[ $universal = 1 ] && archs="arm64 x86_64"
bins=()
for arch in $archs; do
  swiftc -O -target "$arch-apple-macos14.0" -o "$work/VoxlViewer-$arch" "$root/mac/VoxlViewer.swift"
  bins+=("$work/VoxlViewer-$arch")
done
lipo -create "${bins[@]}" -output "$app/Contents/MacOS/VoxlViewer"

# The icon is voxl's own favicon (icon/voxl.ico, 32 pixels; MIT, Tembo).
mkdir "$work/voxl.iconset"
sips -s format png "$root/icon/voxl.ico" --out "$work/voxl.png" >/dev/null
sips -z 16 16 "$work/voxl.png" --out "$work/voxl.iconset/icon_16x16.png" >/dev/null
cp "$work/voxl.png" "$work/voxl.iconset/icon_16x16@2x.png"
cp "$work/voxl.png" "$work/voxl.iconset/icon_32x32.png"
iconutil -c icns -o "$app/Contents/Resources/voxl.icns" "$work/voxl.iconset"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>voxl viewer</string>
  <key>CFBundleDisplayName</key><string>voxl viewer</string>
  <key>CFBundleIdentifier</key><string>io.github.danyeoakl.voxl-viewer</string>
  <key>CFBundleExecutable</key><string>VoxlViewer</string>
  <key>CFBundleIconFile</key><string>voxl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>voxl can send your microphone to the remote machine when you turn it on in voxl's toolbar.</string>
</dict>
</plist>
EOF

if [ -n "$identity" ]; then
  # The hardened runtime needs this for voxl's microphone button.
  cat > "$work/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
EOF
  codesign --force --options runtime --timestamp --entitlements "$work/entitlements.plist" \
    --sign "$identity" "$app"
else
  codesign --force --sign - "$app"
fi

echo "built $app ($(lipo -archs "$app/Contents/MacOS/VoxlViewer"), version $version)"
