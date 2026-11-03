#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM
#
# Builds this fork as dist/OmniWM.app, unsigned, by Scripts/package-app.sh's steps without its
# release checks, signing or notarizing: for a Mac with Xcode 27 and the toolchain of
# .swift-version (a tart VM of ghcr.io/cirruslabs/macos-tahoe-xcode:27.2 while the host lacks
# them). Then copy the app to the host and run Scripts/omniwm-fork-install.sh there.
#
# Once per machine: swiftly with `swiftly install` (Scripts/swift-toolchain.sh), GhosttyKit
# unpacked by Scripts/ghostty-preflight.sh's URL into Frameworks/, and a Python 3.11+ (tomllib)
# as PYTHON for localization.py.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export PATH="$HOME/.swiftly/bin:$PATH"
PYTHON="${PYTHON:-python3}"
LIB="$(Scripts/ghostty-preflight.sh print-library-dir)"
ARGS=(-c release --arch arm64)
LIBRARY_PATH="$LIB" swift build "${ARGS[@]}"
BIN="$(LIBRARY_PATH="$LIB" swift build "${ARGS[@]}" --show-bin-path)"
APP=dist/OmniWM.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses" "$APP/Contents/Frameworks"
cp "$BIN/OmniWM" "$BIN/omniwmctl" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/Info.plist"
plutil -replace OMNIWMGitHash -string "$(git rev-parse --short HEAD 2>/dev/null || echo SNAPSHOT)" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Sources/OmniWMLuau/LICENSE.txt "$APP/Contents/Resources/Licenses/Luau-LICENSE.txt"
cp Sources/OmniWMLuau/lua_LICENSE.txt "$APP/Contents/Resources/Licenses/Lua-LICENSE.txt"
cp Resources/Licenses/*.txt "$APP/Contents/Resources/Licenses/"
cp -R "$BIN/OmniWM_OmniWM.bundle" "$APP/Contents/Resources/"
cp "$BIN/libOmniWMNowPlaying.dylib" "$APP/Contents/Frameworks/"
"$PYTHON" Scripts/localization.py package --bundle "$BIN/OmniWM_OmniWM.bundle" --app "$APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# The snapshot toolchain can call into Swift runtime entry points the oldest macOS the app supports
# lacks; dyld then stops the app at launch. Known one: a task's isCancelled.
if nm -u "$APP/Contents/MacOS/OmniWM" | grep -q "_swift_task_isCancelledWithFlags"; then
  echo "omniwm-fork-build: the binary needs swift_task_isCancelledWithFlags, which macOS 26 lacks" >&2
  exit 1
fi
echo "built $APP"
