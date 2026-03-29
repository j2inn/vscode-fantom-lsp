import type { Platform } from '../platform';

export class LinuxPlatform implements Platform {
  readonly javaExeName        = 'java';
  readonly javacExeName       = 'javac';
  readonly jarExeName         = 'jar';
  readonly classpathSeparator = ':';
}
