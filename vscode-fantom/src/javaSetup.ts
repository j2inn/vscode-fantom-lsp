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
      if (!fs.existsSync(srcDir)) {
        vscode.window.showErrorMessage(
          `Fantom: Java source directory not found: ${srcDir}. ` +
          `The extension package may be missing bundled Java sources.`
        );
        return false;
      }
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
        await showBuildError('Fantom: Compilation failed', compileResult.stderr);
        return false;
      }

      // Step 4: extract Gson classes into classesDir so the fat-JAR contains them
      const jarCmd = jdkBinTool(javaCmd, platform.jarExeName);
      progress.report({ message: 'Packaging JAR…' });
      const extractResult = await runProcess(jarCmd, ['xf', gsonJar], classesDir);
      if (extractResult.code !== 0) {
        await showBuildError('Fantom: Failed to extract Gson', extractResult.stderr);
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
        await showBuildError('Fantom: JAR packaging failed', packageResult.stderr);
        return false;
      }

      return true;
    }
  );
}

// ---------------------------------------------------------------------------
// Error display helper
// ---------------------------------------------------------------------------

/**
 * Show a build error message with a "Show Details" button that opens the
 * full stderr output in a new editor tab.  This avoids truncating long
 * compiler error listings in a notification popup.
 */
async function showBuildError(title: string, stderr: string): Promise<void> {
  const choice = await vscode.window.showErrorMessage(title, 'Show Details', 'Dismiss');
  if (choice === 'Show Details') {
    const doc = await vscode.workspace.openTextDocument({
      content: stderr || '(no output)',
      language: 'plaintext',
    });
    await vscode.window.showTextDocument(doc, { preview: true });
  }
}

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------

/**
 * Return the path where the debug adapter JAR lives (whether or not it exists).
 */
function debugAdapterJarPath(extensionPath: string): string {
  return path.join(extensionPath, 'bundled-debug', 'fantom-debug-adapter.jar');
}

/**
 * Ensure the debug-adapter JAR exists.  Called by the debug adapter factory
 * just before a debug session starts; by this point the JAR should already
 * have been built by checkJavaAndBuildAdapterAtStartup().  If it is still
 * absent (user dismissed the startup build or Java appeared later) we return
 * undefined so VS Code shows a friendly "could not launch" message rather
 * than a raw file-not-found error.
 */
export function ensureDebugAdapterJar(
  extensionPath: string,
  _platform: Platform,
  log: (msg: string) => void
): Promise<string | undefined> {
  const jarPath = debugAdapterJarPath(extensionPath);
  if (fs.existsSync(jarPath)) {
    return Promise.resolve(jarPath);
  }
  log('Debug adapter JAR not found. Run "Fantom: Rebuild debugger" to compile it.');
  vscode.window.showErrorMessage(
    'Fantom: Debug adapter JAR is not built. Run the command ' +
    '"Fantom: Rebuild debugger" (Ctrl+Shift+P) to compile it.',
    'Rebuild now'
  ).then(choice => {
    if (choice === 'Rebuild now') {
      vscode.commands.executeCommand('fantom.rebuildDebugAdapter');
    }
  });
  return Promise.resolve(undefined);
}

/**
 * Run at extension startup:
 *  1. Resolve Java (JAVA_HOME → fantom.javaPath setting → PATH).
 *  2. If not found → show warning popup offering to configure it.
 *  3. If found and the JAR is missing → build it with a progress notification.
 *
 * Non-blocking from the caller's perspective — the build runs asynchronously
 * and does not delay extension activation.
 */
export async function checkJavaAndBuildAdapterAtStartup(
  extensionPath: string,
  platform: Platform,
  log: (msg: string) => void
): Promise<void> {
  const javaCmd = resolveJavaCmd(platform);
  log(`Checking Java: ${javaCmd}`);

  if (!(await isJavaAvailable(javaCmd))) {
    log(`Java not available at: ${javaCmd}`);
    const choice = await vscode.window.showWarningMessage(
      'Fantom: Java (JDK 11+) was not found. It is required to build and run the Fantom debugger. ' +
      'Set JAVA_HOME or configure "fantom.javaPath" in VS Code settings.',
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
        await vscode.workspace.getConfiguration('fantom').update(
          'javaPath', input.trim(), vscode.ConfigurationTarget.Global
        );
        vscode.window.showInformationMessage(
          'Fantom: Java path saved. Restart VS Code to apply.'
        );
      }
    } else if (choice === 'Open Settings') {
      vscode.commands.executeCommand('workbench.action.openSettings', 'fantom.javaPath');
    }
    return;
  }

  log(`Java found: ${javaCmd}`);

  const jarPath = debugAdapterJarPath(extensionPath);
  if (fs.existsSync(jarPath)) {
    log(`Debug adapter JAR already present: ${jarPath}`);
    return;
  }

  log('Debug adapter JAR missing — building from bundled sources…');
  const ok = await buildDebugAdapterJar(extensionPath, javaCmd, platform);
  if (ok) {
    vscode.window.showInformationMessage('Fantom: Debug adapter built successfully.');
    log('Debug adapter JAR built successfully.');
  } else {
    log('Debug adapter JAR build failed.');
  }
}

/**
 * Force-rebuild the debug adapter JAR (deletes the existing one first).
 * Used by the "Fantom: Rebuild debugger" command.
 */
export async function rebuildDebugAdapterJar(
  extensionPath: string,
  platform: Platform,
  log: (msg: string) => void
): Promise<void> {
  const javaCmd = resolveJavaCmd(platform);

  if (!(await isJavaAvailable(javaCmd))) {
    const choice = await vscode.window.showErrorMessage(
      'Fantom: Java not found. Set JAVA_HOME or "fantom.javaPath" in settings before rebuilding.',
      'Open Settings'
    );
    if (choice === 'Open Settings') {
      vscode.commands.executeCommand('workbench.action.openSettings', 'fantom.javaPath');
    }
    return;
  }

  // Delete existing JAR so buildDebugAdapterJar creates a fresh one
  const jarPath = debugAdapterJarPath(extensionPath);
  try { fs.unlinkSync(jarPath); } catch { /* does not exist yet — fine */ }

  log('Rebuilding debug adapter JAR…');
  const ok = await buildDebugAdapterJar(extensionPath, javaCmd, platform);
  if (ok) {
    vscode.window.showInformationMessage('Fantom: Debug adapter rebuilt successfully.');
    log('Debug adapter JAR rebuilt successfully.');
  } else {
    log('Debug adapter JAR rebuild failed.');
  }
}
