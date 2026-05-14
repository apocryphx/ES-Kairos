#!/bin/sh
# Package a built ES_Kairos.app into ES_Kairos.mcpb for drag-into-Claude-Desktop.
#
# This is a standalone release step — it does NOT run as an Xcode build phase.
# Build/Archive the app first; this script then copies the already-signed .app
# into bundle/server/ and runs `mcpb pack`.
#
# Usage:
#   scripts/package-mcpb.sh                       # auto-find latest .app
#   scripts/package-mcpb.sh /path/to/ES_Kairos.app  # explicit path
#
# Discovery order when no path is given:
#   1. Most recent .xcarchive under ~/Library/Developer/Xcode/Archives
#   2. /tmp/kairos-derived Release products
#   3. /tmp/kairos-derived Debug products
#   4. Default DerivedData Release products
#   5. Default DerivedData Debug products

set -eu

PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.volta/bin:$PATH"
if [ -d "$HOME/.nvm/versions/node" ]; then
    for d in "$HOME/.nvm/versions/node"/*/bin; do
        [ -d "$d" ] && PATH="$d:$PATH"
    done
fi
export PATH

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BUNDLE_DIR="$PROJECT_ROOT/bundle"
SERVER_DIR="$BUNDLE_DIR/server"
APP_NAME="ES_Kairos.app"
OUT_MCPB="$PROJECT_ROOT/ES_Kairos.mcpb"

# A DEDICATED clean DerivedData path used ONLY for release packaging.
# DO NOT share with /tmp/kairos-derived — that path is used by
# scripts/smoke-test.sh and by `xcodebuild test`, which injects
# XCTest/XCUnit frameworks into the .app and breaks the codesign seal.
# A polluted bundle gets silently rejected by TCC (no auth prompts),
# which is exactly the bug that motivated this separation.
RELEASE_DERIVED="/tmp/kairos-release-derived"

APP_PATH="${1:-}"

if [ -z "$APP_PATH" ]; then
    echo "package-mcpb.sh: doing a clean release build into $RELEASE_DERIVED"
    rm -rf "$RELEASE_DERIVED"
    cd "$PROJECT_ROOT"
    xcodebuild \
        -project "ES Kairos.xcodeproj" \
        -scheme "ES Kairos" \
        -configuration Release \
        -derivedDataPath "$RELEASE_DERIVED" \
        clean build \
        >/tmp/kairos-release-build.log 2>&1 || {
        echo "package-mcpb.sh: release build failed — see /tmp/kairos-release-build.log" >&2
        tail -40 /tmp/kairos-release-build.log >&2
        exit 1
    }
    APP_PATH="$RELEASE_DERIVED/Build/Products/Release/$APP_NAME"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "package-mcpb.sh: $APP_PATH not found after build" >&2
    exit 1
fi

# Sanity-guard against the test-pollution failure mode we just hit.
if [ -d "$APP_PATH/Contents/Frameworks/XCTest.framework" ] || \
   [ -d "$APP_PATH/Contents/Frameworks/XCUnit.framework" ]  || \
   [ -d "$APP_PATH/Contents/PlugIns" ]; then
    echo "package-mcpb.sh: REFUSING — $APP_PATH contains XCTest/XCUnit or PlugIns." >&2
    echo "  This .app was contaminated by 'xcodebuild test'. TCC will silently" >&2
    echo "  refuse to attribute permissions to it (no Contacts/Calendar prompts)." >&2
    echo "  Build with 'xcodebuild ... clean build' (no 'test') and retry." >&2
    exit 1
fi

echo "package-mcpb.sh: using $APP_PATH"

# --- check signature ------------------------------------------------------

if codesign -v --strict "$APP_PATH" 2>/dev/null; then
    SIG=$(codesign -dvv "$APP_PATH" 2>&1 | awk -F= '/^Authority/ {print $2; exit}')
    [ -z "$SIG" ] && SIG="ad-hoc"
    echo "package-mcpb.sh: signed by: $SIG"
else
    echo "package-mcpb.sh: WARNING — .app fails strict signature check." >&2
    echo "  The .mcpb will still be packed, but Claude Desktop may refuse" >&2
    echo "  to launch a tampered binary. To re-sign ad-hoc:" >&2
    echo "    codesign --force --deep --sign - '$APP_PATH'" >&2
fi

# --- stage ----------------------------------------------------------------

echo "package-mcpb.sh: staging -> $SERVER_DIR/$APP_NAME"
rm -rf "$SERVER_DIR"
mkdir -p "$SERVER_DIR"
ditto "$APP_PATH" "$SERVER_DIR/$APP_NAME"

# --- pack -----------------------------------------------------------------

# Strip Finder/iCloud xattrs that would corrupt the zip.
xattr -cr "$SERVER_DIR" 2>/dev/null || true

if ! command -v npx >/dev/null 2>&1; then
    echo "package-mcpb.sh: npx not on PATH (PATH=$PATH); install Node first" >&2
    exit 1
fi

echo "package-mcpb.sh: running mcpb pack (npx=$(command -v npx))"
cd "$BUNDLE_DIR"
npx --yes @anthropic-ai/mcpb pack . "$OUT_MCPB"

echo "package-mcpb.sh: produced $OUT_MCPB"
ls -lh "$OUT_MCPB"

# --- verify the in-archive signature --------------------------------------

VERIFY_DIR=$(mktemp -d -t es-kairos-verify)
trap 'rm -rf "$VERIFY_DIR"' EXIT
unzip -q "$OUT_MCPB" -d "$VERIFY_DIR"
if codesign -v --strict "$VERIFY_DIR/server/$APP_NAME" 2>/dev/null; then
    AUTH=$(codesign -dvv "$VERIFY_DIR/server/$APP_NAME" 2>&1 \
        | awk -F= '/^Authority/ {print $2; exit}')
    [ -z "$AUTH" ] && AUTH="ad-hoc"
    echo "package-mcpb.sh: in-archive signature OK ($AUTH)"
else
    echo "package-mcpb.sh: WARNING — in-archive signature does NOT verify." >&2
fi
