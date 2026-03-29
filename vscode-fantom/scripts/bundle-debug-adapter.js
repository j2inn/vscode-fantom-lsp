#!/usr/bin/env node
/**
 * bundle-debug-adapter.js
 *
 * Verifies the pre-built debug-adapter JAR and copies the Java sources (and
 * Gson, if already downloaded) into bundled-debug/ so the extension can
 * auto-compile the JAR from those sources when it is missing at runtime.
 *
 * Run after:  bash debug-adapter/build.sh
 * Or via npm: npm run bundle-debug-adapter
 */

"use strict";

const fs   = require("fs");
const path = require("path");

const ROOT        = path.join(__dirname, "..");
const BUNDLED     = path.join(ROOT, "bundled-debug");
const JAR         = path.join(BUNDLED, "fantom-debug-adapter.jar");
const JAVA_SRC    = path.join(ROOT, "debug-adapter", "src", "main", "java");
const DEST_SRC    = path.join(BUNDLED, "java-src");
const GSON_SRC    = path.join(ROOT, "debug-adapter", "lib", "gson.jar");
const DEST_LIB    = path.join(BUNDLED, "lib");
const DEST_GSON   = path.join(DEST_LIB, "gson.jar");

// --- Verify pre-built JAR ---------------------------------------------------
if (!fs.existsSync(JAR)) {
  console.error(`[bundle-debug-adapter] JAR not found at: ${JAR}`);
  console.error("Run:  bash vscode-fantom/debug-adapter/build.sh");
  process.exit(1);
}
console.log(`[bundle-debug-adapter] JAR OK (${fs.statSync(JAR).size} bytes)`);

// --- Copy Java sources -------------------------------------------------------
if (!fs.existsSync(JAVA_SRC)) {
  console.warn(`[bundle-debug-adapter] Java sources not found at ${JAVA_SRC} — skipping source copy.`);
} else {
  copyDirSync(JAVA_SRC, DEST_SRC);
  const count = countFiles(DEST_SRC, ".java");
  console.log(`[bundle-debug-adapter] Java sources copied → bundled-debug/java-src/ (${count} files)`);
}

// --- Copy Gson JAR (if already downloaded by build.sh) ----------------------
if (fs.existsSync(GSON_SRC)) {
  fs.mkdirSync(DEST_LIB, { recursive: true });
  fs.copyFileSync(GSON_SRC, DEST_GSON);
  console.log(`[bundle-debug-adapter] Gson copied → bundled-debug/lib/gson.jar`);
} else {
  console.log(`[bundle-debug-adapter] Gson not found at ${GSON_SRC} — will be downloaded at runtime if needed.`);
}

// ---------------------------------------------------------------------------

function copyDirSync(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const srcPath  = path.join(src,  entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDirSync(srcPath, destPath);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}

function countFiles(dir, ext) {
  let n = 0;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) { n += countFiles(full, ext); }
    else if (entry.name.endsWith(ext)) { n++; }
  }
  return n;
}
