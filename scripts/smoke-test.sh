#!/bin/bash
# Smoke test: build the app, pipe initialize + tools/list to its stdio, and
# verify the responses. Does NOT require Calendar/Contacts TCC — initialize
# and tools/list don't touch EventKit.
#
# Usage:
#   scripts/smoke-test.sh
#
# Exit codes:
#   0  — all assertions passed
#   1  — build or runtime failure
#   2  — assertion failure (response missing fields, wrong tool count, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED="/tmp/kairos-derived"
APP_NAME="ES_Kairos.app"
BIN_NAME="ES_Kairos"

cd "$PROJECT_ROOT"

if ! command -v jq >/dev/null 2>&1; then
    echo "smoke-test: jq is required (brew install jq)" >&2
    exit 1
fi

echo "smoke-test: building $APP_NAME (DerivedData=$DERIVED)..."
xcodebuild \
    -project "ES Kairos.xcodeproj" \
    -scheme "ES Kairos" \
    -configuration Debug \
    -derivedDataPath "$DERIVED" \
    build \
    >/tmp/kairos-build.log 2>&1 || {
    echo "smoke-test: build failed — see /tmp/kairos-build.log" >&2
    tail -40 /tmp/kairos-build.log >&2
    exit 1
}

BIN="$DERIVED/Build/Products/Debug/$APP_NAME/Contents/MacOS/$BIN_NAME"
if [ ! -x "$BIN" ]; then
    echo "smoke-test: binary not found at $BIN" >&2
    ls "$DERIVED/Build/Products/Debug/" >&2 || true
    exit 1
fi
echo "smoke-test: binary at $BIN"

# Send three messages (initialize, initialized notification, tools/list)
# then sleep 3 to keep stdin open while the server replies — see README §10.8.
OUTPUT=$({
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 3
} | "$BIN" 2>/tmp/kairos.err)

echo "smoke-test: raw output:"
echo "$OUTPUT" | sed 's/^/  /'
echo "smoke-test: stderr from binary:"
sed 's/^/  /' /tmp/kairos.err

# Parse each line as JSON; collect by id.
INIT=$(echo "$OUTPUT" | jq -c 'select(.id==1)' | head -n1)
LIST=$(echo "$OUTPUT" | jq -c 'select(.id==2)' | head -n1)

if [ -z "$INIT" ]; then
    echo "smoke-test: FAIL — no response to initialize" >&2
    exit 2
fi
if [ -z "$LIST" ]; then
    echo "smoke-test: FAIL — no response to tools/list" >&2
    exit 2
fi

PROTO=$(echo "$INIT" | jq -r '.result.protocolVersion // empty')
NAME=$(echo "$INIT"  | jq -r '.result.serverInfo.name // empty')
if [ "$PROTO" != "2024-11-05" ]; then
    echo "smoke-test: FAIL — protocolVersion '$PROTO' (expected 2024-11-05)" >&2
    exit 2
fi
if [ "$NAME" != "kairos" ]; then
    echo "smoke-test: FAIL — serverInfo.name '$NAME' (expected kairos)" >&2
    exit 2
fi

# Derive the expected tool set directly from the toolDefinitions array in
# MCPServer.m so this check never goes stale as tools are added or removed.
# Each tool is declared there as:  @{ @"name": @"<tool_name>",
SRC="$PROJECT_ROOT/ES Kairos/MCPServer.m"
EXPECTED_NAMES=$(grep -oE '@\{ @"name": @"[a-z_]+"' "$SRC" \
    | sed -E 's/.*@"([a-z_]+)"$/\1/' | sort || true)
EXPECTED_COUNT=$(printf '%s\n' "$EXPECTED_NAMES" | grep -c . || true)

if [ "${EXPECTED_COUNT:-0}" -eq 0 ]; then
    echo "smoke-test: FAIL — could not parse tool names from $SRC" >&2
    exit 2
fi

COUNT=$(echo "$LIST" | jq -r '.result.tools | length')
if [ "$COUNT" != "$EXPECTED_COUNT" ]; then
    echo "smoke-test: FAIL — tools/list returned $COUNT tools (expected $EXPECTED_COUNT from MCPServer.m)" >&2
    echo "$LIST" | jq '.result.tools | map(.name)' >&2
    exit 2
fi

# The advertised set must exactly match what MCPServer.m declares
# (catches renamed, dropped, or typo'd tools in either direction).
NAMES=$(echo "$LIST" | jq -r '.result.tools[].name' | sort)
if [ "$NAMES" != "$EXPECTED_NAMES" ]; then
    echo "smoke-test: FAIL — advertised tools differ from MCPServer.m declarations" >&2
    echo "  declared:"   >&2; printf '%s\n' "$EXPECTED_NAMES" | sed 's/^/    /' >&2
    echo "  advertised:" >&2; printf '%s\n' "$NAMES"          | sed 's/^/    /' >&2
    exit 2
fi

echo "smoke-test: OK — protocolVersion=$PROTO serverInfo.name=$NAME tools=$COUNT"
