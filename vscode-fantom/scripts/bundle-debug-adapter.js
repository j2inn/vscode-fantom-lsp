#!/usr/bin/env node
/**
 * bundle-debug-adapter.js
 *
 * Copies the built debug-adapter JAR into bundled-debug/.
 * Run after:  bash debug-adapter/build.sh
 * Or via npm: npm run bundle-debug-adapter
 */

"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const SRC = path.join(ROOT, "bundled-debug", "fantom-debug-adapter.jar");
const DEST_DIR = path.join(ROOT, "bundled-debug");

// The build.sh already places the jar in bundled-debug/ — just verify it.
if (!fs.existsSync(SRC)) {
  console.error(`[bundle-debug-adapter] JAR not found at: ${SRC}`);
  console.error("Run:  bash vscode-fantom/debug-adapter/build.sh");
  process.exit(1);
}

fs.mkdirSync(DEST_DIR, { recursive: true });
const size = fs.statSync(SRC).size;
console.log(
  `[bundle-debug-adapter] OK: fantom-debug-adapter.jar (${size} bytes)`,
);
