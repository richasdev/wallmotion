#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/build-native.sh
swift build -j 2 -c release
binary_dir=$(swift build -j 2 -c release --show-bin-path)
app_dir="dist/Wallmotion.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Wallmotion" "$app_dir/Contents/MacOS/Wallmotion"
cp resources/Info.plist "$app_dir/Contents/Info.plist"
test -s resources/AppIcon.icns
cp resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
plutil -lint "$app_dir/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$app_dir"
codesign --verify --strict "$app_dir"
printf 'App de desenvolvimento: %s\n' "$app_dir"
