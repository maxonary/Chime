#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift_compiler="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
mac_sdk="$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
watch_sdk="$developer_dir/Platforms/WatchSimulator.platform/Developer/SDKs/WatchSimulator.sdk"

if [[ ! -x "$swift_compiler" || ! -d "$watch_sdk" ]]; then
  echo "Xcode with the watchOS SDK is required. Set DEVELOPER_DIR to your Xcode Contents/Developer directory." >&2
  exit 1
fi

check_dir="$(mktemp -d "${TMPDIR:-/tmp}/chime-watch-checks.XXXXXX")"
trap 'rm -f "$check_dir/audio-tests" "$check_dir/store-tests" "$check_dir/watch.o"; rmdir "$check_dir"' EXIT
cd "$repo_root"

"$swift_compiler" -sdk "$mac_sdk" \
  "chime Watch App/Managers/LiveAudioCodec.swift" \
  watch/tests/AudioCodecTests.swift -o "$check_dir/audio-tests"
"$check_dir/audio-tests"

"$swift_compiler" -sdk "$mac_sdk" \
  "chime Watch App/Models/AppSettings.swift" \
  "chime Watch App/Models/Message.swift" \
  "chime Watch App/Managers/ConversationStore.swift" \
  watch/tests/ConversationStoreTests.swift -o "$check_dir/store-tests"
"$check_dir/store-tests"

# Compile the actual Watch sources to an object file. This checks code generation
# as well as types; it does not replace an Xcode bundle build or a device run.
"$swift_compiler" -emit-object -whole-module-optimization \
  -target arm64-apple-watchos26.5-simulator -sdk "$watch_sdk" \
  -module-name Chime -swift-version 5 -default-isolation MainActor \
  -strict-concurrency=complete \
  "chime Watch App/"*.swift \
  "chime Watch App/Managers/"*.swift \
  "chime Watch App/Models/"*.swift \
  "chime Watch App/Views/"*.swift \
  -o "$check_dir/watch.o"
echo "PASS: Watch source compilation with strict concurrency checks"
