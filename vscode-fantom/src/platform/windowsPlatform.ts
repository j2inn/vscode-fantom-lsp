import * as fs from 'fs';
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

  linkDirectory(src: string, dest: string): void { fs.symlinkSync(src, dest, 'junction'); }
}
