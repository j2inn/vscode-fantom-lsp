import * as fs from 'fs';
import type { Platform } from '../platform';

export class LinuxPlatform implements Platform {
  readonly javaExeName        = 'java';
  readonly javacExeName       = 'javac';
  readonly jarExeName         = 'jar';
  readonly classpathSeparator = ':';
  readonly spawnThroughShell  = false;

  launcherNames(name: string): string[] { return [name]; }

  scriptPathAlternatives(_rawPath: string): string[] { return []; }

  /** Symlink: fs.rmSync/unlink never follows a file symlink. */
  linkFile(src: string, dest: string): void { fs.symlinkSync(src, dest); }

  linkOrCopyFile(src: string, dest: string): void { fs.symlinkSync(src, dest); }

  linkDirectory(src: string, dest: string): void { fs.symlinkSync(src, dest); }
}
