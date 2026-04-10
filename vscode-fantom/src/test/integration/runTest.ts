/**
 * Integration test entry point.
 *
 * This script is compiled to out/test/integration/runTest.js and run with
 * plain Node.js (outside VS Code).  It downloads a VS Code instance, opens
 * the test workspace, and runs the Mocha suite defined in ./suite/index.ts.
 *
 * Usage (after `pnpm run compile`):
 *   node out/test/integration/runTest.js
 */
import * as path from 'path';
import { runTests } from '@vscode/test-electron';

async function main(): Promise<void> {
  // Root of the extension being tested (the vscode-fantom/ directory).
  const extensionDevelopmentPath = path.resolve(__dirname, '../../..');

  // Compiled Mocha suite entry point (loaded inside the VS Code process).
  const extensionTestsPath = path.resolve(__dirname, './suite/index');

  // Minimal workspace that triggers extension activation via workspaceContains:build.fan.
  const testWorkspacePath = path.resolve(__dirname, '../../../test/integration/workspace');

  await runTests({
    extensionDevelopmentPath,
    extensionTestsPath,
    launchArgs: [
      testWorkspacePath,
      '--headless',                // skip the renderer process entirely; without this, VS
                                   // Code's Electron/Chromium renderer fails to initialise
                                   // on CI runners (no D-Bus, no GPU) and never sends the
                                   // IPC message that triggers the Mocha test runner, even
                                   // though the Node.js extension host starts fine
      '--disable-gpu',             // belt-and-suspenders: suppress any GPU init attempts
      '--disable-workspace-trust', // skips the trust dialog that would block activation
      '--no-sandbox',              // avoids Chromium sandbox failures on Linux CI runners
    ],
  });
}

main().catch(err => {
  console.error('Integration test runner failed:', err);
  process.exit(1);
});
