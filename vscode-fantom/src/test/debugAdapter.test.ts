/**
 * Debug-adapter integration tests.
 *
 * Verifies that the platform abstraction returns correct values, that Java is
 * available, that the debug adapter JAR is present, and that the JAR can
 * actually be launched (the DAP server process stays alive).
 *
 * No VS Code dependency — runs with plain Node.js after TypeScript compilation:
 *   node out/test/debugAdapter.test.js
 */
import * as assert from 'assert';
import * as cp    from 'child_process';
import * as fs    from 'fs';
import * as path  from 'path';
import { LinuxPlatform }   from '../platform/linuxPlatform';
import { WindowsPlatform } from '../platform/windowsPlatform';
import type { Platform }   from '../platform';

// ---------------------------------------------------------------------------
// Minimal test helpers (same pattern as declarationRange.test.ts)
// ---------------------------------------------------------------------------

let passed = 0;
let failed = 0;

async function test(name: string, fn: () => void | Promise<void>): Promise<void> {
  try {
    await fn();
    console.log(`  ✓ ${name}`);
    passed++;
  } catch (e: any) {
    console.error(`  ✗ ${name}`);
    console.error(`    ${e.message}`);
    failed++;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Extension root: vscode-fantom/ — two levels up from out/test/
const EXTENSION_ROOT = path.resolve(__dirname, '../..');
const JAR_PATH = path.join(EXTENSION_ROOT, 'bundled-debug', 'fantom-debug-adapter.jar');

/** Recursively collect all .java files under a directory. */
function collectJavaFilesSync(dir: string): string[] {
  const result: string[] = [];
  function walk(d: string): void {
    for (const entry of fs.readdirSync(d, { withFileTypes: true })) {
      const full = path.join(d, entry.name);
      if (entry.isDirectory()) { walk(full); }
      else if (entry.name.endsWith('.java')) { result.push(full); }
    }
  }
  walk(dir);
  return result;
}

function getPlatform(): Platform {
  return process.platform === 'win32' ? new WindowsPlatform() : new LinuxPlatform();
}

/**
 * Resolve the java executable without depending on VS Code settings.
 * Priority: JAVA_HOME env var → bare name on PATH.
 */
function resolveJava(platform: Platform): string {
  const javaHome = process.env.JAVA_HOME;
  if (javaHome) {
    return path.join(javaHome, 'bin', platform.javaExeName);
  }
  return platform.javaExeName;
}

function isJavaAvailable(javaCmd: string): Promise<boolean> {
  return new Promise(resolve => {
    const child = cp.spawn(javaCmd, ['-version'], { stdio: 'ignore', shell: false });
    child.on('error', () => resolve(false));
    child.on('close', code => resolve(code === 0));
  });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const platform = getPlatform();
  const javaCmd  = resolveJava(platform);

  console.log('\nDebug adapter tests:');

  // ── Platform abstraction ──────────────────────────────────────────────────

  await test('platform returns correct exe names for current OS', () => {
    if (process.platform === 'win32') {
      assert.strictEqual(platform.javaExeName,       'java.exe');
      assert.strictEqual(platform.javacExeName,      'javac.exe');
      assert.strictEqual(platform.jarExeName,        'jar.exe');
      assert.strictEqual(platform.classpathSeparator, ';');
    } else {
      assert.strictEqual(platform.javaExeName,       'java');
      assert.strictEqual(platform.javacExeName,      'javac');
      assert.strictEqual(platform.jarExeName,        'jar');
      assert.strictEqual(platform.classpathSeparator, ':');
    }
  });

  // ── Java availability ─────────────────────────────────────────────────────

  await test('java executable is runnable', async () => {
    const available = await isJavaAvailable(javaCmd);
    assert.ok(
      available,
      `java is not runnable at "${javaCmd}". ` +
      'Set JAVA_HOME or ensure java is on PATH.'
    );
  });

  // ── Bundled Java sources ──────────────────────────────────────────────────

  const JAVA_SRC_DIR = path.join(EXTENSION_ROOT, 'bundled-debug', 'java-src');

  await test('bundled-debug/java-src/ directory exists', () => {
    assert.ok(
      fs.existsSync(JAVA_SRC_DIR),
      `Java source directory not found at: ${JAVA_SRC_DIR}\n` +
      'Run "pnpm run bundle-debug-adapter" (requires JAR to be built first).'
    );
  });

  await test('bundled-debug/java-src/ contains .java files', () => {
    if (!fs.existsSync(JAVA_SRC_DIR)) {
      // Skip — the previous test already reports the missing-directory failure.
      return;
    }
    const javaFiles = collectJavaFilesSync(JAVA_SRC_DIR);
    assert.ok(
      javaFiles.length > 0,
      `No .java files found under: ${JAVA_SRC_DIR}`
    );
  });

  // ── Debug adapter JAR ─────────────────────────────────────────────────────

  await test('debug adapter JAR exists on disk', () => {
    assert.ok(
      fs.existsSync(JAR_PATH),
      `JAR not found at: ${JAR_PATH}\n` +
      'Run "bash debug-adapter/build.sh" first.'
    );
  });

  await test('debug adapter JAR can be launched (DAP server stays alive)', async () => {
    if (!fs.existsSync(JAR_PATH)) {
      // Skip — the previous test already reports the missing-file failure.
      return;
    }

    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const settle = (action: () => void): void => {
        if (!settled) { settled = true; action(); }
      };

      // Keep stdin open as a pipe (don't write or close it).
      // The DAP server blocks reading from stdin; if stdin is closed (ignore →
      // /dev/null) it exits immediately with code 0. With a live pipe it must
      // stay alive waiting for the first DAP message.
      const child = cp.spawn(
        javaCmd,
        ['--add-modules', 'jdk.jdi', '-jar', JAR_PATH],
        { stdio: ['pipe', 'ignore', 'pipe'], shell: false }
      );

      let stderr = '';
      child.stderr?.on('data', (d: Buffer) => { stderr += d.toString(); });

      // Still alive after 3 s → DAP server started successfully.
      const timer = setTimeout(() => {
        child.kill();
        settle(resolve);
      }, 3000);

      child.on('error', err => {
        clearTimeout(timer);
        settle(() => reject(new Error(`Failed to spawn JAR: ${err.message}`)));
      });

      child.on('close', code => {
        clearTimeout(timer);
        // Reached only if the process exited BEFORE the timer fired.
        settle(() => reject(new Error(
          `Debug adapter exited prematurely (code ${code ?? 'null'}).\n` +
          (stderr ? `stderr:\n${stderr}` : '(no stderr)')
        )));
      });
    });
  });

  // ── Summary ───────────────────────────────────────────────────────────────

  console.log(`\n${passed} passed, ${failed} failed`);
  if (failed > 0) { process.exit(1); }
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
