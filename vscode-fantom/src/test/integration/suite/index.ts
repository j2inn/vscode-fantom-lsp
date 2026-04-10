/**
 * Mocha test suite runner — loaded inside the VS Code process by @vscode/test-electron.
 *
 * Exports a `run()` function that sets up Mocha, registers the test files, and
 * returns a Promise that resolves when all tests pass or rejects with the
 * failure count.
 */
import * as path from 'path';
import Mocha from 'mocha';

export function run(): Promise<void> {
  const mocha = new Mocha({
    ui: 'tdd',
    color: true,
    timeout: 15000,
  });

  mocha.addFile(path.resolve(__dirname, 'debugAdapter.test.js'));

  return new Promise<void>((resolve, reject) => {
    mocha.run(failures => {
      // Settle the promise first so @vscode/test-electron sees pass/fail.
      if (failures > 0) {
        reject(new Error(`${failures} integration test(s) failed`));
      } else {
        resolve();
      }

      // Force VS Code's extension host process to exit after a short delay.
      // Without this, long-lived extension resources (LSP client, file-watchers,
      // checkJavaAndBuildAdapterAtStartup, etc.) keep the event loop alive and
      // @vscode/test-electron hangs waiting for the VS Code process to quit.
      setTimeout(() => process.exit(failures > 0 ? 1 : 0), 500);
    });
  });
}
