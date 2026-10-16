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
# "GridDock Local" is a self-signed certificate in the login keychain: its fixed identity keeps the
# Accessibility grant across rebuilds (ad-hoc signatures change with every build). Falls back to a valid
# Apple Development certificate, then ad-hoc.
IDENTITY=$(security find-identity -p codesigning | grep '"GridDock Local"' | head -1 | awk '{print $2}')
[ -z "$IDENTITY" ] && IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')
codesign --force --deep --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"
