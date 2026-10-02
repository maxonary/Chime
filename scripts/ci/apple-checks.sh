#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Match the compiler used for distribution; do not silently fall back to an older SDK.
xcodebuild -version | head -1 | grep -E '^Xcode 27\.'
./scripts/check-watch.sh
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/chime-apple-ci.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
xcodebuild -project chime.xcodeproj -scheme Chime -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$check_dir/iphone" \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project chime.xcodeproj -scheme 'chime Watch App' -configuration Debug \
  -destination 'generic/platform=watchOS Simulator' -derivedDataPath "$check_dir/watch" \
  CODE_SIGNING_ALLOWED=NO build
# Exercise the actual Release archive graph (iPhone embeds Watch and widgets),
# without identities, provisioning updates, devices, Apple accounts or secrets.
xcodebuild -project chime.xcodeproj -scheme Chime -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$check_dir/release" \
  -archivePath "$check_dir/Chime.xcarchive" CODE_SIGNING_ALLOWED=NO archive
python3 scripts/ci/release.py verify-archive "$check_dir/Chime.xcarchive"
