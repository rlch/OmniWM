#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM
#
# Installs a build of this fork as /Applications/OmniWM.app on this Mac, over the Homebrew cask:
# signs the app (built unsigned, in a VM with Xcode 27, by Scripts/package-app.sh's steps) with a
# Developer ID, checks the signature, takes the cask off brew's books, quits the OmniWM running,
# swaps the app, links omniwmctl and its fish completions, and opens it. Safe to run again on
# every update: each step does nothing that is already done.
#
#   Scripts/omniwm-fork-install.sh <unsigned OmniWM.app> [--check]
#
# --check signs a copy and verifies it, and stops before touching brew or the running OmniWM.
# OMNIWM_SIGNING_IDENTITY names the Developer ID (the operator's by default); `-` signs ad hoc, for a
# test of this script in a VM, and skips Gatekeeper's check, which refuses such an app.
# OMNIWM_NOTARIZE_PROFILE, a notarytool keychain profile, notarizes and staples the app first;
# without one the app is signed but not notarized, which Gatekeeper accepts for an app built here
# and never quarantined (spctl says "Unnotarized Developer ID"; the script says so and goes on).
#
# The first switch from the cask's app (signed by upstream) asks for Accessibility and Input
# Monitoring again, once: macOS keys them to the signer. Later builds signed alike keep them.
#
# A rebase that bumps settings.toml's schemaVersion migrates it on first launch: copy the migrated
# file back into dotfiles (dot_config/omniwm/.settings.toml) at once, or chezmoi reverts it until
# OmniWM's pre-migration backups fill and it stops writing its settings.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="${1:-}"
MODE="${2:-install}"
IDENTITY="${OMNIWM_SIGNING_IDENTITY:-Developer ID Application: Richard Mathieson (SJ2UMC3U38)}"
NOTARIZE_PROFILE="${OMNIWM_NOTARIZE_PROFILE:-}"
ENTITLEMENTS="$ROOT_DIR/OmniWM.entitlements"
BUNDLE_ID="com.barut.OmniWM"
TARGET="/Applications/OmniWM.app"
STATE_DIR="$HOME/.local/state/omniwm-fork"
CTL_LINK="/opt/homebrew/bin/omniwmctl"
SETTINGS="$HOME/.config/omniwm/settings.toml"

fail() {
  echo "omniwm-fork-install: $*" >&2
  exit 1
}
say() { echo "omniwm-fork-install: $*"; }

[ -n "$SOURCE_APP" ] && [ -d "$SOURCE_APP/Contents/MacOS" ] || fail "usage: $0 <unsigned OmniWM.app> [--check]"
[ "$MODE" = "install" ] || [ "$MODE" = "--check" ] || fail "unknown mode $MODE"
if [ "$IDENTITY" = "-" ]; then
  STAMP=(--timestamp=none)
else
  STAMP=(--timestamp)
  security find-identity -v -p codesigning | grep -qF "$IDENTITY" || fail "no signing identity '$IDENTITY' in the keychain"
fi
[ -f "$ENTITLEMENTS" ] || fail "no $ENTITLEMENTS"

# 1. A signed copy, staged beside the state folder: the source app is never changed.
mkdir -p "$STATE_DIR"
STAGED="$STATE_DIR/OmniWM.app"
rm -rf "$STAGED"
ditto "$SOURCE_APP" "$STAGED"
xattr -cr "$STAGED"
say "signing as $IDENTITY"
for lib in "$STAGED/Contents/Frameworks/"*.dylib; do
  [ -e "$lib" ] && codesign --force --options runtime "${STAMP[@]}" --sign "$IDENTITY" "$lib"
done
codesign --force --options runtime "${STAMP[@]}" --sign "$IDENTITY" "$STAGED/Contents/MacOS/omniwmctl"
codesign --force --options runtime "${STAMP[@]}" --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$STAGED/Contents/MacOS/OmniWM"
codesign --force --options runtime "${STAMP[@]}" --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$STAGED"

if [ -n "$NOTARIZE_PROFILE" ]; then
  say "notarizing with profile $NOTARIZE_PROFILE"
  ZIP="$STATE_DIR/OmniWM.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$STAGED" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARIZE_PROFILE" --wait --timeout "${OMNIWM_NOTARIZE_TIMEOUT:-30m}"
  xcrun stapler staple "$STAGED"
  rm -f "$ZIP"
fi

# 2. Checked before anything running is touched.
codesign --verify --deep --strict --verbose=2 "$STAGED" || fail "the signed app does not verify"
[ "$(defaults read "$STAGED/Contents/Info.plist" CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "the app is not $BUNDLE_ID"
if [ "$IDENTITY" = "-" ]; then
  say "signed ad hoc: Gatekeeper's check skipped"
elif ! assess="$(spctl --assess --type execute --verbose=2 "$STAGED" 2>&1)"; then
  if [ -z "$NOTARIZE_PROFILE" ] && grep -q "Unnotarized Developer ID" <<<"$assess"; then
    say "not notarized (no OMNIWM_NOTARIZE_PROFILE): fine for an app built and installed here"
  else
    fail "Gatekeeper refuses the app: $assess"
  fi
fi
if [ -f "$SETTINGS" ] && grep -Eq '^updateChecksEnabled *= *true' "$SETTINGS"; then
  say "warning: $SETTINGS has updateChecksEnabled = true: OmniWM's updater would install upstream's release over the fork (set it false in dotfiles)"
fi
if [ "$MODE" = "--check" ]; then
  say "checked: $STAGED is signed and verifies; nothing installed"
  exit 0
fi

# 3. Off brew's books, so no `brew upgrade` puts upstream back; the app is kept until the swap.
if command -v brew >/dev/null 2>&1 && brew list --cask omniwm >/dev/null 2>&1; then
  say "taking the omniwm cask off brew (its app stays until the swap)"
  ditto "$TARGET" "$STATE_DIR/upstream.app" 2>/dev/null || true
  brew uninstall --cask omniwm
fi

# 4. Quit, swap, open. The app it replaces is kept as previous.app.
# The app at the target alone, by its path: another build (OmniWM Dev) has the same process name.
running() { pgrep -qf "^$TARGET/Contents/MacOS/OmniWM"; }
if running; then
  say "quitting OmniWM"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do running || break; sleep 0.1; done
  # No Automation grant for this terminal (or a dialog up): asked to end, as a logout does.
  if running; then
    say "OmniWM did not quit when asked; ending it"
    kill -TERM $(pgrep -f "^$TARGET/Contents/MacOS/OmniWM") 2>/dev/null || true
    for _ in $(seq 1 50); do running || break; sleep 0.1; done
  fi
  running && fail "OmniWM did not quit"
fi
if [ -d "$TARGET" ]; then
  rm -rf "$STATE_DIR/previous.app"
  mv "$TARGET" "$STATE_DIR/previous.app"
fi
ditto "$STAGED" "$TARGET"

# 5. omniwmctl on the PATH and its completions, as the cask gave them.
ln -sf "$TARGET/Contents/MacOS/omniwmctl" "$CTL_LINK"
mkdir -p "$HOME/.config/fish/completions"
"$CTL_LINK" completion fish > "$HOME/.config/fish/completions/omniwmctl.fish" || say "warning: omniwmctl completion fish failed"

open "$TARGET"
say "installed $(defaults read "$TARGET/Contents/Info.plist" OMNIWMGitHash 2>/dev/null || echo '?'); the previous app is $STATE_DIR/previous.app"
say "first switch from the cask: grant Accessibility and Input Monitoring to OmniWM again when asked"
