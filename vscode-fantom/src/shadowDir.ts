import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

const isWindows = process.platform === 'win32';

/**
 * Owns the lifecycle of a temporary shadow copy of a Fantom installation tree.
 *
 * The shadow dir acts as a substitute FAN_HOME for the LSP server process so
 * that the real installation files stay unlocked and can be overwritten by
 * builds while the server is running.
 *
 * Structure inside the shadow dir:
 *   lib/fan/<main>.pod   – real copy (original stays free for builds to overwrite)
 *   lib/fan/*.pod        – hard link (Windows) or symlink (Linux/Mac) to real pod
 *   lib/java/            – junction (Windows) or symlink (Linux/Mac) to real lib/java,
 *                          with recursive copy as fallback when junction creation fails
 *   etc/                 – real directory
 *   etc/sys/             – real directory
 *   etc/sys/config.props – modified copy with java.options stripped
 *   etc/sys/<other>      – copy (Windows) or symlink (Linux/Mac) to real file
 *   etc/<other>/         – junction (Windows) or symlink (Linux/Mac) to real subdir
 *
 * All deletion goes through safeRemove(), which:
 *   1. Verifies the path is inside os.tmpdir() — refuses to delete otherwise.
 *   2. Unlinks all junctions/symlinks before rmSync so Windows cannot follow
 *      them into the real installation.
 *   3. Only calls rmSync when every junction was successfully unlinked.
 */
export class ShadowDir {
  private constructor(readonly path: string) {}

  /**
   * Creates a shadow dir and returns a ShadowDir instance, or undefined on
   * failure (partial dir is cleaned up safely before returning).
   */
  static create(
    mainPodFileName: string,
    realFanHome: string,
    log: (msg: string) => void,
  ): ShadowDir | undefined {
    const dir = path.join(os.tmpdir(), `fantom-lsp-shadow-${Date.now()}`);
    try {
      ShadowDir.buildLibFan(dir, mainPodFileName, realFanHome);
      ShadowDir.buildLibJava(dir, realFanHome, log);
      ShadowDir.buildEtc(dir, realFanHome, log);
      log(`Shadow dir created: ${dir}`);
      return new ShadowDir(dir);
    } catch (e: any) {
      log(`WARNING: Could not create shadow dir: ${e.message}`);
      ShadowDir.safeRemove(dir, log);
      return undefined;
    }
  }

  /** Removes the shadow dir safely. */
  dispose(log: (msg: string) => void): void {
    ShadowDir.safeRemove(this.path, log);
  }

  // ---------------------------------------------------------------------------
  // Build phases
  // ---------------------------------------------------------------------------

  private static buildLibFan(
    shadowDir: string,
    mainPodFileName: string,
    realFanHome: string,
  ): void {
    const shadowLibFan = path.join(shadowDir, 'lib', 'fan');
    fs.mkdirSync(shadowLibFan, { recursive: true });

    const realLibFan = path.join(realFanHome, 'lib', 'fan');
    for (const entry of fs.readdirSync(realLibFan)) {
      if (!entry.endsWith('.pod')) { continue; }
      const src  = path.join(realLibFan, entry);
      const dest = path.join(shadowLibFan, entry);
      if (entry === mainPodFileName) {
        // Real copy — original stays unlocked so builds can overwrite it.
        fs.copyFileSync(src, dest);
      } else {
        // Hard link (Windows): shares the inode; deleting the shadow entry
        // never touches the original file in realFanHome.
        // Symlink (Linux/Mac): rmSync does not follow file symlinks.
        isWindows ? fs.linkSync(src, dest) : fs.symlinkSync(src, dest);
      }
    }
  }

  private static buildLibJava(
    shadowDir: string,
    realFanHome: string,
    log: (msg: string) => void,
  ): void {
    const realLibJava   = path.join(realFanHome, 'lib', 'java');
    const shadowLibJava = path.join(shadowDir, 'lib', 'java');

    // Junction (Windows) / symlink (Linux/Mac) so the Fantom launcher finds
    // sys.jar when it derives FAN_CP from FAN_HOME.
    // Fall back to a recursive copy when junction creation fails (e.g. missing
    // SeCreateSymbolicLink privilege) — the copy is inside %TEMP% so it is
    // always safe to delete later without touching the real installation.
    try {
      fs.symlinkSync(realLibJava, shadowLibJava, 'junction');
    } catch (_) {
      log('lib/java junction failed — copying lib/java into shadow dir as fallback');
      ShadowDir.copyDirRecursive(realLibJava, shadowLibJava);
    }
  }

  private static buildEtc(
    shadowDir: string,
    realFanHome: string,
    log: (msg: string) => void,
  ): void {
    const realEtcDir   = path.join(realFanHome, 'etc');
    const shadowEtcDir = path.join(shadowDir, 'etc');
    fs.mkdirSync(shadowEtcDir, { recursive: true });

    for (const etcEntry of fs.readdirSync(realEtcDir)) {
      const realEtcPath   = path.join(realEtcDir, etcEntry);
      const shadowEtcPath = path.join(shadowEtcDir, etcEntry);

      if (etcEntry === 'sys') {
        // etc/sys needs a real directory so we can write a modified config.props.
        fs.mkdirSync(shadowEtcPath, { recursive: true });
        for (const sysEntry of fs.readdirSync(realEtcPath)) {
          const realSysPath   = path.join(realEtcPath, sysEntry);
          const shadowSysPath = path.join(shadowEtcPath, sysEntry);
          if (sysEntry === 'config.props') {
            // Strip java.options to suppress JDWP output on LSP stdout.
            const original = fs.readFileSync(realSysPath, 'utf8');
            const modified = original
              .split('\n')
              .filter(line => !line.trim().startsWith('java.options'))
              .join('\n');
            fs.writeFileSync(shadowSysPath, modified, 'utf8');
            log('Shadow config.props: stripped java.options (JDWP suppressed)');
          } else {
            // File symlinks require Developer Mode on Windows — copy instead.
            isWindows
              ? fs.copyFileSync(realSysPath, shadowSysPath)
              : fs.symlinkSync(realSysPath, shadowSysPath);
          }
        }
      } else {
        // Every other etc/ entry: junction (Windows dirs) or symlink (Linux/Mac).
        const stat = fs.statSync(realEtcPath);
        if (isWindows && stat.isDirectory()) {
          fs.symlinkSync(realEtcPath, shadowEtcPath, 'junction');
        } else {
          fs.symlinkSync(realEtcPath, shadowEtcPath);
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Safe removal
  // ---------------------------------------------------------------------------

  /**
   * The single place in the codebase that deletes a shadow dir.
   *
   * Guards:
   *   1. Path must be inside os.tmpdir() — never deletes outside %TEMP%/tmp.
   *   2. All junctions/symlinks inside the tree are unlinked first so that
   *      Windows rmSync cannot follow them into the real installation.
   *   3. rmSync is skipped entirely if any junction failed to unlink on Windows.
   */
  private static safeRemove(dir: string, log: (msg: string) => void): void {
    // Guard 1: boundary check — refuse to delete anything outside os.tmpdir().
    const tmpBase = os.tmpdir();
    if (!isUnderDir(dir, tmpBase)) {
      log(`WARNING: shadow dir "${dir}" is not under tmpdir "${tmpBase}" — refusing to delete`);
      return;
    }

    // Guard 2 + 3: unlink junctions first; on Windows abort if any remain.
    const allUnlinked = ShadowDir.unlinkSymlinks(dir);
    if (isWindows && !allUnlinked) {
      log(`WARNING: Could not unlink all junctions in shadow dir — skipping delete to protect FAN_HOME: ${dir}`);
      return;
    }

    try {
      fs.rmSync(dir, { recursive: true });
      log(`Cleaned up shadow dir: ${dir}`);
    } catch (_) {}
  }

  /**
   * Recursively walks dir and unlinks every entry that isSymbolicLink() —
   * which covers both plain symlinks and Windows junctions.
   * Returns true only when every such entry was successfully unlinked.
   */
  static unlinkSymlinks(dir: string): boolean {
    let entries: fs.Dirent[];
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return true; }
    let allOk = true;
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isSymbolicLink()) {
        try { fs.unlinkSync(full); } catch (_) { allOk = false; }
      } else if (entry.isDirectory()) {
        if (!ShadowDir.unlinkSymlinks(full)) { allOk = false; }
      }
    }
    return allOk;
  }

  // ---------------------------------------------------------------------------
  // Utilities
  // ---------------------------------------------------------------------------

  /** Recursively copies all files from src into dest (dest is created if needed). */
  static copyDirRecursive(src: string, dest: string): void {
    fs.mkdirSync(dest, { recursive: true });
    for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
      const srcPath  = path.join(src,  entry.name);
      const destPath = path.join(dest, entry.name);
      if (entry.isDirectory()) {
        ShadowDir.copyDirRecursive(srcPath, destPath);
      } else {
        fs.copyFileSync(srcPath, destPath);
      }
    }
  }
}

/** Returns true when target is equal to base or is a descendant of base. */
function isUnderDir(target: string, base: string): boolean {
  const rel = path.relative(base, target);
  return !!rel && !rel.startsWith('..') && !path.isAbsolute(rel);
}
