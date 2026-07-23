import * as vscode from 'vscode';

/**
 * GitExtension API surface needed to read working-tree change state.
 * Declared locally since @types/vscode does not ship the git extension's types.
 */
interface GitApi {
  repositories: GitRepository[];
  onDidOpenRepository: vscode.Event<GitRepository>;
}
interface GitRepository {
  state: {
    workingTreeChanges: { uri: vscode.Uri }[];
    indexChanges: { uri: vscode.Uri }[];
    onDidChange: vscode.Event<void>;
  };
}
interface GitExtensionExports {
  getAPI(version: 1): GitApi;
}

/**
 * Decorates .fan files in the explorer with a color reflecting their most
 * severe state: errors > warnings > uncommitted git changes > clean.
 * VS Code's own git decorations are suppressed for .fan files by this
 * provider taking precedence whenever a color is returned.
 */
export class FantomFileDecorationProvider implements vscode.FileDecorationProvider, vscode.Disposable {
  private readonly emitter = new vscode.EventEmitter<vscode.Uri | vscode.Uri[] | undefined>();
  readonly onDidChangeFileDecorations = this.emitter.event;

  private readonly disposables: vscode.Disposable[] = [this.emitter];
  private gitApi: GitApi | undefined;

  constructor() {
    this.disposables.push(
      vscode.languages.onDidChangeDiagnostics(e => this.emitter.fire([...e.uris]))
    );
    this.hookGitExtension();
  }

  provideFileDecoration(uri: vscode.Uri): vscode.FileDecoration | undefined {
    if (!uri.path.endsWith('.fan')) { return undefined; }

    const severity = this.worstDiagnosticSeverity(uri);
    if (severity === vscode.DiagnosticSeverity.Error) {
      return new vscode.FileDecoration(undefined, 'Has errors', new vscode.ThemeColor('list.errorForeground'));
    }
    if (severity === vscode.DiagnosticSeverity.Warning) {
      return new vscode.FileDecoration(undefined, 'Has warnings', new vscode.ThemeColor('list.warningForeground'));
    }
    if (this.isGitModified(uri)) {
      return new vscode.FileDecoration(undefined, 'Modified', new vscode.ThemeColor('gitDecoration.modifiedResourceForeground'));
    }
    return undefined;
  }

  dispose(): void {
    this.disposables.forEach(d => d.dispose());
  }

  private worstDiagnosticSeverity(uri: vscode.Uri): vscode.DiagnosticSeverity | undefined {
    let worst: vscode.DiagnosticSeverity | undefined;
    for (const d of vscode.languages.getDiagnostics(uri)) {
      if (d.severity === vscode.DiagnosticSeverity.Error) { return vscode.DiagnosticSeverity.Error; }
      if (d.severity === vscode.DiagnosticSeverity.Warning) { worst = vscode.DiagnosticSeverity.Warning; }
    }
    return worst;
  }

  private isGitModified(uri: vscode.Uri): boolean {
    if (!this.gitApi) { return false; }
    return this.gitApi.repositories.some(repo =>
      repo.state.workingTreeChanges.some(c => c.uri.fsPath === uri.fsPath) ||
      repo.state.indexChanges.some(c => c.uri.fsPath === uri.fsPath)
    );
  }

  private hookGitExtension(): void {
    const gitExt = vscode.extensions.getExtension<GitExtensionExports>('vscode.git');
    if (!gitExt) { return; }

    const hookRepo = (repo: GitRepository) => {
      this.disposables.push(repo.state.onDidChange(() => this.emitter.fire(undefined)));
      this.emitter.fire(undefined);
    };

    const attach = () => {
      this.gitApi = gitExt.exports.getAPI(1);
      // Repositories may not be discovered yet at activation time (git scans
      // the workspace asynchronously), so listen for late arrivals too.
      this.gitApi.repositories.forEach(hookRepo);
      this.disposables.push(this.gitApi.onDidOpenRepository(hookRepo));
      this.emitter.fire(undefined);
    };

    (gitExt.isActive ? Promise.resolve() : gitExt.activate()).then(attach);
  }
}
