import * as fs from 'fs';
import * as path from 'path';
import type { Platform } from '../platform';

export class WindowsPlatform implements Platform {
  readonly javaExeName        = 'java.exe';
  readonly javacExeName       = 'javac.exe';
  readonly jarExeName         = 'jar.exe';
  readonly classpathSeparator = ';';
  readonly spawnThroughShell  = true;

  launcherNames(name: string): string[] { return [`${name}.bat`, `${name}.exe`]; }

  scriptPathAlternatives(rawPath: string): string[] {
    return /\.(bat|exe|cmd)$/i.test(rawPath) ? [] : [`${rawPath}.bat`];
  }

  /** Hard link: needs no elevation, and unlinking it never touches the original. */
  linkFile(src: string, dest: string): void { fs.linkSync(src, dest); }

  /** File symlinks need Developer Mode on Windows, so copy instead. */
  linkOrCopyFile(src: string, dest: string): void { fs.copyFileSync(src, dest); }

  /**
   * Mirrors `src` as real directories holding hard links (or copies when a
   * hard link is impossible, e.g. a different volume). Never a junction: an
   * orphaned shadow dir in %TEMP% would otherwise let any recursive delete
   * (disk cleanup, antivirus, an update) follow the junction into `src` and
   * wipe the real installation. Deleting a hard link or copy only ever
   * removes the shadow entry.
   */
  linkDirectory(src: string, dest: string): void {
    fs.mkdirSync(dest, { recursive: true });
    for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
      const from = path.join(src, entry.name);
      const to = path.join(dest, entry.name);
      if (entry.isDirectory()) {
        this.linkDirectory(from, to);
      } else {
        try { fs.linkSync(from, to); } catch (_) { fs.copyFileSync(from, to); }
      }
    }
  }
}
