#!/bin/bash
# Makes a launcher for one machine: ~/Applications/voxl viewer/NAME.app, a copy of voxl viewer
# that opens URL, with its own name, Dock icon and window memory.
#
#   mac/make-shortcut.sh NAME URL
#   mac/make-shortcut.sh "My Mac" https://my-mac.example.ts.net:6901/
#
# The copy is made from build/voxl viewer.app, else /Applications or ~/Applications.
# VOXL_VIEWER_APP=/path/to/voxl\ viewer.app picks another one; SHORTCUT_DIR=/some/dir writes
# the launcher there instead.
set -euo pipefail

usage='usage: mac/make-shortcut.sh NAME URL   (URL like https://my-mac.example.ts.net:6901/)'
[ $# -eq 2 ] || { echo "$usage" >&2; exit 2; }
name=$1
url=$2
case "$url" in http://?*|https://?*) ;; *) echo "$usage" >&2; exit 2 ;; esac
case "$name" in ""|.*|*/*) echo "NAME can't be empty, start with a dot or contain /" >&2; exit 2 ;; esac

root="$(cd "$(dirname "$0")/.." && pwd)"
src="${VOXL_VIEWER_APP:-}"
if [ -z "$src" ]; then
  for candidate in "$root/build/voxl viewer.app" "/Applications/voxl viewer.app" "$HOME/Applications/voxl viewer.app"; do
    if [ -d "$candidate" ]; then src=$candidate; break; fi
  done
fi
if [ -z "$src" ] || [ ! -d "$src" ]; then
  echo "voxl viewer.app not found: run mac/build.sh first, or set VOXL_VIEWER_APP" >&2
  exit 1
fi

dir="${SHORTCUT_DIR:-$HOME/Applications/voxl viewer}"
app="$dir/$name.app"

# Its own bundle id, so macOS treats it as its own app: the main id plus the name in lowercase
# letters and digits, and a hash of the exact name, so "My Mac" and "My-Mac" stay two apps.
slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9' '-' | tr -s '-' | sed 's/^-//; s/-$//')
hash=$(printf '%s' "$name" | md5 | cut -c1-8)
slug=${slug:+$slug-}$hash
base=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$src/Contents/Info.plist")

mkdir -p "$dir"
rm -rf "$app"
ditto --noqtn "$src" "$app"
plist="$app/Contents/Info.plist"
plutil -replace CFBundleName -string "$name" "$plist"
plutil -replace CFBundleDisplayName -string "$name" "$plist"
plutil -replace CFBundleIdentifier -string "$base.$slug" "$plist"
plutil -replace VoxlURL -string "$url" "$plist"
# The changed Info.plist needs a new signature; an ad-hoc one is enough for an app made here.
codesign --force --sign - "$app"

echo "made $app"
echo "open it from Finder or Spotlight, or: open \"$app\""
