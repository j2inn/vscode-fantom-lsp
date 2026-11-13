/**
 * download.ts
 *
 * Downloads a file over HTTPS and refuses to keep anything that is not the
 * expected file: the HTTP status must be 200, redirects are limited and must
 * stay on HTTPS, and a SHA-256 checksum can be required. The data is written
 * to a temporary file and moved into place only when every check passes, so a
 * failed or partial download never leaves a file at the destination.
 *
 * No VS Code dependency — runs under plain Node for unit tests.
 */
import * as crypto from 'crypto';
import * as fs from 'fs';
import * as https from 'https';
import type { IncomingMessage } from 'http';

/** Maximum number of redirects followed before giving up. */
const MAX_REDIRECTS = 5;

/** HTTP status codes that point to another location. */
const REDIRECT_STATUSES = [301, 302, 303, 307, 308];

/** Minimal request function, replaceable in tests. */
export type HttpsGet = (
  url: string,
  onResponse: (res: IncomingMessage) => void
) => { on(event: 'error', listener: (err: Error) => void): unknown };

export interface DownloadOptions {
  /** Expected SHA-256 of the file, as lowercase hex. The download fails if it differs. */
  sha256?: string;
  /** Request function; defaults to https.get. */
  get?: HttpsGet;
}

/** Downloads `url` to `dest`. Rejects, leaving nothing at `dest`, on any failure. */
export async function downloadFile(
  url: string,
  dest: string,
  options: DownloadOptions = {}
): Promise<void> {
  const get = options.get ?? (https.get as unknown as HttpsGet);
  const part = `${dest}.part`;
  try {
    const hash = await fetchToFile(url, part, get, MAX_REDIRECTS);
    if (options.sha256 && hash !== options.sha256.toLowerCase()) {
      throw new Error(`checksum mismatch: expected ${options.sha256}, got ${hash}`);
    }
    fs.renameSync(part, dest);
  } catch (e) {
    try { fs.unlinkSync(part); } catch { /* nothing to clean up */ }
    throw e;
  }
}

/** Follows redirects, streams the body into `part`, and resolves with its SHA-256. */
function fetchToFile(url: string, part: string, get: HttpsGet, redirectsLeft: number): Promise<string> {
  return new Promise((resolve, reject) => {
    get(url, res => {
      const status = res.statusCode ?? 0;
      if (REDIRECT_STATUSES.includes(status)) {
        res.resume();
        const location = res.headers.location;
        if (!location || redirectsLeft <= 0) {
          reject(new Error(`too many redirects or missing Location from ${url}`));
          return;
        }
        const next = new URL(location, url).toString();
        if (!next.startsWith('https://')) {
          reject(new Error(`refusing redirect to a non-HTTPS URL: ${next}`));
          return;
        }
        fetchToFile(next, part, get, redirectsLeft - 1).then(resolve, reject);
        return;
      }
      if (status !== 200) {
        res.resume();
        reject(new Error(`HTTP ${status} from ${url}`));
        return;
      }
      const hash = crypto.createHash('sha256');
      const file = fs.createWriteStream(part);
      res.on('data', (chunk: Buffer) => hash.update(chunk));
      res.on('error', err => { file.destroy(); reject(err); });
      file.on('error', reject);
      file.on('finish', () => resolve(hash.digest('hex')));
      res.pipe(file);
    }).on('error', reject);
  });
}
