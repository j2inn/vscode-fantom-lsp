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
}

let _current: Platform | undefined;

/** Return the platform strategy for the running OS. */
export function getPlatform(): Platform {
  if (!_current) {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    _current = process.platform === 'win32'
      ? new (require('./platform/windowsPlatform').WindowsPlatform)() as Platform
      : new (require('./platform/linuxPlatform').LinuxPlatform)() as Platform;
  }
  return _current!;
}
