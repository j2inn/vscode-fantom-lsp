import * as assert from 'assert';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { hardLinkOrCopy } from '../platform/windowsPlatform';

function test(name: string, fn: () => void): void {
  try { fn(); console.log(`  ✓ ${name}`); } catch (e) {
    console.error(`  ✗ ${name}`); console.error(e); process.exitCode = 1;
  }
}

function tmp(): string { return fs.mkdtempSync(path.join(os.tmpdir(), 'hlc-')); }

test('hardLinkOrCopy links when possible', () => {
  const dir = tmp();
  try {
    const src = path.join(dir, 'a'); fs.writeFileSync(src, 'x');
    const dest = path.join(dir, 'b');
    hardLinkOrCopy(src, dest);
    assert.strictEqual(fs.readFileSync(dest, 'utf8'), 'x');
    assert.strictEqual(fs.statSync(src).ino, fs.statSync(dest).ino);
  } finally { fs.rmSync(dir, { recursive: true }); }
});

test('hardLinkOrCopy copies when linking fails with EXDEV (different volume)', () => {
  const dir = tmp();
  try {
    const src = path.join(dir, 'a'); fs.writeFileSync(src, 'x');
    const dest = path.join(dir, 'b');
    hardLinkOrCopy(src, dest, () => { throw Object.assign(new Error('EXDEV'), { code: 'EXDEV' }); });
    assert.strictEqual(fs.readFileSync(dest, 'utf8'), 'x');
    assert.notStrictEqual(fs.statSync(src).ino, fs.statSync(dest).ino);
    fs.unlinkSync(dest);
    assert.ok(fs.existsSync(src), 'deleting the copy never touches the original');
  } finally { fs.rmSync(dir, { recursive: true }); }
});
