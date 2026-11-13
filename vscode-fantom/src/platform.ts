/**
 * Platform — strategy interface for OS-specific behaviour.
 *
 * Any code that behaves differently on Windows vs Linux/macOS must go through
 * this interface and its concrete implementations in src/platform/.
 * Never use inline `process.platform` checks for new feature code.
 */
export interface Platform {
  /** Name of the java executable ('java' on Linux, 'java.exe' on Windows). */
  readonly javaExeName: string;
  /** Name of the javac compiler ('javac' or 'javac.exe'). */
  readonly javacExeName: string;
  /** Name of the jar tool ('jar' or 'jar.exe'). */
  readonly jarExeName: string;
  /** Classpath separator (':' on Linux, ';' on Windows). */
  readonly classpathSeparator: string;
  /** True if launcher scripts must be spawned through a shell (Windows .bat files). */
  readonly spawnThroughShell: boolean;

  /**
   * File names a launcher called `name` can have in a bin directory, in
   * preference order (e.g. ['fan'] on Linux, ['fan.bat', 'fan.exe'] on Windows).
   */
  launcherNames(name: string): string[];

  /**
   * Alternative paths to try when `rawPath` does not exist as given
   * (e.g. `rawPath + '.bat'` on Windows). Empty on Linux.
   */
  scriptPathAlternatives(rawPath: string): string[];

  /** Make `dest` refer to the file `src` without copying it, safe to unlink later. */
  linkFile(src: string, dest: string): void;

  /** Make `dest` show the file `src`: a link where the OS allows it, else a copy. */
  linkOrCopyFile(src: string, dest: string): void;

  /** Make `dest` refer to the directory `src` (symlink, or junction on Windows). */
  linkDirectory(src: string, dest: string): void;
}

let _current: Platform | undefined;

/** Return the platform strategy for the running OS. */
export function getPlatform(): Platform {
  if (!_current) {
    _current = process.platform === 'win32'
      ? new (require('./platform/windowsPlatform').WindowsPlatform)() as Platform
      : new (require('./platform/linuxPlatform').LinuxPlatform)() as Platform;
  }
  return _current as Platform;
}
