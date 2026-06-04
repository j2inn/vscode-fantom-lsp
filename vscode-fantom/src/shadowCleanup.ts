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
