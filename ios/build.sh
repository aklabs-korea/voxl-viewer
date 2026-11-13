#!/bin/bash
# Builds the iPhone and iPad app on a Mac with Xcode 27.2+ and XcodeGen (brew install xcodegen).
#
#   ios/build.sh sim          build for a simulator, install it there and open it
#   ios/build.sh uitest       the gesture and key test in a simulator (needs a dev voxl: see GestureTests);
#                             ONLY=GestureTests/testLayout or ONLY=ReproTests runs part of it
#   ios/build.sh testflight   archive, sign in Apple's cloud and upload to TestFlight
#
# SIM=<name or id> picks the simulator (default: the first iPhone Duo).
# TESTLOG=<url> makes a test build, which posts what it measures to that URL (ios/testlog.py) every
# 10 s; without it the app sends nothing anywhere but the voxl links it is given.
# testflight signs with an App Store Connect API key: ASC_ENV (default ~/.appstoreconnect/asc.env)
# sets ASC_KEY_ID and ASC_ISSUER_ID, and the key is ~/.appstoreconnect/private_keys/AuthKey_<id>.p8.
# The archive is unsigned and Xcode signs the export in Apple's cloud, so it runs over SSH with no
# keychain and no Xcode account. TEAM sets the Apple team (default: the one in project.yml).
set -euo pipefail
cd "$(dirname "$0")"
export PATH=/opt/homebrew/bin:$PATH
work=~/.cache/voxl-ios
mkdir -p "$work"
testlog=${TESTLOG:-}
team=${TEAM:-L52Z6X4335}
xcodegen generate --quiet

simulator() {
  local want=${SIM:-iPhone Duo}
  if [[ $want =~ ^[0-9A-F-]{36}$ ]]; then echo "$want"; return; fi
  xcrun simctl list devices available | grep -F "$want (" | sed -n 's/.*(\([0-9A-F-]\{36\}\)).*/\1/p' | head -1
}

case "${1:-}" in
sim)
  xcodebuild -project Voxl.xcodeproj -scheme Voxl -sdk iphonesimulator -configuration Debug \
    -derivedDataPath "$work/dd-sim" build CODE_SIGNING_ALLOWED=NO VOXL_TESTLOG="$testlog" -quiet
  sim=$(simulator)
  xcrun simctl boot "$sim" 2>/dev/null || true
  xcrun simctl install "$sim" "$work/dd-sim/Build/Products/Debug-iphonesimulator/Voxl.app"
  xcrun simctl launch --terminate-running-process "$sim" la.aklabs.voxl
  echo "running on simulator $sim"
  ;;
uitest)
  xcodebuild test -project Voxl.xcodeproj -scheme Voxl -destination "platform=iOS Simulator,id=$(simulator)" \
    -derivedDataPath "$work/dd-sim" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    VOXL_TESTLOG="$testlog" ${ONLY:+-only-testing:VoxlUITests/$ONLY} -quiet
  ;;
testflight)
  source "${ASC_ENV:-$HOME/.appstoreconnect/asc.env}"
  key=~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
  auth=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  hide() { sed -e "s/$ASC_KEY_ID/<key-id>/g" -e "s/$ASC_ISSUER_ID/<issuer-id>/g"; }
  build=$(date +%Y%m%d%H%M)
  archive="$work/archives/Voxl-$build.xcarchive"
  out=$(mktemp -d "$work/tf.XXXXXX")
  xcodebuild archive -project Voxl.xcodeproj -scheme Voxl -configuration Release -destination generic/platform=iOS \
    -archivePath "$archive" -derivedDataPath "$work/dd-release" CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM="$team" \
    CURRENT_PROJECT_VERSION="$build" VOXL_TESTLOG="$testlog" > "$out/archive.log" 2>&1 \
    || { grep -E 'error' "$out/archive.log" | tail -20; echo "ARCHIVE FAILED"; exit 1; }
  cat > "$out/options.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/options.plist" \
    -exportPath "$out/export" -allowProvisioningUpdates "${auth[@]}" 2>&1 | hide > "$out/export.log" \
    || { grep -vE '^\s*$' "$out/export.log" | tail -15; echo "UPLOAD FAILED"; exit 1; }
  grep -q 'EXPORT SUCCEEDED' "$out/export.log" || { tail -15 "$out/export.log"; echo "UPLOAD FAILED"; exit 1; }
  echo "uploaded build $build${testlog:+ (a test build)}; App Store Connect processes it in about 5-15 minutes"
  ;;
*) echo "usage: ios/build.sh sim|uitest|testflight" >&2; exit 2 ;;
esac
