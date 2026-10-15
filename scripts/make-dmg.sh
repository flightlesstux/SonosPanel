#!/bin/zsh
# Builds the app and packages it as build/SonosPanel-<version>.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh >/dev/null
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/SonosPanel.app/Contents/Info.plist)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R build/SonosPanel.app "$stage/"
ln -s /Applications "$stage/Applications"
dmg="build/SonosPanel-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "SonosPanel $version" -srcfolder "$stage" -format UDZO -ov "$dmg"
ls -lh "$dmg"
