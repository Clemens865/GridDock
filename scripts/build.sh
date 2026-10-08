#!/bin/zsh
# Builds GridDock.app, signs it with a stable identity (keeps the Accessibility grant across rebuilds)
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP=build/GridDock.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/GridDock "$APP/Contents/MacOS/GridDock"
cp Resources/Info.plist "$APP/Contents/Info.plist"
IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')
codesign --force --deep --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"
