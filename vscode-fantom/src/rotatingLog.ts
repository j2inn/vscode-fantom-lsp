import * as fs from 'fs';

/** Default size at which the active log file is rotated. */
export const DEFAULT_MAX_LOG_BYTES = 512 * 1024;

/** Default number of rotated files kept next to the active one (file.1 .. file.N). */
export const DEFAULT_KEPT_LOG_FILES = 3;

/**
 * Append-only text log with size-based rotation: when the active file would
 * exceed `maxBytes` it becomes `file.1`, the previous `file.1` becomes `file.2`
 * and so on; the oldest of `keep` rotated files is dropped. Total disk use is
 * therefore bounded by roughly `maxBytes * (keep + 1)`. Never throws.
 */
export class RotatingLog {
  private size: number;

  constructor(
    readonly filePath: string,
    private readonly maxBytes: number = DEFAULT_MAX_LOG_BYTES,
    private readonly keep: number = DEFAULT_KEPT_LOG_FILES,
  ) {
    this.size = RotatingLog.fileSize(filePath);
  }

  /** Appends one line (a newline is added). */
  append(line: string): void {
    const text = line + '\n';
    const bytes = Buffer.byteLength(text);
    try {
      if (this.size > 0 && this.size + bytes > this.maxBytes) { this.rotate(); }
      fs.appendFileSync(this.filePath, text);
      this.size += bytes;
    } catch (_) { /* logging must never break the extension */ }
  }

  private rotate(): void {
    for (let i = this.keep; i >= 1; i--) {
      const from = i === 1 ? this.filePath : `${this.filePath}.${i - 1}`;
      const to = `${this.filePath}.${i}`;
      try {
        if (i === this.keep) { fs.rmSync(to, { force: true }); }
        if (fs.existsSync(from)) { fs.renameSync(from, to); }
      } catch (_) { /* keep going: a locked old file must not stop the log */ }
    }
    this.size = RotatingLog.fileSize(this.filePath);
  }

  private static fileSize(file: string): number {
    try { return fs.statSync(file).size; } catch (_) { return 0; }
  }
}
