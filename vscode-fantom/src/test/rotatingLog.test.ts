import * as assert from 'assert';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { RotatingLog } from '../rotatingLog';

function test(name: string, fn: () => void): void {
  try { fn(); console.log(`  ✓ ${name}`); } catch (e) {
    console.error(`  ✗ ${name}`); console.error(e); process.exitCode = 1;
  }
}

function tmpFile(): { dir: string; file: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rotlog-'));
  return { dir, file: path.join(dir, 'x.log') };
}

test('appends lines to one file below the limit', () => {
  const { dir, file } = tmpFile();
  try {
    const log = new RotatingLog(file, 1000, 2);
    log.append('a'); log.append('b');
    assert.strictEqual(fs.readFileSync(file, 'utf8'), 'a\nb\n');
    assert.ok(!fs.existsSync(file + '.1'));
  } finally { fs.rmSync(dir, { recursive: true }); }
});

test('rotates when the limit is exceeded and keeps the newest line active', () => {
  const { dir, file } = tmpFile();
  try {
    const log = new RotatingLog(file, 20, 2);
    log.append('0123456789'); // 11 bytes
    log.append('abcdefghij'); // would reach 22 > 20 -> rotate
    assert.strictEqual(fs.readFileSync(file + '.1', 'utf8'), '0123456789\n');
    assert.strictEqual(fs.readFileSync(file, 'utf8'), 'abcdefghij\n');
  } finally { fs.rmSync(dir, { recursive: true }); }
});

test('never keeps more than `keep` rotated files, so disk use is bounded', () => {
  const { dir, file } = tmpFile();
  try {
    const log = new RotatingLog(file, 20, 2);
    for (let i = 0; i < 50; i++) { log.append('line-number-' + i); }
    const files = fs.readdirSync(dir).sort();
    assert.deepStrictEqual(files, ['x.log', 'x.log.1', 'x.log.2']);
    for (const f of files) { assert.ok(fs.statSync(path.join(dir, f)).size <= 40); }
    assert.ok(fs.readFileSync(file, 'utf8').includes('line-number-49'));
  } finally { fs.rmSync(dir, { recursive: true }); }
});

test('an existing large file is rotated on the first append after restart', () => {
  const { dir, file } = tmpFile();
  try {
    fs.writeFileSync(file, 'x'.repeat(100));
    const log = new RotatingLog(file, 50, 1);
    log.append('new');
    assert.strictEqual(fs.readFileSync(file, 'utf8'), 'new\n');
    assert.strictEqual(fs.statSync(file + '.1').size, 100);
  } finally { fs.rmSync(dir, { recursive: true }); }
});

test('append never throws when the directory is missing', () => {
  const log = new RotatingLog(path.join(os.tmpdir(), 'no-such-dir-xyz', 'x.log'));
  log.append('ignored');
});
