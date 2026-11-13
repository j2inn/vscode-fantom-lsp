import * as fs from 'fs';
import * as path from 'path';
import type { Platform } from '../platform';

/**
 * Hard-links `src` to `dest`, or copies it when linking is impossible. A hard
 * link cannot cross volumes (EXDEV), which is common here: the shadow dir is
 * under %TEMP% on C: while a Fantom installation often lives on another drive.
 * `link` is injectable for tests.
 */
export function hardLinkOrCopy(
  src: string,
  dest: string,
  link: (s: string, d: string) => void = fs.linkSync,
): void {
  try {
    link(src, dest);
  } catch (_) {
    fs.copyFileSync(src, dest);
  }
}

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

  /**
   * Hard link (needs no elevation; unlinking it never touches the original),
   * falling back to a copy across volumes.
   */
  linkFile(src: string, dest: string): void { hardLinkOrCopy(src, dest); }

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
        hardLinkOrCopy(from, to);
      }
    }
  }
}
