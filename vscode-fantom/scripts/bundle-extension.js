#!/usr/bin/env node
/**
 * bundle-extension.js — Bundles the VS Code extension entry point with esbuild.
 *
 * Runs after `tsc` (which generates out/declarationRange.js etc. for tests)
 * and overwrites out/extension.js with a single self-contained bundle that
 * includes vscode-languageclient and all other npm dependencies.
 *
 * vscode is marked external because it is provided at runtime by VS Code.
 * Node built-ins are also external (platform: 'node' handles this).
 */

"use strict";

const esbuild = require("esbuild");
const path = require("path");

const isProduction = process.argv.includes("--production");

esbuild
  .build({
    entryPoints: [path.join(__dirname, "..", "src", "extension.ts")],
    bundle: true,
    outfile: path.join(__dirname, "..", "out", "extension.js"),
    external: ["vscode"],
    format: "cjs",
    platform: "node",
    target: "node18",
    sourcemap: !isProduction,
    minify: isProduction,
  })
  .then(() => {
    console.log(
      `[bundle-extension] Bundled out/extension.js (${isProduction ? "production" : "development"})`,
    );
  })
  .catch((err) => {
    console.error("[bundle-extension] Build failed:", err);
    process.exit(1);
  });
