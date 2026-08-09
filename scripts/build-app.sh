#!/bin/bash
set -euo pipefail

# Builds a distributable SwarmBar.app: archives the Release config, then
# exports with the Developer ID method.
#
# The export, rather than a plain `build`, is what strips the get-task-allow
# debug entitlement, adds the secure timestamp, and signs nested code
# correctly, so the result actually passes notarization.
#
# Output: build/SwarmBar.app
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SwarmBar"
ARCHIVE="$ROOT/build/$APP_NAME.xcarchive"
EXPORT_DIR="$ROOT/build/export"
APP_DIR="$ROOT/build/$APP_NAME.app"

# The .xcodeproj is generated, not committed.
command -v xcodegen >/dev/null || { echo "error: xcodegen not installed (brew install xcodegen)"; exit 1; }
echo "==> Generating the project"
(cd "$ROOT" && xcodegen generate)

echo "==> Archiving $APP_NAME (Release)"
rm -rf "$ARCHIVE"
xcodebuild -project "$ROOT/$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -archivePath "$ARCHIVE" \
    archive

echo "==> Exporting Developer ID app"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist"

[ -d "$EXPORT_DIR/$APP_NAME.app" ] || { echo "error: export produced no $APP_NAME.app"; exit 1; }
rm -rf "$APP_DIR"
cp -R "$EXPORT_DIR/$APP_NAME.app" "$APP_DIR"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP_DIR"
SIGINFO="$(codesign -dvv "$APP_DIR" 2>&1 || true)"
echo "$SIGINFO" | grep -E "Authority=|TeamIdentifier=|runtime" || true

# Capture first, then match. Piping to `grep -q` under pipefail can SIGPIPE
# the producer and read as a false failure.
case "$SIGINFO" in
    *"Authority=Developer ID Application"*) ;;
    *) echo "error: $APP_NAME.app is not Developer ID signed"; exit 1 ;;
esac
case "$SIGINFO" in
    *runtime*) ;;
    *) echo "error: hardened runtime missing, notarization will reject this"; exit 1 ;;
esac

ENTS="$(codesign -d --entitlements - "$APP_DIR" 2>/dev/null || true)"
case "$ENTS" in
    *get-task-allow*) echo "error: get-task-allow present, this is a development signature, not distributable"; exit 1 ;;
esac

# The one check the other projects do not need. Under the hardened runtime
# SwarmBar cannot send an Apple event without this entitlement, so a build
# missing it launches, shows every session, and silently fails at Approve,
# Deny, Reply and Open in Terminal. Nothing else in the pipeline would
# notice: it signs, notarizes and staples exactly the same.
case "$ENTS" in
    *"com.apple.security.automation.apple-events"*) ;;
    *) echo "error: apple-events entitlement missing. The signed app could not drive iTerm2,"
       echo "       so approvals and inline reply would fail silently. Refusing to ship it."; exit 1 ;;
esac

echo "==> Done: $APP_DIR"
