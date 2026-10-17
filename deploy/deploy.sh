#!/usr/bin/env bash
# Formwerk: archive and upload to TestFlight.
#   bash deploy/deploy.sh                       # archive + upload
#   bash deploy/deploy.sh --archive-only        # archive, print its path
#   bash deploy/deploy.sh --upload "<path>"     # upload an existing archive
# Uses the Apple ID signed in to Xcode (team HC67GN5D2X). The archive goes to
# Xcode's Archives folder (shows up in the Organizer) because codesign fails
# inside this iCloud-synced Documents folder.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
MODE="${1:-all}"

BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
ARCHIVE_DIR="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
ARCHIVE_PATH="$ARCHIVE_DIR/Formwerk $BUILD_NUMBER.xcarchive"
EXPORT_PATH="$(mktemp -d)/Formwerk-export"
mkdir -p "$ARCHIVE_DIR"

upload() {
  echo "[3/3] Export + upload to App Store Connect"
  xcodebuild \
    -exportArchive \
    -archivePath "$1" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist deploy/ExportOptions.plist \
    -allowProvisioningUpdates
  echo "Uploaded. It appears in App Store Connect → Formwerk → TestFlight after processing (~10–30 min)."
}

if [ "$MODE" = "--upload" ]; then
  upload "${2:?archive path missing}"
  exit 0
fi

echo "[1/3] xcodegen generate"
xcodegen generate

echo "[2/3] Archive (Release, build $BUILD_NUMBER)"
xcodebuild \
  -project Formwerk.xcodeproj \
  -scheme Formwerk \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive

if [ "$MODE" = "--archive-only" ]; then
  echo "Archived: $ARCHIVE_PATH"
  exit 0
fi
upload "$ARCHIVE_PATH"
