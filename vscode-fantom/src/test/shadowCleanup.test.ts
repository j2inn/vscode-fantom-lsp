/**
 * Unit tests for unlinkShadowLinks, linkOrCopyLibJava, and copyDirRecursive.
 *
 * No VS Code dependency — runs with plain Node.js after TypeScript compilation:
 *   node out/test/shadowCleanup.test.js
 */

import * as assert from 'assert';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { unlinkShadowLinks, linkOrCopyLibJava, copyDirRecursive } from '../shadowCleanup';

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void): void {
  try {
    fn();
    console.log(`  ✓ ${name}`);
    passed++;
  } catch (e: any) {
    console.error(`  ✗ ${name}`);
    console.error(`    ${e.message}`);
    failed++;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeTmpDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'shadow-test-'));
}

function writeFile(p: string, content = 'x'): void {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, content);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test('returns true and removes symlink at top level', () => {
  const shadowDir = makeTmpDir();
  const target = makeTmpDir();
  const link = path.join(shadowDir, 'link');
  try {
    fs.symlinkSync(target, link);
    const result = unlinkShadowLinks(shadowDir);
    assert.strictEqual(result, true, 'should return true');
    assert.ok(!fs.existsSync(link), 'symlink should be removed');
    assert.ok(fs.existsSync(target), 'target directory must not be deleted');
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
    try { fs.rmSync(target, { recursive: true }); } catch (_) {}
  }
});

test('returns true and removes symlink nested inside a real subdirectory', () => {
  const shadowDir = makeTmpDir();
  const target = makeTmpDir();
  const subDir = path.join(shadowDir, 'lib', 'java');
  fs.mkdirSync(subDir, { recursive: true });
  const link = path.join(subDir, 'link');
  try {
    fs.symlinkSync(target, link);
    const result = unlinkShadowLinks(shadowDir);
    assert.strictEqual(result, true, 'should return true');
    assert.ok(!fs.existsSync(link), 'nested symlink should be removed');
    assert.ok(fs.existsSync(target), 'target directory must not be deleted');
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
    try { fs.rmSync(target, { recursive: true }); } catch (_) {}
  }
});

test('does not remove regular files', () => {
  const shadowDir = makeTmpDir();
  const file = path.join(shadowDir, 'regular.txt');
  try {
    writeFile(file);
    unlinkShadowLinks(shadowDir);
    assert.ok(fs.existsSync(file), 'regular file must not be removed');
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
  }
});

test('returns true when there are no symlinks', () => {
  const shadowDir = makeTmpDir();
  const file = path.join(shadowDir, 'pod.pod');
  try {
    writeFile(file);
    const result = unlinkShadowLinks(shadowDir);
    assert.strictEqual(result, true);
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
  }
});

test('returns true for an empty directory', () => {
  const shadowDir = makeTmpDir();
  try {
    const result = unlinkShadowLinks(shadowDir);
    assert.strictEqual(result, true);
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
  }
});

test('returns true for a non-existent directory', () => {
  const result = unlinkShadowLinks(path.join(os.tmpdir(), 'does-not-exist-shadow-xyz'));
  assert.strictEqual(result, true);
});

test('target contents survive after symlink is removed', () => {
  const shadowDir = makeTmpDir();
  const target = makeTmpDir();
  const targetFile = path.join(target, 'sys.jar');
  writeFile(targetFile, 'jar-content');
  const link = path.join(shadowDir, 'lib-java-link');
  try {
    fs.symlinkSync(target, link);
    unlinkShadowLinks(shadowDir);
    assert.ok(!fs.existsSync(link), 'symlink should be gone');
    assert.ok(fs.existsSync(targetFile), 'sys.jar inside target must survive');
    assert.strictEqual(fs.readFileSync(targetFile, 'utf8'), 'jar-content');
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
    try { fs.rmSync(target, { recursive: true }); } catch (_) {}
  }
});

test('removes multiple symlinks and returns true', () => {
  const shadowDir = makeTmpDir();
  const t1 = makeTmpDir();
  const t2 = makeTmpDir();
  const l1 = path.join(shadowDir, 'link1');
  const l2 = path.join(shadowDir, 'link2');
  try {
    fs.symlinkSync(t1, l1);
    fs.symlinkSync(t2, l2);
    const result = unlinkShadowLinks(shadowDir);
    assert.strictEqual(result, true);
    assert.ok(!fs.existsSync(l1));
    assert.ok(!fs.existsSync(l2));
    assert.ok(fs.existsSync(t1), 'target 1 must survive');
    assert.ok(fs.existsSync(t2), 'target 2 must survive');
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
    try { fs.rmSync(t1, { recursive: true }); } catch (_) {}
    try { fs.rmSync(t2, { recursive: true }); } catch (_) {}
  }
});

// ---------------------------------------------------------------------------
// copyDirRecursive
// ---------------------------------------------------------------------------

test('copyDirRecursive copies files from a flat directory', () => {
  const src  = makeTmpDir();
  const dest = makeTmpDir();
  try {
    writeFile(path.join(src, 'sys.jar'), 'jar-bytes');
    writeFile(path.join(src, 'other.jar'), 'other-bytes');
    fs.rmSync(dest, { recursive: true });  // let copyDirRecursive create it
    copyDirRecursive(src, dest);
    assert.strictEqual(fs.readFileSync(path.join(dest, 'sys.jar'),   'utf8'), 'jar-bytes');
    assert.strictEqual(fs.readFileSync(path.join(dest, 'other.jar'), 'utf8'), 'other-bytes');
  } finally {
    try { fs.rmSync(src,  { recursive: true }); } catch (_) {}
    try { fs.rmSync(dest, { recursive: true }); } catch (_) {}
  }
});

test('copyDirRecursive copies nested subdirectories', () => {
  const src  = makeTmpDir();
  const dest = makeTmpDir();
  try {
    writeFile(path.join(src, 'sub', 'deep.txt'), 'deep');
    fs.rmSync(dest, { recursive: true });
    copyDirRecursive(src, dest);
    assert.strictEqual(fs.readFileSync(path.join(dest, 'sub', 'deep.txt'), 'utf8'), 'deep');
  } finally {
    try { fs.rmSync(src,  { recursive: true }); } catch (_) {}
    try { fs.rmSync(dest, { recursive: true }); } catch (_) {}
  }
});

test('copyDirRecursive does not modify the source', () => {
  const src  = makeTmpDir();
  const dest = makeTmpDir();
  try {
    writeFile(path.join(src, 'sys.jar'), 'original');
    fs.rmSync(dest, { recursive: true });
    copyDirRecursive(src, dest);
    assert.strictEqual(fs.readFileSync(path.join(src, 'sys.jar'), 'utf8'), 'original');
  } finally {
    try { fs.rmSync(src,  { recursive: true }); } catch (_) {}
    try { fs.rmSync(dest, { recursive: true }); } catch (_) {}
  }
});

// ---------------------------------------------------------------------------
// linkOrCopyLibJava — symlink/junction path
// ---------------------------------------------------------------------------

test('linkOrCopyLibJava creates a symlink/junction when possible', () => {
  const realLibJava   = makeTmpDir();
  const shadowLibJava = path.join(makeTmpDir(), 'lib', 'java');
  const shadowParent  = path.dirname(shadowLibJava);
  try {
    writeFile(path.join(realLibJava, 'sys.jar'), 'jar');
    fs.mkdirSync(shadowParent, { recursive: true });
    const logs: string[] = [];
    linkOrCopyLibJava(realLibJava, shadowLibJava, msg => logs.push(msg));
    // Whether a symlink or copy, sys.jar must be readable at the shadow path
    assert.ok(fs.existsSync(path.join(shadowLibJava, 'sys.jar')), 'sys.jar must be accessible');
    assert.ok(logs.length === 0, 'no fallback log expected when symlink succeeds');
  } finally {
    try { fs.rmSync(realLibJava,                      { recursive: true }); } catch (_) {}
    try { fs.rmSync(path.dirname(shadowParent),       { recursive: true }); } catch (_) {}
  }
});

// ---------------------------------------------------------------------------
// linkOrCopyLibJava — copy fallback path
// ---------------------------------------------------------------------------

test('linkOrCopyLibJava falls back to copy when symlink throws', () => {
  const realLibJava   = makeTmpDir();
  const shadowLibJava = path.join(makeTmpDir(), 'lib', 'java');
  const shadowParent  = path.dirname(shadowLibJava);
  try {
    writeFile(path.join(realLibJava, 'sys.jar'),  'jar-content');
    writeFile(path.join(realLibJava, 'other.jar'), 'other-content');
    fs.mkdirSync(shadowParent, { recursive: true });

    // Simulate junction failure by pre-creating the destination so symlinkSync throws.
    fs.mkdirSync(shadowLibJava, { recursive: true });

    const logs: string[] = [];
    linkOrCopyLibJava(realLibJava, shadowLibJava, msg => logs.push(msg));

    assert.ok(logs.some(l => l.includes('fallback')), 'fallback log message expected');
    assert.strictEqual(fs.readFileSync(path.join(shadowLibJava, 'sys.jar'),   'utf8'), 'jar-content');
    assert.strictEqual(fs.readFileSync(path.join(shadowLibJava, 'other.jar'), 'utf8'), 'other-content');

    // Source must be untouched
    assert.strictEqual(fs.readFileSync(path.join(realLibJava, 'sys.jar'), 'utf8'), 'jar-content');
  } finally {
    try { fs.rmSync(realLibJava,                { recursive: true }); } catch (_) {}
    try { fs.rmSync(path.dirname(shadowParent), { recursive: true }); } catch (_) {}
  }
});

test('linkOrCopyLibJava fallback does not delete source contents', () => {
  const realLibJava   = makeTmpDir();
  const shadowLibJava = path.join(makeTmpDir(), 'lib', 'java');
  const shadowParent  = path.dirname(shadowLibJava);
  try {
    writeFile(path.join(realLibJava, 'sys.jar'), 'precious');
    fs.mkdirSync(shadowParent, { recursive: true });
    // Force fallback
    fs.mkdirSync(shadowLibJava, { recursive: true });

    linkOrCopyLibJava(realLibJava, shadowLibJava, () => {});

    assert.strictEqual(fs.readFileSync(path.join(realLibJava, 'sys.jar'), 'utf8'), 'precious',
      'source sys.jar must be untouched after copy fallback');
  } finally {
    try { fs.rmSync(realLibJava,                { recursive: true }); } catch (_) {}
    try { fs.rmSync(path.dirname(shadowParent), { recursive: true }); } catch (_) {}
  }
});

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

console.log('\nShadowCleanup tests:');
console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) { process.exit(1); }
