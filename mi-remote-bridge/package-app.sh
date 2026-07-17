#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP="$SCRIPT_DIR/dist/MiRemoteBridge.app"
CONTENTS="$APP/Contents"

cd "$SCRIPT_DIR"
swift build -c release

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS"
cp "$SCRIPT_DIR/.build/release/MiRemoteBridge" "$CONTENTS/MacOS/MiRemoteBridge"
cp "$SCRIPT_DIR/Packaging/Info.plist" "$CONTENTS/Info.plist"
chmod 755 "$CONTENTS/MacOS/MiRemoteBridge"

# Give the ad-hoc build a stable designated requirement. Without this,
# codesign falls back to a CDHash-only requirement, so every rebuild looks
# like a different application to Accessibility/Input Monitoring (TCC).
codesign \
  --force \
  --deep \
  --sign - \
  --timestamp=none \
  --requirements '=designated => identifier "local.simaqingfeng.MiRemoteBridge"' \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
print "Built: $APP"
