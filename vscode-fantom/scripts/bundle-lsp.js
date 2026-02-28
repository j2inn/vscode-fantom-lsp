#!/usr/bin/env node
/**
 * bundle-lsp.js — Compiles the Fantom LSP pod and copies it into the extension
 * for bundling inside the VSIX package.
 *
 * Requires only the FAN_HOME environment variable.
 *
 * The script:
 *  1. Locates the fan executable via $FAN_HOME/bin/fan[.bat]
 *  2. Runs `fan src/lsp/build.fan` to compile the lsp pod
 *  3. Copies lsp.pod from $FAN_HOME/lib/fan/ to bundled-pods/
 */

"use strict";

const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const isWindows = process.platform === "win32";

const fanHome = (process.env.FAN_HOME || "").trim().replace(/[/\\]+$/, "");
if (!fanHome) {
  console.error("ERROR: FAN_HOME environment variable is not set.");
  console.error(
    "Set FAN_HOME to your Fantom installation directory (the folder containing bin/fan).",
  );
  process.exit(1);
}

// Locate fan executable inside FAN_HOME
function findFanExe(home) {
  const base = path.join(home, "bin", "fan");
  if (fs.existsSync(base)) {
    return base;
  }
  if (isWindows) {
    if (fs.existsSync(base + ".bat")) {
      return base + ".bat";
    }
    if (fs.existsSync(base + ".exe")) {
      return base + ".exe";
    }
  }
  return null;
}

const fanExe = findFanExe(fanHome);
if (!fanExe) {
  console.error(
    `ERROR: fan executable not found in ${path.join(fanHome, "bin")}`,
  );
  console.error("Check that FAN_HOME points to a valid Fantom installation.");
  process.exit(1);
}

const extensionDir = path.resolve(__dirname, "..");
const projectRoot = path.resolve(extensionDir, "..");
const bundledPodsDir = path.join(extensionDir, "bundled-pods");
const buildFan = path.join(projectRoot, "build.fan");
const lspPodSrc = path.join(fanHome, "lib", "fan", "vscodeFantomLsp.pod");

console.log(`fan executable: ${fanExe}`);
console.log(`FAN_HOME:       ${fanHome}`);
console.log(`build.fan:      ${buildFan}`);

// Step 1: Compile the vscodeFantomLsp pod
if (!fs.existsSync(buildFan)) {
  console.error(`ERROR: build.fan not found at ${buildFan}`);
  process.exit(1);
}

console.log("\nCompiling vscodeFantomLsp pod...");
try {
  execFileSync(fanExe, [buildFan], { stdio: "inherit", cwd: projectRoot });
} catch (e) {
  console.error("ERROR: Failed to compile vscodeFantomLsp pod.");
  process.exit(1);
}

// Step 2: Copy vscodeFantomLsp.pod to bundled-pods/
if (!fs.existsSync(lspPodSrc)) {
  console.error(
    `ERROR: vscodeFantomLsp.pod not found at ${lspPodSrc} after build.`,
  );
  process.exit(1);
}

fs.mkdirSync(bundledPodsDir, { recursive: true });

const lspPodDst = path.join(bundledPodsDir, "vscodeFantomLsp.pod");
fs.copyFileSync(lspPodSrc, lspPodDst);

const size = fs.statSync(lspPodDst).size;
console.log(
  `\nBundled vscodeFantomLsp.pod (${(size / 1024).toFixed(1)} KB) -> ${lspPodDst}`,
);
