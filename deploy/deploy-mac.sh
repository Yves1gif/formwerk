#!/usr/bin/env bash
# Formwerk for Mac: archive and upload to App Store Connect (same Apple ID/team as the iPad build).
#   bash deploy/deploy-mac.sh                    # archive + upload
#   bash deploy/deploy-mac.sh --upload "<path>"  # upload an existing archive
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
ARCHIVE_DIR="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
ARCHIVE_PATH="$ARCHIVE_DIR/Formwerk-mac $BUILD_NUMBER.xcarchive"
EXPORT_PATH="$(mktemp -d)/Formwerk-mac-export"
mkdir -p "$ARCHIVE_DIR"
upload() {
  echo "[2/2] Export + upload to App Store Connect"
  xcodebuild -exportArchive -archivePath "$1" -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist deploy/ExportOptions.plist -allowProvisioningUpdates
  echo "Uploaded."
}
if [ "${1:-}" = "--upload" ]; then upload "${2:?archive path missing}"; exit 0; fi
xcodegen generate
echo "[1/2] Archive macOS (Release, build $BUILD_NUMBER)"
xcodebuild -project Formwerk.xcodeproj -scheme Formwerk -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive
upload "$ARCHIVE_PATH"
