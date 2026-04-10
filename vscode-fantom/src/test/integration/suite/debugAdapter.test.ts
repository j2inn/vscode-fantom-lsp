/**
 * Integration tests for the Fantom debug adapter.
 *
 * These tests run inside a VS Code instance (spawned by @vscode/test-electron)
 * and verify:
 *   1. The extension activates successfully.
 *   2. Java is detectable via the platform resolution logic.
 *   3. The debug adapter JAR is present (built before the test run).
 *   4. The JAR can be launched — the Java process stays alive, confirming
 *      the DAP server starts correctly on both Linux and Windows.
 */
import * as assert from 'assert';
import * as cp from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import { getPlatform } from '../../../platform';
import { resolveJavaCmd, isJavaAvailable } from '../../../javaSetup';

const EXT_ID = 'AndreaGiusti.fantom-language-server';

suite('Fantom debug adapter', () => {
  // ---------------------------------------------------------------------------
  // Extension activation
  // ---------------------------------------------------------------------------

  suite('Extension', () => {
    test('extension is present in VS Code', () => {
      const ext = vscode.extensions.getExtension(EXT_ID);
      assert.ok(ext, `Extension "${EXT_ID}" not found. Check publisher/name in package.json.`);
    });

    test('extension activates without errors', async () => {
      const ext = vscode.extensions.getExtension(EXT_ID);
      if (ext && !ext.isActive) {
        await ext.activate();
      }
      assert.ok(ext?.isActive, 'Extension did not become active');
    });
  });

  // ---------------------------------------------------------------------------
  // Java availability (platform-specific path resolution)
  // ---------------------------------------------------------------------------

  suite('Java', () => {
    test('java executable resolves correctly for current platform', () => {
      const platform = getPlatform();
      const javaCmd = resolveJavaCmd(platform);
      assert.ok(javaCmd.length > 0, 'resolveJavaCmd returned an empty string');
      // On Windows the resolved name must reference the .exe executable.
      if (process.platform === 'win32') {
        assert.ok(
          javaCmd.toLowerCase().endsWith('.exe') || javaCmd === 'java.exe',
          `Expected a .exe path on Windows, got: ${javaCmd}`
        );
      }
    });

    test('java is available and runnable', async function () {
      const platform = getPlatform();
      const javaCmd = resolveJavaCmd(platform);
      const available = await isJavaAvailable(javaCmd);
      assert.ok(
        available,
        `Java is not runnable at "${javaCmd}". ` +
        'Ensure JAVA_HOME is set or java is on PATH.'
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Debug adapter JAR
  // ---------------------------------------------------------------------------

  suite('Debug adapter JAR', () => {
    function getJarPath(): string {
      const ext = vscode.extensions.getExtension(EXT_ID);
      assert.ok(ext, `Extension "${EXT_ID}" not found`);
      return path.join(ext.extensionUri.fsPath, 'bundled-debug', 'fantom-debug-adapter.jar');
    }

    test('JAR file exists on disk', () => {
      const jar = getJarPath();
      assert.ok(
        fs.existsSync(jar),
        `Debug adapter JAR not found at: ${jar}\n` +
        'Run "bash debug-adapter/build.sh" (Linux/macOS) or the equivalent on Windows first.'
      );
    });

    test('JAR can be launched (DAP server stays alive)', async function () {
      // Allow extra time: JVM startup can be slow on CI runners.
      // (Mocha `this` is available because we use `function`, not an arrow.)
      // eslint-disable-next-line @typescript-eslint/no-invalid-this
      this.timeout(15000);

      const jar = getJarPath();
      if (!fs.existsSync(jar)) {
        // Skip rather than fail if the JAR was not built — the previous test
        // already reports the missing-file failure.
        // eslint-disable-next-line @typescript-eslint/no-invalid-this
        this.skip();
        return;
      }

      const platform = getPlatform();
      const javaCmd = resolveJavaCmd(platform);

      await new Promise<void>((resolve, reject) => {
        let settled = false;
        const settle = (action: () => void): void => {
          if (!settled) {
            settled = true;
            action();
          }
        };

        const child = cp.spawn(
          javaCmd,
          ['--add-modules', 'jdk.jdi', '-jar', jar],
          {
            // Provide no stdin — a real DAP client would write to it.
            // The server must stay alive waiting for the first DAP message.
            stdio: ['ignore', 'ignore', 'pipe'],
            shell: false,
          }
        );

        let stderr = '';
        child.stderr?.on('data', (chunk: Buffer) => { stderr += chunk.toString(); });

        // If the process is still running after 3 seconds the DAP server
        // started successfully and is waiting for input → pass.
        const timer = setTimeout(() => {
          child.kill();
          settle(resolve);
        }, 3000);

        child.on('error', err => {
          clearTimeout(timer);
          settle(() => reject(new Error(
            `Failed to spawn debug adapter JAR: ${err.message}`
          )));
        });

        child.on('close', code => {
          clearTimeout(timer);
          // Only reach here if the process exited BEFORE the timer fired
          // (i.e., the server crashed before receiving any input).
          settle(() => reject(new Error(
            `Debug adapter exited prematurely (exit code ${code ?? 'null'}).\n` +
            (stderr ? `stderr:\n${stderr}` : '(no stderr output)')
          )));
        });
      });
    });
  });
});
