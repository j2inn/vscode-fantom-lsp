import * as fs from 'fs';
import * as path from 'path';

const isWindows = process.platform === 'win32';

// Extensions to try on Windows when the name has no extension
const WIN_EXTS = ['.bat', '.cmd', '.exe', '.com'];

export function which(name: string): string | undefined {
  const dirs = (process.env.PATH || '').split(path.delimiter);
  for (const dir of dirs) {
    const full = path.join(dir, name);

    // On Windows, try the name with common executable extensions
    if (isWindows && !path.extname(name)) {
      for (const ext of WIN_EXTS) {
        const fullExt = full + ext;
        if (fs.existsSync(fullExt)) {
          return fullExt;
        }
      }
    }

    try {
      fs.accessSync(full, fs.constants.X_OK);
      return full;
    } catch {
      // not found in this dir
    }
  }
  return undefined;
}
