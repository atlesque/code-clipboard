#!/bin/zsh
# Builds "Code Clipboard.app" and installs it to /Applications.
#   ./build.sh                    build + install + (re)launch
#   NTFY_TOKEN=tk_… ./build.sh    also hand the app an access token (moved into Keychain)
# Settings come from the environment or a .env file next to this script (see .env.example).
set -euo pipefail
cd "${0:A:h}"

[[ -f .env ]] && { set -a; source ./.env; set +a; }
BUNDLE_ID="${BUNDLE_ID:-com.example.code-clipboard}"
NTFY_TOPIC_URL="${NTFY_TOPIC_URL:-}"
# Sign with a real certificate when there is one: macOS then recognises rebuilds as the same
# app, so the Keychain doesn't ask again. Ad-hoc ("-") signing changes identity on every build.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

APP="build/Code Clipboard.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -replace NtfyTopicURL -string "$NTFY_TOPIC_URL" "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -target arm64-apple-macos13 \
  -o "$APP/Contents/MacOS/CodeClipboard" Sources/main.swift
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"

pkill -x CodeClipboard 2>/dev/null && sleep 1 || true
rm -rf "/Applications/Code Clipboard.app"
cp -R "$APP" /Applications/

if [[ -n "${NTFY_TOKEN:-}" ]]; then
  dir="$HOME/Library/Application Support/Code Clipboard"
  mkdir -p "$dir" && (umask 077; print -rn -- "$NTFY_TOKEN" > "$dir/token")
fi

open "/Applications/Code Clipboard.app"
echo "Installed and launched /Applications/Code Clipboard.app ($BUNDLE_ID, signed: $SIGN_IDENTITY)"
