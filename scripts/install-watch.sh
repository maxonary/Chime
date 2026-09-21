#!/bin/bash
# Personal-device installation: credentials stay in ignored local files.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
watch_device="${1:?Usage: install-watch.sh DEVICE_ID [--fresh]}"
mkdir -p .context
xcodebuild -project chime.xcodeproj -scheme 'chime Watch App' -configuration Debug \
  -destination "platform=watchOS,id=$watch_device" -derivedDataPath .context/DeviceDerivedData \
  -allowProvisioningUpdates build > .context/watch-install-build.log 2>&1 || {
  tail -n 30 .context/watch-install-build.log >&2
  exit 1
}
xcrun devicectl device install app --device "$watch_device" \
  '.context/DeviceDerivedData/Build/Products/Debug-watchos/chime Watch App.app' --timeout 60
python3 scripts/provision-watch.py "$@"
xcrun devicectl device process launch --device "$watch_device" --terminate-existing maxonary.chime.watchkitapp --timeout 30
