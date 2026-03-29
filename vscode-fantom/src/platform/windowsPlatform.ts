import type { Platform } from '../platform';

export class WindowsPlatform implements Platform {
  readonly javaExeName        = 'java.exe';
  readonly javacExeName       = 'javac.exe';
  readonly jarExeName         = 'jar.exe';
  readonly classpathSeparator = ';';
}
