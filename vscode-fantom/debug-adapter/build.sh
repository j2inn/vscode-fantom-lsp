#!/usr/bin/env bash
# build.sh — Build the Fantom debug adapter JAR (no Maven required)
# Usage: bash vscode-fantom/debug-adapter/build.sh   (from workspace root)
#   or:  ./build.sh                                   (from debug-adapter/)
# Output: vscode-fantom/bundled-debug/fantom-debug-adapter.jar

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$SCRIPT_DIR"
DEST="$SCRIPT_DIR/../bundled-debug"
SRC="$WORK/src/main/java"
LIB="$WORK/lib"
CLASSES="$WORK/classes"

mkdir -p "$LIB" "$CLASSES" "$DEST"

# ── Download Gson if not present ──────────────────────────────────────────────
GSON_JAR="$LIB/gson.jar"
GSON_URL="https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar"

if [ ! -f "$GSON_JAR" ]; then
  echo "[build] Downloading Gson..."
  if command -v curl &>/dev/null; then
    curl -s -L "$GSON_URL" -o "$GSON_JAR"
  elif command -v wget &>/dev/null; then
    wget -q "$GSON_URL" -O "$GSON_JAR"
  else
    echo "[build] ERROR: neither curl nor wget found."
    echo "  Download manually: $GSON_URL  →  $GSON_JAR"
    exit 1
  fi
  echo "[build] Gson downloaded ($(wc -c < "$GSON_JAR") bytes)"
fi

# ── Compile ───────────────────────────────────────────────────────────────────
echo "[build] Compiling Java sources..."
rm -rf "$CLASSES"
mkdir -p "$CLASSES"

javac --add-modules jdk.jdi \
  -cp "$GSON_JAR" \
  -d "$CLASSES" \
  "$SRC/fan/lsp/debug/Main.java" \
  "$SRC/fan/lsp/debug/DapServer.java" \
  "$SRC/fan/lsp/debug/FantomDebugSession.java" \
  "$SRC/fan/lsp/debug/SourceMapper.java"

# ── Package fat JAR ───────────────────────────────────────────────────────────
echo "[build] Packaging fat JAR..."

cd "$CLASSES"
jar xf "$GSON_JAR"
rm -rf META-INF

MANIFEST="$(mktemp)"
printf 'Manifest-Version: 1.0\nMain-Class: fan.lsp.debug.Main\n\n' > "$MANIFEST"

OUT="$DEST/fantom-debug-adapter.jar"
jar cfm "$OUT" "$MANIFEST" -C "$CLASSES" .
rm "$MANIFEST"

SIZE=$(wc -c < "$OUT")
echo "[build] Done: bundled-debug/fantom-debug-adapter.jar (${SIZE} bytes)"
