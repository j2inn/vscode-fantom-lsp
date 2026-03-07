import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as vscode from 'vscode';
import { getDeclarationEndLine } from './declarationRange';
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;
let outputChannel: vscode.OutputChannel;

let errorStatusItem: vscode.StatusBarItem | undefined;
let warnStatusItem: vscode.StatusBarItem | undefined;

const POD_FILE_NEW = 'vscodeFantomLsp.pod';
const POD_FILE_LEGACY = 'lsp.pod';
const SCRIPT_NEW = 'vscodeFantomLsp::Main';
const SCRIPT_LEGACY = 'lsp::Main';

function updateDiagnosticStatusItems(): void {
  let errors = 0;
  let warnings = 0;

  vscode.languages.getDiagnostics().forEach(([, diags]) => {
    diags.forEach(d => {
      if (d.severity === vscode.DiagnosticSeverity.Error) errors++;
      else if (d.severity === vscode.DiagnosticSeverity.Warning) warnings++;
    });
  });

  if (errorStatusItem) {
    if (errors > 0) {
      errorStatusItem.text = `$(error) ${errors}`;
      errorStatusItem.tooltip = `${errors} error${errors !== 1 ? 's' : ''}`;
      errorStatusItem.show();
    } else {
      errorStatusItem.hide();
    }
  }

  if (warnStatusItem) {
    if (warnings > 0) {
      warnStatusItem.text = `$(warning) ${warnings}`;
      warnStatusItem.tooltip = `${warnings} warning${warnings !== 1 ? 's' : ''}`;
      warnStatusItem.show();
    } else {
      warnStatusItem.hide();
    }
  }
}

const isWindows = process.platform === 'win32';

function log(msg: string): void {
  outputChannel.appendLine(`[Fantom] ${msg}`);
  console.log(`[Fantom] ${msg}`);
}

// Path of the current shadow dir, if any.  Cleaned up on deactivation.
let currentShadowDir: string | undefined;

/**
 * Creates a shadow copy of lsp.pod in a temp directory so the LSP server
 * loads the pod from there, leaving the original free to be overwritten
 * during builds.
 *
 * Structure:
 *   <shadowDir>/lib/fan/lsp.pod  – real copy (original stays unlocked for builds)
 *   <shadowDir>/lib/fan/*.pod    – symlink/hardlink to each real pod
 *   <shadowDir>/lib/java         – junction/symlink → realFanHome/lib/java (sys.jar)
 *   <shadowDir>/etc              – junction/symlink → realFanHome/etc (timezone data etc.)
 *
 * Returns the shadow dir path, or undefined on failure.
 */
function createShadowDir(mainPodFileName: string, realFanHome: string): string | undefined {
  const shadowDir = path.join(os.tmpdir(), `fantom-lsp-shadow-${Date.now()}`);
  try {
    const shadowLibFan = path.join(shadowDir, 'lib', 'fan');
    fs.mkdirSync(shadowLibFan, { recursive: true });

    // Fantom loads sys.pod at JVM static-init time, before config.props path= is
    // applied, so we must expose ALL pods in shadowDir/lib/fan/.
    // - main pod: real copy so the original file is never opened by the server
    //   and stays free for the build to overwrite.
    // - every other pod: symlink (Linux/Mac) or hard link (Windows).
    //   Hard links share the inode with the original, but those pods are never
    //   rebuilt so any JVM lock on them is harmless.
    const realLibFan = path.join(realFanHome, 'lib', 'fan');
    for (const entry of fs.readdirSync(realLibFan)) {
      if (!entry.endsWith('.pod')) { continue; }
      const src  = path.join(realLibFan, entry);
      const dest = path.join(shadowLibFan, entry);
      if (entry === mainPodFileName) {
        fs.copyFileSync(src, dest);
      } else {
        // fs.linkSync creates a hard link (no elevation needed on Windows).
        // fs.symlinkSync creates a plain symlink on Linux/Mac.
        isWindows ? fs.linkSync(src, dest) : fs.symlinkSync(src, dest);
      }
    }

    // Junction (Windows) / symlink (Linux/Mac) for lib/java so the fanlaunch
    // script finds sys.jar when it derives FAN_CP from FAN_HOME.
    fs.symlinkSync(
      path.join(realFanHome, 'lib', 'java'),
      path.join(shadowDir, 'lib', 'java'),
      'junction'
    );

    // Junction/symlink the entire etc/ tree so timezone data, locale files,
    // and real config.props are all found.  No custom config.props is needed
    // because all pods are already present in shadowDir/lib/fan/.
    fs.symlinkSync(
      path.join(realFanHome, 'etc'),
      path.join(shadowDir, 'etc'),
      'junction'
    );

    log(`Shadow dir created: ${shadowDir}`);
    return shadowDir;
  } catch (e: any) {
    log(`WARNING: Could not create shadow dir: ${e.message}`);
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
    return undefined;
  }
}

function cleanupShadowDir(): void {
  if (currentShadowDir) {
    try {
      fs.rmSync(currentShadowDir, { recursive: true });
      log(`Cleaned up shadow dir: ${currentShadowDir}`);
    } catch (_) {}
    currentShadowDir = undefined;
  }
}

/**
 * Check if the current workspace is a Fantom project.
 * Returns true if any workspace folder contains build.fan, *.fan files, or fan.config.json.
 */
function isFantomProject(): boolean {
  const folders = vscode.workspace.workspaceFolders;
  if (!folders) { return false; }

  for (const folder of folders) {
    if (fs.existsSync(path.join(folder.uri.fsPath, 'fan.config.json'))) { return true; }
    if (fs.existsSync(path.join(folder.uri.fsPath, 'build.fan'))) { return true; }
    if (fs.existsSync(path.join(folder.uri.fsPath, 'build.all'))) { return true; }

    // Check for .fan files in root
    try {
      const entries = fs.readdirSync(folder.uri.fsPath);
      if (entries.some(e => e.endsWith('.fan'))) { return true; }
    } catch (e) { /* ignore */ }
  }
  return false;
}

/**
 * Resolve the fan executable from FAN_HOME.
 */
function resolveFanExecutable(fanHome: string): string | undefined {
  const fanBin = isWindows ? 'fan.bat' : 'fan';
  const fanExePath = path.join(fanHome, 'bin', fanBin);
  if (fs.existsSync(fanExePath)) { return fanExePath; }
  if (isWindows) {
    const alt = path.join(fanHome, 'bin', 'fan.exe');
    if (fs.existsSync(alt)) { return alt; }
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// fan.config.json
// ---------------------------------------------------------------------------

interface FinConfig {
  /** Path to the Fantom installation directory (containing bin/fan). Optional — falls back to FAN_HOME env var. */
  fanPath?: string;
  /** Build target passed to 'fan build.fan <target>'. Optional. */
  fanTargetBuild?: string;
  /** Milliseconds to wait after the last keystroke before running diagnostics. Default: 2000. */
  debounceTime?: number;
  /** Whether to warn on unused 'using' imports. Default: true. */
  enableUnusedImport?: boolean;
}

/** Returns the absolute path to fan.config.json in the first workspace folder. */
function getFinConfigPath(): string | undefined {
  const folders = vscode.workspace.workspaceFolders;
  if (!folders || folders.length === 0) { return undefined; }
  return path.join(folders[0].uri.fsPath, 'fan.config.json');
}

/**
 * Reads and parses fan.config.json from the workspace root.
 * If the file is missing, offers to create a skeleton and returns undefined.
 * If the file is malformed, shows an error and returns undefined.
 */
async function readFinConfig(): Promise<FinConfig | undefined> {
  const configPath = getFinConfigPath();
  if (!configPath) { return undefined; }

  if (!fs.existsSync(configPath)) {
    log('fan.config.json not found');

    // If FAN_HOME is set in the environment, use it as fallback without requiring the config file.
    const envFanHome = (process.env.FAN_HOME || '').trim();
    if (envFanHome) {
      log(`fan.config.json not found, using FAN_HOME env var: ${envFanHome}`);
      return {} as FinConfig;
    }

    const choice = await vscode.window.showWarningMessage(
      'Fantom: fan.config.json not found and FAN_HOME is not set. ' +
      'Set the FAN_HOME environment variable to your Fantom installation directory, ' +
      'or create a fan.config.json with a "fanPath" entry. Would you like to create a skeleton?',
      'Create fan.config.json',
      'Not now'
    );

    if (choice === 'Create fan.config.json') {
      const skeleton: FinConfig = {
        fanPath: '/path/to/fantom-installation',
        fanTargetBuild: '',
        debounceTime: 500
      };
      try {
        fs.writeFileSync(configPath, JSON.stringify(skeleton, null, 2) + '\n', 'utf8');
        log(`Created skeleton fan.config.json at ${configPath}`);
        const doc = await vscode.workspace.openTextDocument(configPath);
        await vscode.window.showTextDocument(doc);
        vscode.window.showInformationMessage(
          'fan.config.json created. Set "fanPath" to your Fantom installation directory ' +
          '(the folder containing bin/fan), or remove it and set the FAN_HOME environment variable instead. ' +
          'Save the file to restart the LSP.'
        );
      } catch (e: any) {
        vscode.window.showErrorMessage(`Fantom: Could not create fan.config.json: ${e.message}`);
      }
    }
    return undefined;
  }

  try {
    const content = fs.readFileSync(configPath, 'utf8');
    const parsed = JSON.parse(content) as FinConfig;
    log(`Loaded fan.config.json: fanPath="${parsed.fanPath ?? '(not set, FAN_HOME will be used)'}", fanTargetBuild="${parsed.fanTargetBuild ?? ''}", debounceTime=${parsed.debounceTime ?? 2000}, enableUnusedImport=${parsed.enableUnusedImport ?? true}`);
    return parsed;
  } catch (e: any) {
    log(`ERROR parsing fan.config.json: ${e.message}`);
    vscode.window.showErrorMessage(
      `Fantom: Failed to parse fan.config.json: ${e.message}. ` +
      'Please fix the JSON and save the file to restart the LSP.'
    );
    return undefined;
  }
}

// ---------------------------------------------------------------------------
// LSP client lifecycle
// ---------------------------------------------------------------------------

/**
 * Resolve and validate fanHome from a FinConfig.
 * Returns the fan executable path, or undefined on error (after showing a message).
 */
function resolveFanPath(finConfig: FinConfig): string | undefined {
  // fanPath in fan.config.json takes priority over FAN_HOME env var.
  let fanHome = (finConfig.fanPath || '').trim();
  while (fanHome.endsWith('/') || fanHome.endsWith('\\')) {
    fanHome = fanHome.slice(0, -1);
  }

  const isPlaceholder = !fanHome || fanHome === '/path/to/fantom-installation';
  if (isPlaceholder) {
    // Fall back to FAN_HOME environment variable
    fanHome = (process.env.FAN_HOME || '').trim();
    while (fanHome.endsWith('/') || fanHome.endsWith('\\')) {
      fanHome = fanHome.slice(0, -1);
    }
    if (fanHome) {
      log(`fanPath not set in fan.config.json — using FAN_HOME env var: ${fanHome}`);
    }
  }

  if (!fanHome) {
    log('ERROR: fanPath not configured and FAN_HOME is not set');
    vscode.window.showWarningMessage(
      'Fantom: Set "fanPath" in fan.config.json or the FAN_HOME environment variable ' +
      'to your Fantom installation directory (the folder containing bin/fan).'
    );
    return undefined;
  }

  if (!fs.existsSync(fanHome)) {
    log(`ERROR: fanHome directory does not exist: ${fanHome}`);
    vscode.window.showErrorMessage(
      `Fantom: Fantom installation directory "${fanHome}" does not exist. ` +
      'Check "fanPath" in fan.config.json or the FAN_HOME environment variable.'
    );
    return undefined;
  }

  const fanExe = resolveFanExecutable(fanHome);
  if (!fanExe) {
    log(`ERROR: fan executable not found in ${path.join(fanHome, 'bin')}`);
    vscode.window.showErrorMessage(
      `Fantom: fan executable not found in "${path.join(fanHome, 'bin')}". ` +
      'Check "fanPath" in fan.config.json or the FAN_HOME environment variable.'
    );
    return undefined;
  }

  log(`fan executable = "${fanExe}"`);
  return fanExe;
}

/**
 * Start (or restart) the LSP client with the given configuration.
 * The caller is responsible for stopping any existing client first.
 */
async function startLspClient(context: vscode.ExtensionContext, finConfig: FinConfig): Promise<void> {
  const fanExe = resolveFanPath(finConfig);
  if (!fanExe) { return; }

  const config = vscode.workspace.getConfiguration('fantom');
  const javaPath = config.get<string>('javaPath') || '';
  const javaHome = process.env.JAVA_HOME;
  const javaExe = isWindows ? 'java.exe' : 'java';
  const actualJavaPath = javaPath || (javaHome ? path.join(javaHome, 'bin', javaExe) : 'java');
  log(`Java path = "${actualJavaPath}"`);

  // Create a shadow copy of lsp.pod so builds can overwrite the original
  // while the server is running.
  cleanupShadowDir();
  const fanHome = path.dirname(path.dirname(fanExe));
  const podDir = path.join(fanHome, 'lib', 'fan');
  const newPodSrc = path.join(podDir, POD_FILE_NEW);
  const legacyPodSrc = path.join(podDir, POD_FILE_LEGACY);
  const mainPodSrc = fs.existsSync(newPodSrc) ? newPodSrc : legacyPodSrc;
  const mainPodFileName = fs.existsSync(newPodSrc) ? POD_FILE_NEW : POD_FILE_LEGACY;
  const serverScript = fs.existsSync(newPodSrc) ? SCRIPT_NEW : SCRIPT_LEGACY;

  log(`Selected language server pod: ${mainPodFileName}`);
  log(`Selected language server script: ${serverScript}`);

  if (fs.existsSync(mainPodSrc)) {
    currentShadowDir = createShadowDir(mainPodFileName, fanHome);
  }

  const serverOptions: ServerOptions = {
    command: fanExe,
    args: [serverScript],
    options: {
      shell: isWindows,
      env: {
        ...process.env,
        FAN_JAVA: actualJavaPath,
        ...(currentShadowDir ? { FAN_HOME: currentShadowDir } : {})
      }
    }
  };

  const fanBuildTarget = (finConfig.fanTargetBuild || '').trim();
  const debounceMs = (typeof finConfig.debounceTime === 'number' && finConfig.debounceTime >= 100)
    ? finConfig.debounceTime
    : 2000;
  const pedanticMode = config.get<boolean>('pedanticMode') ?? false;
  // enableUnusedImport defaults to true when absent from fan.config.json
  const enableUnusedImport = finConfig.enableUnusedImport !== false;

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: 'file', language: 'fantom' }
    ],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher('**/*.fan')
    },
    initializationOptions: {
      fanPath: fanExe,
      fanBuildTarget: fanBuildTarget || undefined,
      debounceMs: debounceMs || undefined,
      pedanticMode: pedanticMode,
      enableUnusedImport: enableUnusedImport
    },
    outputChannelName: 'Fantom Language Server',
    traceOutputChannel: vscode.window.createOutputChannel('Fantom Language Server Trace')
  };

  client = new LanguageClient(
    'fantomLanguageServer',
    'Fantom Language Server',
    serverOptions,
    clientOptions
  );

  // Register indexing progress handler before start() so no notifications are missed.
  // The server sends fantom/progress { kind, message, increment? } from backgroundInit.
  {
    let progressReporter: vscode.Progress<{ message?: string; increment?: number }> | undefined;
    let progressResolve: (() => void) | undefined;

    client.onNotification('fantom/progress', (params: any) => {
      const kind: string    = params?.kind    ?? '';
      const message: string = params?.message ?? '';
      const increment: number | undefined = typeof params?.increment === 'number'
        ? params.increment : undefined;

      if (kind === 'begin') {
        vscode.window.withProgress(
          { location: vscode.ProgressLocation.Notification, title: 'Fantom LSP', cancellable: false },
          (progress) => {
            progressReporter = progress;
            progress.report({ message });
            return new Promise<void>(resolve => { progressResolve = resolve; });
          }
        );
      } else if (kind === 'report') {
        progressReporter?.report({ message, increment });
      } else if (kind === 'end') {
        progressResolve?.();
        progressResolve  = undefined;
        progressReporter = undefined;
      }
    });
  }

  log('Starting Fantom Language Server...');

  client.start().then(() => {
    log('Language Server started successfully');

    if (!fanBuildTarget) {
      vscode.window.showInformationMessage(
        'Fantom: Consider setting "fanTargetBuild" in fan.config.json for project builds.'
      );
    }
  }).catch((error) => {
    log(`ERROR starting Language Server: ${error.message}`);
    vscode.window.showErrorMessage(
      `Failed to start Fantom Language Server: ${error.message}`
    );
  });
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  outputChannel = vscode.window.createOutputChannel('Fantom Extension');
  log('Extension activating...');

  // --- Step 0: Only proceed if this is a Fantom project ---
  if (!isFantomProject()) {
    log('No Fantom project detected (no build.fan, .fan files, or fan.config.json). Extension idle.');
    return;
  }

  log('👻 Fantom project detected!');
  vscode.window.showInformationMessage('👻 A Fantom project has been found!');

  // --- Status bar items (created once, reused across restarts) ---
  errorStatusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 99);
  errorStatusItem.command = 'workbench.actions.view.problems';
  errorStatusItem.name = 'Fantom Errors';
  context.subscriptions.push(errorStatusItem);

  warnStatusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 98);
  warnStatusItem.command = 'workbench.actions.view.problems';
  warnStatusItem.name = 'Fantom Warnings';
  context.subscriptions.push(warnStatusItem);

  context.subscriptions.push(
    vscode.languages.onDidChangeDiagnostics(() => updateDiagnosticStatusItems())
  );

  // --- Command: Remove Unused Imports in File ---
  context.subscriptions.push(
    vscode.commands.registerCommand('fantom.removeUnusedImports', async () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor || editor.document.languageId !== 'fantom') {
        vscode.window.showWarningMessage('Fantom: Open a .fan file to remove unused imports.');
        return;
      }

      const uri = editor.document.uri;
      const diags = vscode.languages.getDiagnostics(uri);

      const unusedImportDiags = diags.filter(d =>
        d.source === 'fantom' &&
        d.severity === vscode.DiagnosticSeverity.Warning &&
        d.message.startsWith('Unused import')
      );

      if (unusedImportDiags.length === 0) {
        vscode.window.showInformationMessage('Fantom: No unused imports found.');
        return;
      }

      // Sort descending by line so deletions don't shift subsequent line numbers
      unusedImportDiags.sort((a, b) => b.range.start.line - a.range.start.line);

      const edit = new vscode.WorkspaceEdit();
      for (const d of unusedImportDiags) {
        const line = d.range.start.line;
        edit.delete(uri, new vscode.Range(line, 0, line + 1, 0));
      }

      const applied = await vscode.workspace.applyEdit(edit);
      if (!applied) {
        vscode.window.showErrorMessage('Fantom: Failed to apply edits.');
        return;
      }

      // Save the document so the LSP reads the updated content from disk
      // and clears the stale diagnostics.
      await editor.document.save();

      const count = unusedImportDiags.length;
      vscode.window.showInformationMessage(
        `Fantom: Removed ${count} unused import${count !== 1 ? 's' : ''}.`
      );
    })
  );

  // --- Command: Remove Unused Imports in Project ---
  context.subscriptions.push(
    vscode.commands.registerCommand('fantom.removeUnusedImportsInProject', async () => {
      const allDiagnostics = vscode.languages.getDiagnostics();

      const edit = new vscode.WorkspaceEdit();
      const modifiedUris: vscode.Uri[] = [];
      let totalCount = 0;

      for (const [uri, diags] of allDiagnostics) {
        if (!uri.path.endsWith('.fan')) { continue; }

        const unusedImportDiags = diags.filter(d =>
          d.source === 'fantom' &&
          d.severity === vscode.DiagnosticSeverity.Warning &&
          d.message.startsWith('Unused import')
        );

        if (unusedImportDiags.length === 0) { continue; }

        // Sort descending by line so deletions don't shift subsequent line numbers
        unusedImportDiags.sort((a, b) => b.range.start.line - a.range.start.line);

        for (const d of unusedImportDiags) {
          const line = d.range.start.line;
          edit.delete(uri, new vscode.Range(line, 0, line + 1, 0));
        }

        modifiedUris.push(uri);
        totalCount += unusedImportDiags.length;
      }

      if (totalCount === 0) {
        vscode.window.showInformationMessage('Fantom: No unused imports found in project.');
        return;
      }

      const applied = await vscode.workspace.applyEdit(edit);
      if (!applied) {
        vscode.window.showErrorMessage('Fantom: Failed to apply project edits.');
        return;
      }

      // applyEdit modifies the in-memory buffer but does not save to disk.
      // Explicitly save each modified document so the LSP re-reads the new
      // content and clears the diagnostics.
      await Promise.all(modifiedUris.map(async (uri) => {
        try {
          const doc = await vscode.workspace.openTextDocument(uri);
          await doc.save();
        } catch (_) { /* ignore individual save failures */ }
      }));

      const fileCount = modifiedUris.length;
      vscode.window.showInformationMessage(
        `Fantom: Removed ${totalCount} unused import${totalCount !== 1 ? 's' : ''} across ${fileCount} file${fileCount !== 1 ? 's' : ''}.`
      );
    })
  );

  // --- Command: Remove Unused Variables in File ---
  context.subscriptions.push(
    vscode.commands.registerCommand('fantom.removeUnusedVariables', async () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor || editor.document.languageId !== 'fantom') {
        vscode.window.showWarningMessage('Fantom: Open a .fan file to remove unused variables.');
        return;
      }

      const uri = editor.document.uri;
      const diags = vscode.languages.getDiagnostics(uri);

      const unusedVarDiags = diags.filter(d =>
        d.source === 'fantom' &&
        d.severity === vscode.DiagnosticSeverity.Warning &&
        d.message.includes('is declared but never used')
      );

      if (unusedVarDiags.length === 0) {
        vscode.window.showInformationMessage('Fantom: No unused variables found.');
        return;
      }

      // Sort descending by start line so deletions don't shift subsequent line numbers.
      unusedVarDiags.sort((a, b) => b.range.start.line - a.range.start.line);

      const document = editor.document;
      const edit = new vscode.WorkspaceEdit();
      for (const d of unusedVarDiags) {
        const startLine = d.range.start.line;
        const endLine = getDeclarationEndLine(
          i => document.lineAt(i).text,
          document.lineCount,
          startLine
        );
        edit.delete(uri, new vscode.Range(startLine, 0, endLine + 1, 0));
      }

      const applied = await vscode.workspace.applyEdit(edit);
      if (!applied) {
        vscode.window.showErrorMessage('Fantom: Failed to apply edits.');
        return;
      }

      await editor.document.save();

      const count = unusedVarDiags.length;
      vscode.window.showInformationMessage(
        `Fantom: Removed ${count} unused variable${count !== 1 ? 's' : ''}.`
      );
    })
  );

  // --- Command: Remove Unused Variables in Project ---
  context.subscriptions.push(
    vscode.commands.registerCommand('fantom.removeUnusedVariablesInProject', async () => {
      const allDiagnostics = vscode.languages.getDiagnostics();

      const edit = new vscode.WorkspaceEdit();
      const docsToSave: vscode.TextDocument[] = [];
      let totalCount = 0;

      for (const [uri, diags] of allDiagnostics) {
        if (!uri.path.endsWith('.fan')) { continue; }

        const unusedVarDiags = diags.filter(d =>
          d.source === 'fantom' &&
          d.severity === vscode.DiagnosticSeverity.Warning &&
          d.message.includes('is declared but never used')
        );

        if (unusedVarDiags.length === 0) { continue; }

        // Open the document to read line content for multi-line detection.
        let doc: vscode.TextDocument;
        try {
          doc = await vscode.workspace.openTextDocument(uri);
        } catch (_) { continue; }

        // Sort descending by start line so deletions don't shift subsequent line numbers.
        unusedVarDiags.sort((a, b) => b.range.start.line - a.range.start.line);

        for (const d of unusedVarDiags) {
          const startLine = d.range.start.line;
          const endLine = getDeclarationEndLine(
            i => doc.lineAt(i).text,
            doc.lineCount,
            startLine
          );
          edit.delete(uri, new vscode.Range(startLine, 0, endLine + 1, 0));
        }

        docsToSave.push(doc);
        totalCount += unusedVarDiags.length;
      }

      if (totalCount === 0) {
        vscode.window.showInformationMessage('Fantom: No unused variables found in project.');
        return;
      }

      const applied = await vscode.workspace.applyEdit(edit);
      if (!applied) {
        vscode.window.showErrorMessage('Fantom: Failed to apply project edits.');
        return;
      }

      await Promise.all(docsToSave.map(async (doc) => {
        try { await doc.save(); } catch (_) { /* ignore individual save failures */ }
      }));

      const fileCount = docsToSave.length;
      vscode.window.showInformationMessage(
        `Fantom: Removed ${totalCount} unused variable${totalCount !== 1 ? 's' : ''} across ${fileCount} file${fileCount !== 1 ? 's' : ''}.`
      );
    })
  );

  // --- Watch fan.config.json — restart LSP on change ---
  const folders = vscode.workspace.workspaceFolders;
  if (folders && folders.length > 0) {
    const finConfigWatcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(folders[0], 'fan.config.json')
    );

    const onFinConfigChanged = async () => {
      log('fan.config.json changed, restarting LSP');
      vscode.window.showInformationMessage('Fantom: New configuration detected, restarting LSP...');

      if (client) {
        await client.stop();
        client = undefined;
      }

      const newConfig = await readFinConfig();
      if (newConfig) {
        await startLspClient(context, newConfig);
      }
    };

    finConfigWatcher.onDidChange(onFinConfigChanged);
    finConfigWatcher.onDidCreate(onFinConfigChanged);
    context.subscriptions.push(finConfigWatcher);
  }

  // --- Step 1: Read fan.config.json ---
  const finConfig = await readFinConfig();
  if (!finConfig) { return; }

  // --- Step 2: Deploy LSP pod ---
  const fanExeForDeploy = resolveFanPath(finConfig);
  if (!fanExeForDeploy) { return; }
  const fanHomeForDeploy = path.dirname(path.dirname(fanExeForDeploy)); // bin/../ = home

  const config = vscode.workspace.getConfiguration('fantom');
  const useBuiltIn = config.get<boolean>('useBuiltInLspPod') ?? true;

  if (useBuiltIn) {
    const bundledNewPod = path.join(context.extensionPath, 'bundled-pods', POD_FILE_NEW);
    const bundledLegacyPod = path.join(context.extensionPath, 'bundled-pods', POD_FILE_LEGACY);
    const bundledPod = fs.existsSync(bundledNewPod) ? bundledNewPod : bundledLegacyPod;
    const bundledPodName = fs.existsSync(bundledNewPod) ? POD_FILE_NEW : POD_FILE_LEGACY;
    log(`Selected bundled pod for deployment: ${bundledPodName}`);
    const targetDir = path.join(fanHomeForDeploy, 'lib', 'fan');
    const targetPod = path.join(targetDir, bundledPodName);

    if (!fs.existsSync(bundledPod)) {
      log(`ERROR: bundled language server pod not found at ${bundledNewPod} or ${bundledLegacyPod}`);
      vscode.window.showErrorMessage(
        'Fantom: Built-in LSP pod not found in extension. The extension may be incomplete.'
      );
      return;
    }

    if (!fs.existsSync(targetDir)) {
      log(`ERROR: target dir does not exist: ${targetDir}`);
      vscode.window.showErrorMessage(
        `Fantom: "${targetDir}" does not exist. Check fanPath in fan.config.json.`
      );
      return;
    }

    if (fs.existsSync(targetPod)) {
      log(`${bundledPodName} already present at ${targetPod}`);
      const bundledBuf = fs.readFileSync(bundledPod);
      const targetBuf = fs.readFileSync(targetPod);
      if (bundledBuf.equals(targetBuf)) {
        log(`${bundledPodName} is identical to bundled version`);
        vscode.window.showInformationMessage(`Fantom: ${bundledPodName} with latest version already exists.`);
      } else {
        const choice = await vscode.window.showInformationMessage(
          `Fantom: A language server pod (${bundledPodName}) already exists. It is recommended to update it to get the latest features and fixes.`,
          'Update',
          'Skip'
        );
        if (choice === 'Update') {
          try {
            fs.copyFileSync(bundledPod, targetPod);
            log(`Updated ${bundledPodName} at ${targetPod}`);
            vscode.window.showInformationMessage('Fantom: LSP pod updated successfully.');
          } catch (e: any) {
            log(`ERROR updating ${bundledPodName}: ${e.message}`);
            vscode.window.showErrorMessage(
              `Fantom: Failed to update LSP pod. Error: ${e.message}`
            );
            return;
          }
        } else {
          log(`User chose to skip ${bundledPodName} update`);
        }
      }
    } else {
      try {
        fs.copyFileSync(bundledPod, targetPod);
        log(`Deployed ${bundledPodName} to ${targetPod}`);
        vscode.window.showInformationMessage(`Fantom: LSP pod installed to ${targetPod}`);
      } catch (e: any) {
        log(`ERROR copying ${bundledPodName}: ${e.message}`);
        vscode.window.showErrorMessage(
          `Fantom: LSP pod cannot be installed to "${targetPod}". Error: ${e.message}`
        );
        return;
      }
    }
  } else {
    const podDir = path.join(fanHomeForDeploy, 'lib', 'fan');
    const hasNew = fs.existsSync(path.join(podDir, POD_FILE_NEW));
    const hasLegacy = fs.existsSync(path.join(podDir, POD_FILE_LEGACY));
    if (!hasNew && !hasLegacy) {
      log(`ERROR: no language server pod found at ${podDir}`);
      const choice = await vscode.window.showErrorMessage(
        `Fantom: neither ${POD_FILE_NEW} nor ${POD_FILE_LEGACY} was found in your fan installation. Build it or enable "useBuiltInLspPod".`,
        'Open Settings'
      );
      if (choice === 'Open Settings') {
        vscode.commands.executeCommand('workbench.action.openWorkspaceSettings', { query: 'fantom.useBuiltInLspPod' });
      }
      return;
    }
  }

  // --- Step 3: Start LSP server ---
  await startLspClient(context, finConfig);
}

export function deactivate(): Thenable<void> | undefined {
  cleanupShadowDir();
  if (!client) {
    return undefined;
  }
  log('Deactivating extension');
  return client.stop();
}
