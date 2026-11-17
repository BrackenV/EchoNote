#!/bin/zsh
set -eu
cd "${0:A:h}"
cargo build --release
APP="dist/Lecture Recorder.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -whole-module-optimization -module-cache-path "${TMPDIR:-/private/tmp}/lecture-swift-cache" -import-objc-header native/Audio.h native/Main.swift -L target/release -llecture_audio -framework AppKit -framework AVFoundation -framework IOKit -framework Security -framework SystemConfiguration -Xlinker -dead_strip -o "$APP/Contents/MacOS/Lecture Recorder"
cp native/Info.plist "$APP/Contents/Info.plist"
swift -module-cache-path "${TMPDIR:-/private/tmp}/lecture-swift-cache" native/Icon.swift dist/AppIcon.iconset
sips -s format icns dist/AppIcon.iconset/icon_512x512.png --out "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
