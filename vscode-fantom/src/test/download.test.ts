/**
 * Unit tests for downloadFile.
 *
 * No VS Code dependency — runs with plain Node.js after TypeScript compilation:
 *   node out/test/download.test.js
 */

import * as assert from 'assert';
import * as crypto from 'crypto';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { Readable } from 'stream';
import { downloadFile, HttpsGet } from '../download';

let passed = 0;
let failed = 0;

async function test(name: string, fn: () => Promise<void>): Promise<void> {
  try {
    await fn();
    console.log(`  ✓ ${name}`);
    passed++;
  } catch (e: any) {
    console.error(`  ✗ ${name}`);
    console.error(`    ${e.message}`);
    failed++;
  }
}

/** Fake https.get serving canned responses by URL. */
function fakeGet(routes: Record<string, { status: number; body?: string; location?: string }>): HttpsGet {
  return (url, onResponse) => {
    const route = routes[url];
    const res: any = Readable.from(route && route.body !== undefined ? [Buffer.from(route.body)] : []);
    res.statusCode = route ? route.status : 404;
    res.headers = route && route.location ? { location: route.location } : {};
    setImmediate(() => onResponse(res));
    return { on: () => undefined };
  };
}

function tmpDest(): string {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'download-test-')), 'out.jar');
}

const sha = (s: string) => crypto.createHash('sha256').update(s).digest('hex');

async function main(): Promise<void> {
  console.log('\ndownloadFile tests:');

  await test('saves the body of a 200 response', async () => {
    const dest = tmpDest();
    await downloadFile('https://x/a', dest, { get: fakeGet({ 'https://x/a': { status: 200, body: 'hello' } }) });
    assert.strictEqual(fs.readFileSync(dest, 'utf8'), 'hello');
    assert.ok(!fs.existsSync(`${dest}.part`), 'temp file must be gone');
  });

  await test('a 404 response fails and leaves nothing behind', async () => {
    const dest = tmpDest();
    await assert.rejects(
      downloadFile('https://x/a', dest, { get: fakeGet({ 'https://x/a': { status: 404, body: '<html>' } }) }),
      /HTTP 404/);
    assert.ok(!fs.existsSync(dest) && !fs.existsSync(`${dest}.part`));
  });

  await test('follows a redirect to another HTTPS URL', async () => {
    const dest = tmpDest();
    const get = fakeGet({
      'https://x/a': { status: 302, location: 'https://y/b' },
      'https://y/b': { status: 200, body: 'moved' },
    });
    await downloadFile('https://x/a', dest, { get });
    assert.strictEqual(fs.readFileSync(dest, 'utf8'), 'moved');
  });

  await test('refuses a redirect to plain HTTP', async () => {
    const dest = tmpDest();
    const get = fakeGet({ 'https://x/a': { status: 301, location: 'http://evil/b' } });
    await assert.rejects(downloadFile('https://x/a', dest, { get }), /non-HTTPS/);
    assert.ok(!fs.existsSync(dest));
  });

  await test('gives up after too many redirects', async () => {
    const dest = tmpDest();
    const get = fakeGet({ 'https://x/a': { status: 302, location: 'https://x/a' } });
    await assert.rejects(downloadFile('https://x/a', dest, { get }), /too many redirects/);
  });

  await test('accepts a matching checksum', async () => {
    const dest = tmpDest();
    await downloadFile('https://x/a', dest, {
      get: fakeGet({ 'https://x/a': { status: 200, body: 'data' } }),
      sha256: sha('data'),
    });
    assert.ok(fs.existsSync(dest));
  });

  await test('rejects a checksum mismatch and leaves nothing behind', async () => {
    const dest = tmpDest();
    await assert.rejects(
      downloadFile('https://x/a', dest, {
        get: fakeGet({ 'https://x/a': { status: 200, body: 'tampered' } }),
        sha256: sha('data'),
      }),
      /checksum mismatch/);
    assert.ok(!fs.existsSync(dest) && !fs.existsSync(`${dest}.part`));
  });

  console.log(`\n${passed} passed, ${failed} failed`);
  if (failed > 0) { process.exit(1); }
}

main();
