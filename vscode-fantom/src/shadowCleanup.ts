import * as fs from 'fs';
import * as path from 'path';

/**
 * Recursively walks `dir` and unlinks any entry whose lstat reports it as a
 * symlink or junction (isSymbolicLink).  This must run before rmSync so that
 * Windows junctions are not followed during the recursive delete.
 *
 * Returns true if every symlink/junction was successfully unlinked, false if
 * any unlink failed (caller should not proceed with recursive delete on Windows).
 */
export function unlinkShadowLinks(dir: string): boolean {
  let entries: fs.Dirent[];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return true; }
  let allOk = true;
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isSymbolicLink()) {
      try {
        fs.unlinkSync(full);
      } catch (_) {
        allOk = false;
      }
    } else if (entry.isDirectory()) {
      if (!unlinkShadowLinks(full)) { allOk = false; }
    }
  }
  return allOk;
}

/**
 * Points shadowLibJava at realLibJava using a junction (Windows) or symlink
 * (Linux/Mac).  If the junction/symlink cannot be created (e.g. missing
 * SeCreateSymbolicLink privilege on Windows), falls back to a recursive copy
 * of lib/java into the shadow dir so the JVM can always find sys.jar without
 * touching FAN_HOME.
 */
export function linkOrCopyLibJava(
  realLibJava: string,
  shadowLibJava: string,
  log: (msg: string) => void,
): void {
  try {
    fs.symlinkSync(realLibJava, shadowLibJava, 'junction');
    return;
  } catch (_) {
    // Junction creation failed — fall through to copy.
  }
  log('lib/java junction failed — copying lib/java into shadow dir as fallback');
  copyDirRecursive(realLibJava, shadowLibJava);
}

/** Recursively copies all files from src into dest (dest is created if needed). */
export function copyDirRecursive(src: string, dest: string): void {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const srcPath  = path.join(src,  entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDirRecursive(srcPath, destPath);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}
