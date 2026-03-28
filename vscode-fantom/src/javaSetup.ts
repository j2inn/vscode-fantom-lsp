/**
 * javaSetup — Java detection, user prompting, and debug-adapter JAR compilation.
 *
 * This module handles all aspects of Java management for the Fantom extension:
 *   - Resolving the java executable from settings / JAVA_HOME / PATH
 *   - Verifying that java is actually runnable
 *   - Prompting the user to configure Java when it cannot be found
 *   - Auto-compiling the debug-adapter JAR from bundled sources when missing
 */
import * as cp   from 'child_process';
import * as fs   from 'fs';
import * as https from 'https';
import * as path from 'path';
import * as vscode from 'vscode';
import type { Platform } from './platform';
import { which } from './which';

const GSON_URL =
  'https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar';

// ---------------------------------------------------------------------------
// Java resolution
// ---------------------------------------------------------------------------

/**
 * Resolve the java executable path.
 * Priority: fantom.javaPath setting → JAVA_HOME env var → PATH lookup.
 */
export function resolveJavaCmd(platform: Platform): string {
  const config    = vscode.workspace.getConfiguration('fantom');
  const javaPath  = config.get<string>('javaPath') || '';
  if (javaPath) { return javaPath; }

  const javaHome = process.env.JAVA_HOME;
  if (javaHome) { return path.join(javaHome, 'bin', platform.javaExeName); }

  return which(platform.javaExeName) ?? platform.javaExeName;
}

/**
 * Given the path to java, return the path to a sibling JDK tool (javac, jar).
 * If java is a bare name on PATH (no directory component), the tool is also bare.
 */
function jdkBinTool(javaCmd: string, toolExeName: string): string {
  if (path.isAbsolute(javaCmd) || javaCmd.includes(path.sep)) {
    return path.join(path.dirname(javaCmd), toolExeName);
  }
  return toolExeName;
}

/**
 * Verify that the java executable at `javaCmd` is runnable.
 */
export function isJavaAvailable(javaCmd: string): Promise<boolean> {
  return new Promise(resolve => {
    const child = cp.spawn(javaCmd, ['-version'], { stdio: 'ignore', shell: false });
    child.on('error', () => resolve(false));
    child.on('close', code => resolve(code === 0));
  });
}

// ---------------------------------------------------------------------------
// User prompt
// ---------------------------------------------------------------------------

/**
 * Show a warning popup telling the user Java was not found and offering to
 * configure it.  Updates `fantom.javaPath` if the user enters a path.
 * Returns the newly configured java command, or undefined if dismissed.
 */
export async function promptForJavaPath(platform: Platform): Promise<string | undefined> {
  const choice = await vscode.window.showWarningMessage(
    'Fantom: Java (JDK 11+) not found. It is required for the Fantom debugger.',
    'Set Java Path',
    'Open Settings',
    'Dismiss'
  );

  if (choice === 'Set Java Path') {
    const placeholder = platform.javaExeName === 'java.exe'
      ? 'C:\\Program Files\\Java\\jdk-17\\bin\\java.exe'
      : '/usr/lib/jvm/java-17-openjdk-amd64/bin/java';
    const input = await vscode.window.showInputBox({
      prompt: `Full path to the ${platform.javaExeName} executable`,
      placeHolder: placeholder,
    });
    if (input?.trim()) {
      const trimmed = input.trim();
      await vscode.workspace.getConfiguration('fantom').update(
        'javaPath', trimmed, vscode.ConfigurationTarget.Global
      );
      vscode.window.showInformationMessage(
        `Fantom: Java path saved. Restart VS Code if the debugger still does not work.`
      );
      return trimmed;
    }
  } else if (choice === 'Open Settings') {
    await vscode.commands.executeCommand('workbench.action.openSettings', 'fantom.javaPath');
  }

  return undefined;
}

// ---------------------------------------------------------------------------
// JAR auto-build
// ---------------------------------------------------------------------------

/** Download a URL to a local file, following HTTP redirects. */
function downloadFile(url: string, dest: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);
    https.get(url, res => {
      if (res.statusCode === 301 || res.statusCode === 302) {
        file.close();
        try { fs.unlinkSync(dest); } catch { /* ignore */ }
        downloadFile(res.headers.location!, dest).then(resolve).catch(reject);
        return;
      }
      res.pipe(file);
      file.on('finish', () => file.close(() => resolve()));
    }).on('error', err => {
      try { fs.unlinkSync(dest); } catch { /* ignore */ }
      reject(err);
    });
  });
}

/** Spawn a process and return its exit code and stderr text. */
function runProcess(
  cmd: string, args: string[], cwd: string
): Promise<{ code: number; stderr: string }> {
  return new Promise(resolve => {
    let stderr = '';
    const child = cp.spawn(cmd, args, { cwd, stdio: ['ignore', 'ignore', 'pipe'] });
    child.stderr?.on('data', (d: Buffer) => { stderr += d.toString(); });
    child.on('error', err => resolve({ code: 1, stderr: err.message }));
    child.on('close', code => resolve({ code: code ?? 1, stderr }));
  });
}

/** Recursively collect all .java files under a directory. */
function collectJavaFiles(dir: string): string[] {
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

/**
 * Compile the debug-adapter JAR from sources bundled with the extension.
 *
 * Expected layout inside the extension:
 *   bundled-debug/java-src/  — Java source tree (fan/lsp/debug/...)
 *   bundled-debug/lib/       — Gson JAR (downloaded on first build)
 *
 * Output: bundled-debug/fantom-debug-adapter.jar
 *
 * Returns true on success.
 */
export async function buildDebugAdapterJar(
  extensionPath: string,
  javaCmd: string,
  platform: Platform
): Promise<boolean> {
  return vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: 'Fantom: Building debug adapter', cancellable: false },
    async (progress) => {
      const bundledDebug = path.join(extensionPath, 'bundled-debug');
      const srcDir       = path.join(bundledDebug, 'java-src');
      const libDir       = path.join(bundledDebug, 'lib');
      const classesDir   = path.join(bundledDebug, 'classes');
      const gsonJar      = path.join(libDir, 'gson.jar');
      const jarOut       = path.join(bundledDebug, 'fantom-debug-adapter.jar');

      fs.mkdirSync(libDir,     { recursive: true });
      fs.mkdirSync(classesDir, { recursive: true });

      // Step 1: Gson
      if (!fs.existsSync(gsonJar)) {
        progress.report({ message: 'Downloading Gson library…' });
        try {
          await downloadFile(GSON_URL, gsonJar);
        } catch (e: any) {
          vscode.window.showErrorMessage(
            `Fantom: Failed to download Gson: ${e.message}. ` +
            `Download manually from ${GSON_URL} and place it at ${gsonJar}`
          );
          return false;
        }
      }

      // Step 2: collect sources
      const javaFiles = collectJavaFiles(srcDir);
      if (javaFiles.length === 0) {
        vscode.window.showErrorMessage(`Fantom: No Java sources found in ${srcDir}.`);
        return false;
      }

      // Step 3: compile
      const javacCmd = jdkBinTool(javaCmd, platform.javacExeName);
      progress.report({ message: 'Compiling Java sources…' });
      const compileResult = await runProcess(
        javacCmd,
        ['--add-modules', 'jdk.jdi', '-cp', gsonJar, '-d', classesDir, ...javaFiles],
        bundledDebug
      );
      if (compileResult.code !== 0) {
        vscode.window.showErrorMessage(
          `Fantom: javac failed. ${compileResult.stderr.slice(0, 400)}`
        );
        return false;
      }

      // Step 4: extract Gson classes into classesDir so the fat-JAR contains them
      const jarCmd = jdkBinTool(javaCmd, platform.jarExeName);
      progress.report({ message: 'Packaging JAR…' });
      const extractResult = await runProcess(jarCmd, ['xf', gsonJar], classesDir);
      if (extractResult.code !== 0) {
        vscode.window.showErrorMessage(`Fantom: Failed to extract Gson into classes.`);
        return false;
      }
      // Remove META-INF brought in by Gson to avoid manifest conflicts
      const metaInf = path.join(classesDir, 'META-INF');
      if (fs.existsSync(metaInf)) { fs.rmSync(metaInf, { recursive: true, force: true }); }

      // Step 5: write manifest and create fat JAR
      const manifestPath = path.join(bundledDebug, '_MANIFEST_.MF');
      fs.writeFileSync(manifestPath, 'Manifest-Version: 1.0\nMain-Class: fan.lsp.debug.Main\n\n');

      const packageResult = await runProcess(
        jarCmd,
        ['cfm', jarOut, manifestPath, '-C', classesDir, '.'],
        bundledDebug
      );
      try { fs.unlinkSync(manifestPath); } catch { /* ignore */ }
      fs.rmSync(classesDir, { recursive: true, force: true });

      if (packageResult.code !== 0) {
        vscode.window.showErrorMessage(`Fantom: jar packaging failed.`);
        return false;
      }

      return true;
    }
  );
}

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------

/**
 * Ensure the debug-adapter JAR is present.
 * If missing, attempt to compile it from bundled Java sources.
 * Returns the JAR path on success, or undefined if unavailable.
 */
export async function ensureDebugAdapterJar(
  extensionPath: string,
  platform: Platform,
  log: (msg: string) => void
): Promise<string | undefined> {
  const jarPath = path.join(extensionPath, 'bundled-debug', 'fantom-debug-adapter.jar');
  if (fs.existsSync(jarPath)) { return jarPath; }

  log('Debug adapter JAR not found — attempting to build from bundled sources.');

  const srcDir = path.join(extensionPath, 'bundled-debug', 'java-src');
  if (!fs.existsSync(srcDir)) {
    vscode.window.showErrorMessage(
      'Fantom: Debug adapter JAR is missing and Java sources are not bundled. ' +
      'Re-install the extension, or build manually: bash debug-adapter/build.sh'
    );
    return undefined;
  }

  // Resolve and verify java
  let javaCmd = resolveJavaCmd(platform);
  if (!(await isJavaAvailable(javaCmd))) {
    log(`Java not available at: ${javaCmd}`);
    const configured = await promptForJavaPath(platform);
    if (!configured) {
      vscode.window.showErrorMessage(
        'Fantom: Java is required to build the debug adapter. ' +
        'Set fantom.javaPath in VS Code settings.'
      );
      return undefined;
    }
    javaCmd = configured;
  }

  const ok = await buildDebugAdapterJar(extensionPath, javaCmd, platform);
  if (!ok) { return undefined; }

  vscode.window.showInformationMessage('Fantom: Debug adapter built successfully.');
  return jarPath;
}

/**
 * Check Java availability at extension startup and warn the user if missing.
 * Non-blocking — does not prevent the extension from activating.
 */
export async function checkJavaAtStartup(
  platform: Platform,
  log: (msg: string) => void
): Promise<void> {
  const javaCmd = resolveJavaCmd(platform);
  const available = await isJavaAvailable(javaCmd);
  if (available) {
    log(`Java found: ${javaCmd}`);
    return;
  }
  log(`Java not found at: ${javaCmd}`);
  // Show prompt asynchronously — don't await to keep activation fast
  promptForJavaPath(platform).catch(() => { /* user dismissed */ });
}
