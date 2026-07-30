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
 * Deletion is always targeted — never recursive:
 *   - Each junction/symlink is removed with fs.unlinkSync (leaf-only, never followed).
 *   - Each real directory created by this class is removed with fs.rmdirSync (non-recursive).
 *   - fs.rmSync is never called on any directory, so Windows cannot follow a junction
 *     into the real Fantom installation.
 *
 * dispose() only runs on a clean shutdown (deactivate(), or before creating a
 * replacement). An abrupt kill of the extension host — e.g. VS Code force-
 * restarting itself to apply an update — skips dispose() entirely and leaves
 * the shadow dir orphaned in os.tmpdir(), junctions and all. sweepOrphaned()
 * must be called near activation to clean up any such leftovers from a prior
 * session before they can be swept up by an external recursive delete (disk
 * cleanup, antivirus, a manual %TEMP% wipe) that follows the junctions into
 * the real installation.
 */
/** Prefix used for every shadow dir this class creates, under os.tmpdir(). */
const SHADOW_DIR_PREFIX = 'fantom-lsp-shadow-';

export class ShadowDir {
  private constructor(readonly path: string) {}

  /**
   * Finds and safely disposes shadow dirs left behind by a previous session
   * that was killed before it could call dispose() (e.g. VS Code force-
   * restarting itself to apply an update — deactivate() never runs on an
   * abrupt process kill). Each match is torn down with the same leaf-only
   * logic as dispose(), never a recursive delete, so a junction inside an
   * orphaned dir can never be followed into the real Fantom installation.
   *
   * Without this sweep, orphaned shadow dirs accumulate under os.tmpdir()
   * indefinitely — each one full of live junctions into the real
   * installation's etc/ and lib/java/ — and remain a hazard for any external
   * tool (Windows Disk Cleanup, Storage Sense, antivirus, manual %TEMP%
   * wipe) that later recursively deletes the temp folder and follows those
   * junctions into the real installation.
   *
   * Safe to call at any time, including while a current shadow dir is in
   * use — currentDirPath is always skipped.
   */
  static sweepOrphaned(currentDirPath: string | undefined, log: (msg: string) => void): void {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(os.tmpdir(), { withFileTypes: true });
    } catch (_) {
      return;
    }

    for (const entry of entries) {
      if (!entry.isDirectory() || !entry.name.startsWith(SHADOW_DIR_PREFIX)) { continue; }
      const full = path.join(os.tmpdir(), entry.name);
      if (full === currentDirPath) { continue; }

      log(`Found orphaned shadow dir from a previous session: ${full}`);
      ShadowDir.disposeLibFan(full, log);
      ShadowDir.disposeLibJava(full, log);
      ShadowDir.disposeEtc(full, log);
      ShadowDir.removeRealDirIfEmpty(path.join(full, 'lib'), log);
      ShadowDir.removeRealDirIfEmpty(full, log);
    }
  }

  /**
   * Creates a shadow dir and returns a ShadowDir instance, or undefined on
   * failure (partial dir is cleaned up safely before returning).
   */
  static create(
    mainPodFileName: string,
    realFanHome: string,
    log: (msg: string) => void,
  ): ShadowDir | undefined {
    // mkdtempSync atomically creates a unique directory — unlike a
    // Date.now()-suffixed name, it cannot collide with another shadow dir
    // created within the same millisecond (e.g. two overlapping restarts).
    // A collision there would make the second create() call tear down the
    // first, still-in-use shadow dir out from under it.
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), SHADOW_DIR_PREFIX));
    try {
      ShadowDir.buildLibFan(dir, mainPodFileName, realFanHome);
      ShadowDir.buildLibJava(dir, realFanHome, log);
      ShadowDir.buildEtc(dir, realFanHome, log);
      log(`Shadow dir created: ${dir}`);
      return new ShadowDir(dir);
    } catch (e: any) {
      log(`WARNING: Could not create shadow dir: ${e.message}`);
      // Clean up whatever was partially built — same targeted approach as dispose().
      ShadowDir.disposeLibFan(dir, log);
      ShadowDir.disposeLibJava(dir, log);
      ShadowDir.disposeEtc(dir, log);
      ShadowDir.removeRealDirIfEmpty(path.join(dir, 'lib'), log);
      ShadowDir.removeRealDirIfEmpty(dir, log);
      return undefined;
    }
  }

  /**
   * Removes the shadow dir by deleting only the entries the extension created,
   * in reverse build order.  Each junction/symlink is unlinked as a leaf —
   * fs.rmSync is never called on any path that contains or could contain a
   * junction, so Windows can never follow a junction into the real installation.
   */
  dispose(log: (msg: string) => void): void {
    ShadowDir.disposeLibFan(this.path, log);
    ShadowDir.disposeLibJava(this.path, log);
    ShadowDir.disposeEtc(this.path, log);
    ShadowDir.removeRealDirIfEmpty(path.join(this.path, 'lib'), log);
    ShadowDir.removeRealDirIfEmpty(this.path, log);
    log(`Cleaned up shadow dir: ${this.path}`);
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
  // Targeted disposal helpers (one per build phase, executed in reverse)
  // ---------------------------------------------------------------------------

  /**
   * Deletes every entry inside lib/fan/ then removes the real directories.
   * Hard links and symlinks are unlinked as leaf nodes — rmSync is only called
   * on the real lib/fan/ directory after it has been emptied entry-by-entry.
   */
  private static disposeLibFan(shadowDir: string, log: (msg: string) => void): void {
    const libFan = path.join(shadowDir, 'lib', 'fan');
    ShadowDir.removeLeafEntries(libFan, log);
    ShadowDir.removeRealDirIfEmpty(libFan, log);
  }

  /**
   * Removes lib/java — either an unlink (junction/symlink) or entry-by-entry
   * deletion of the copied directory, never a recursive rmSync on a junction.
   */
  private static disposeLibJava(shadowDir: string, log: (msg: string) => void): void {
    const libJava = path.join(shadowDir, 'lib', 'java');
    try {
      const stat = fs.lstatSync(libJava);
      if (stat.isSymbolicLink()) {
        // Junction or symlink — unlink the leaf entry only, never recurse.
        fs.unlinkSync(libJava);
      } else if (stat.isDirectory()) {
        // Copied fallback — only real files inside, safe to delete entry-by-entry.
        ShadowDir.removeLeafEntries(libJava, log);
        ShadowDir.removeRealDirIfEmpty(libJava, log);
      }
    } catch (_) {}
  }

  /**
   * Removes etc/ — unlinks junction/symlink leaves, then removes the real
   * etc/sys/ entries one by one, then rmdir the real directories.
   * Never calls rmSync on a directory that may contain junctions.
   */
  private static disposeEtc(shadowDir: string, log: (msg: string) => void): void {
    const etcDir    = path.join(shadowDir, 'etc');
    const etcSysDir = path.join(etcDir, 'sys');

    // etc/sys/ — only real files (copies); remove individually then rmdir.
    ShadowDir.removeLeafEntries(etcSysDir, log);
    ShadowDir.removeRealDirIfEmpty(etcSysDir, log);

    // etc/<other>/ — each is a junction or symlink leaf; unlink directly.
    ShadowDir.removeLeafEntries(etcDir, log);
    ShadowDir.removeRealDirIfEmpty(etcDir, log);
  }

  /**
   * Walks `dir` one level deep and removes every entry:
   * - Symlinks/junctions: fs.unlinkSync (removes the leaf, never follows)
   * - Regular files:      fs.unlinkSync
   * - Subdirectories:     NOT touched — this method is intentionally shallow
   *
   * Real subdirectories must be emptied by a dedicated helper before calling
   * removeRealDirIfEmpty on them.
   */
  private static removeLeafEntries(dir: string, log: (msg: string) => void): void {
    let entries: fs.Dirent[];
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return; }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isSymbolicLink() || entry.isFile()) {
        try { fs.unlinkSync(full); } catch (e: any) {
          log(`WARNING: could not remove shadow entry "${full}": ${e.message}`);
        }
      }
      // Real subdirectories are left for their own dedicated disposal helper.
    }
  }

  // ---------------------------------------------------------------------------
  // Public utilities (used by tests and as internal helpers)
  // ---------------------------------------------------------------------------

  /** Removes `dir` with fs.rmdirSync (non-recursive — safe by design). */
  static removeRealDirIfEmpty(dir: string, log: (msg: string) => void): void {
    try { fs.rmdirSync(dir); } catch (e: any) {
      log(`WARNING: could not remove shadow dir "${dir}": ${e.message}`);
    }
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
