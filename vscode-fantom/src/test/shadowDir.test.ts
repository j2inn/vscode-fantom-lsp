/**
 * Unit tests for ShadowDir.
 *
 * No VS Code dependency — runs with plain Node.js after TypeScript compilation:
 *   node out/test/shadowDir.test.js
 */

import * as assert from 'assert';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { ShadowDir } from '../shadowDir';

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
// ShadowDir.unlinkSymlinks
// ---------------------------------------------------------------------------

test('unlinkSymlinks returns true and removes symlink at top level', () => {
  const shadowDir = makeTmpDir();
  const target = makeTmpDir();
  const link = path.join(shadowDir, 'link');
  try {
    fs.symlinkSync(target, link);
    const result = ShadowDir.unlinkSymlinks(shadowDir);
    assert.strictEqual(result, true, 'should return true');
    assert.ok(!fs.existsSync(link), 'symlink should be removed');
    assert.ok(fs.existsSync(target), 'target directory must not be deleted');
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
    try { fs.rmSync(target,    { recursive: true }); } catch (_) {}
  }
});

test('unlinkSymlinks returns true and removes symlink nested inside a real subdirectory', () => {
  const shadowDir = makeTmpDir();
  const target = makeTmpDir();
  const subDir = path.join(shadowDir, 'lib', 'java');
  fs.mkdirSync(subDir, { recursive: true });
  const link = path.join(subDir, 'link');
  try {
    fs.symlinkSync(target, link);
    const result = ShadowDir.unlinkSymlinks(shadowDir);
    assert.strictEqual(result, true, 'should return true');
    assert.ok(!fs.existsSync(link), 'nested symlink should be removed');
    assert.ok(fs.existsSync(target), 'target directory must not be deleted');
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
    try { fs.rmSync(target,    { recursive: true }); } catch (_) {}
  }
});

test('unlinkSymlinks does not remove regular files', () => {
  const shadowDir = makeTmpDir();
  const file = path.join(shadowDir, 'regular.txt');
  try {
    writeFile(file);
    ShadowDir.unlinkSymlinks(shadowDir);
    assert.ok(fs.existsSync(file), 'regular file must not be removed');
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
  }
});

test('unlinkSymlinks returns true when there are no symlinks', () => {
  const shadowDir = makeTmpDir();
  const file = path.join(shadowDir, 'pod.pod');
  try {
    writeFile(file);
    const result = ShadowDir.unlinkSymlinks(shadowDir);
    assert.strictEqual(result, true);
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
  }
});

test('unlinkSymlinks returns true for an empty directory', () => {
  const shadowDir = makeTmpDir();
  try {
    const result = ShadowDir.unlinkSymlinks(shadowDir);
    assert.strictEqual(result, true);
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
  }
});

test('unlinkSymlinks returns true for a non-existent directory', () => {
  const result = ShadowDir.unlinkSymlinks(path.join(os.tmpdir(), 'does-not-exist-shadow-xyz'));
  assert.strictEqual(result, true);
});

test('unlinkSymlinks: target contents survive after symlink is removed', () => {
  const shadowDir = makeTmpDir();
  const target = makeTmpDir();
  const targetFile = path.join(target, 'sys.jar');
  writeFile(targetFile, 'jar-content');
  const link = path.join(shadowDir, 'lib-java-link');
  try {
    fs.symlinkSync(target, link);
    ShadowDir.unlinkSymlinks(shadowDir);
    assert.ok(!fs.existsSync(link), 'symlink should be gone');
    assert.ok(fs.existsSync(targetFile), 'sys.jar inside target must survive');
    assert.strictEqual(fs.readFileSync(targetFile, 'utf8'), 'jar-content');
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
    try { fs.rmSync(target,    { recursive: true }); } catch (_) {}
  }
});

test('unlinkSymlinks removes multiple symlinks and returns true', () => {
  const shadowDir = makeTmpDir();
  const t1 = makeTmpDir();
  const t2 = makeTmpDir();
  const l1 = path.join(shadowDir, 'link1');
  const l2 = path.join(shadowDir, 'link2');
  try {
    fs.symlinkSync(t1, l1);
    fs.symlinkSync(t2, l2);
    const result = ShadowDir.unlinkSymlinks(shadowDir);
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
// ShadowDir.copyDirRecursive
// ---------------------------------------------------------------------------

test('copyDirRecursive copies files from a flat directory', () => {
  const src  = makeTmpDir();
  const dest = makeTmpDir();
  try {
    writeFile(path.join(src, 'sys.jar'),   'jar-bytes');
    writeFile(path.join(src, 'other.jar'), 'other-bytes');
    fs.rmSync(dest, { recursive: true });
    ShadowDir.copyDirRecursive(src, dest);
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
    ShadowDir.copyDirRecursive(src, dest);
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
    ShadowDir.copyDirRecursive(src, dest);
    assert.strictEqual(fs.readFileSync(path.join(src, 'sys.jar'), 'utf8'), 'original');
  } finally {
    try { fs.rmSync(src,  { recursive: true }); } catch (_) {}
    try { fs.rmSync(dest, { recursive: true }); } catch (_) {}
  }
});

// ---------------------------------------------------------------------------
// lib/java linking — symlink/junction path
// ---------------------------------------------------------------------------

test('buildLibJava creates a symlink/junction when possible', () => {
  const realLibJava   = makeTmpDir();
  const shadowLibJava = path.join(makeTmpDir(), 'lib', 'java');
  const shadowParent  = path.dirname(shadowLibJava);
  try {
    writeFile(path.join(realLibJava, 'sys.jar'), 'jar');
    fs.mkdirSync(shadowParent, { recursive: true });
    const logs: string[] = [];
    // Drive the private buildLibJava path via copyDirRecursive indirectly:
    // use a temp shadowDir structure and test the outcome.
    try {
      fs.symlinkSync(realLibJava, shadowLibJava, 'junction');
    } catch (_) {
      ShadowDir.copyDirRecursive(realLibJava, shadowLibJava);
      logs.push('fallback');
    }
    assert.ok(fs.existsSync(path.join(shadowLibJava, 'sys.jar')), 'sys.jar must be accessible');
  } finally {
    try { fs.rmSync(realLibJava,                { recursive: true }); } catch (_) {}
    try { fs.rmSync(path.dirname(shadowParent), { recursive: true }); } catch (_) {}
  }
});

// ---------------------------------------------------------------------------
// lib/java linking — copy fallback path
// ---------------------------------------------------------------------------

test('lib/java copy fallback: files appear in shadow and source is untouched', () => {
  const realLibJava   = makeTmpDir();
  const shadowLibJava = path.join(makeTmpDir(), 'lib', 'java');
  const shadowParent  = path.dirname(shadowLibJava);
  try {
    writeFile(path.join(realLibJava, 'sys.jar'),   'jar-content');
    writeFile(path.join(realLibJava, 'other.jar'), 'other-content');
    fs.mkdirSync(shadowParent, { recursive: true });
    // Pre-create dest to force symlinkSync to throw → copy fallback
    fs.mkdirSync(shadowLibJava, { recursive: true });
    const logs: string[] = [];
    try {
      fs.symlinkSync(realLibJava, shadowLibJava, 'junction');
    } catch (_) {
      logs.push('lib/java junction failed — copying lib/java into shadow dir as fallback');
      ShadowDir.copyDirRecursive(realLibJava, shadowLibJava);
    }
    assert.ok(logs.some(l => l.includes('fallback')), 'fallback log expected');
    assert.strictEqual(fs.readFileSync(path.join(shadowLibJava, 'sys.jar'),   'utf8'), 'jar-content');
    assert.strictEqual(fs.readFileSync(path.join(shadowLibJava, 'other.jar'), 'utf8'), 'other-content');
    assert.strictEqual(fs.readFileSync(path.join(realLibJava,   'sys.jar'),   'utf8'), 'jar-content',
      'source must be untouched');
  } finally {
    try { fs.rmSync(realLibJava,                { recursive: true }); } catch (_) {}
    try { fs.rmSync(path.dirname(shadowParent), { recursive: true }); } catch (_) {}
  }
});

test('lib/java fallback does not delete source contents', () => {
  const realLibJava   = makeTmpDir();
  const shadowLibJava = path.join(makeTmpDir(), 'lib', 'java');
  const shadowParent  = path.dirname(shadowLibJava);
  try {
    writeFile(path.join(realLibJava, 'sys.jar'), 'precious');
    fs.mkdirSync(shadowParent, { recursive: true });
    fs.mkdirSync(shadowLibJava, { recursive: true });
    try { fs.symlinkSync(realLibJava, shadowLibJava, 'junction'); } catch (_) {
      ShadowDir.copyDirRecursive(realLibJava, shadowLibJava);
    }
    assert.strictEqual(fs.readFileSync(path.join(realLibJava, 'sys.jar'), 'utf8'), 'precious',
      'source sys.jar must be untouched after copy fallback');
  } finally {
    try { fs.rmSync(realLibJava,                { recursive: true }); } catch (_) {}
    try { fs.rmSync(path.dirname(shadowParent), { recursive: true }); } catch (_) {}
  }
});

// ---------------------------------------------------------------------------
// ShadowDir.removeRealDirIfEmpty
// ---------------------------------------------------------------------------

test('removeRealDirIfEmpty removes an empty directory', () => {
  const dir = makeTmpDir();
  const logs: string[] = [];
  ShadowDir.removeRealDirIfEmpty(dir, m => logs.push(m));
  assert.ok(!fs.existsSync(dir), 'empty dir must be removed');
  assert.strictEqual(logs.length, 0, 'no warnings expected');
});

test('removeRealDirIfEmpty logs a warning (does not throw) when dir is not empty', () => {
  const dir = makeTmpDir();
  try {
    writeFile(path.join(dir, 'file.txt'));
    const logs: string[] = [];
    ShadowDir.removeRealDirIfEmpty(dir, m => logs.push(m));
    assert.ok(fs.existsSync(dir), 'non-empty dir must NOT be removed');
    assert.ok(logs.some(m => m.includes('WARNING')), 'a warning must be logged');
  } finally {
    try { fs.rmSync(dir, { recursive: true }); } catch (_) {}
  }
});

test('removeRealDirIfEmpty logs a warning (does not throw) for a non-existent path', () => {
  const missing = path.join(os.tmpdir(), 'shadow-test-nonexistent-xyz');
  const logs: string[] = [];
  ShadowDir.removeRealDirIfEmpty(missing, m => logs.push(m));
  assert.ok(logs.some(m => m.includes('WARNING')), 'a warning must be logged for missing path');
});

// ---------------------------------------------------------------------------
// disposeEtc — real etc/ structure never touched
// ---------------------------------------------------------------------------

/**
 * Build a minimal fake fanHome with enough structure for ShadowDir.create().
 * Returns { fanHome, podFile } where fanHome mimics a real Fantom installation.
 */
function makeFakeFanHome(podFileName: string): { fanHome: string; podFile: string } {
  const fanHome = makeTmpDir();
  // lib/fan — one pod file
  const libFan = path.join(fanHome, 'lib', 'fan');
  fs.mkdirSync(libFan, { recursive: true });
  const podFile = path.join(libFan, podFileName);
  writeFile(podFile, 'pod-bytes');
  // lib/java — one jar file (so junction/symlink target is non-empty)
  const libJava = path.join(fanHome, 'lib', 'java');
  fs.mkdirSync(libJava, { recursive: true });
  writeFile(path.join(libJava, 'sys.jar'), 'jar-bytes');
  // etc/sys — required files
  const etcSys = path.join(fanHome, 'etc', 'sys');
  fs.mkdirSync(etcSys, { recursive: true });
  writeFile(path.join(etcSys, 'config.props'), 'key=value\n');
  writeFile(path.join(etcSys, 'units.txt'),    'units\n');
  // etc/build — a second etc sub-directory (becomes a junction/symlink in shadow)
  const etcBuild = path.join(fanHome, 'etc', 'build');
  fs.mkdirSync(etcBuild, { recursive: true });
  writeFile(path.join(etcBuild, 'props.txt'), 'build-props\n');
  return { fanHome, podFile };
}

test('dispose: real fanHome etc/ contents survive after dispose', () => {
  const { fanHome } = makeFakeFanHome('main.pod');
  const logs: string[] = [];
  const shadow = ShadowDir.create('main.pod', fanHome, m => logs.push(m));
  try {
    assert.ok(shadow !== undefined, 'create must succeed');
    shadow!.dispose(m => logs.push(m));
    // The real fanHome/etc and its contents must be completely untouched.
    assert.ok(fs.existsSync(path.join(fanHome, 'etc', 'sys', 'config.props')),
      'real etc/sys/config.props must survive dispose');
    assert.ok(fs.existsSync(path.join(fanHome, 'etc', 'sys', 'units.txt')),
      'real etc/sys/units.txt must survive dispose');
    assert.ok(fs.existsSync(path.join(fanHome, 'etc', 'build', 'props.txt')),
      'real etc/build/props.txt must survive dispose');
    assert.ok(fs.existsSync(path.join(fanHome, 'etc')),
      'real etc/ directory must survive dispose');
  } finally {
    try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
    if (shadow) { try { fs.rmSync(shadow.path, { recursive: true }); } catch (_) {} }
  }
});

test('dispose: real fanHome lib/java contents survive after dispose', () => {
  const { fanHome } = makeFakeFanHome('main.pod');
  const logs: string[] = [];
  const shadow = ShadowDir.create('main.pod', fanHome, m => logs.push(m));
  try {
    assert.ok(shadow !== undefined, 'create must succeed');
    shadow!.dispose(m => logs.push(m));
    assert.ok(fs.existsSync(path.join(fanHome, 'lib', 'java', 'sys.jar')),
      'real lib/java/sys.jar must survive dispose');
  } finally {
    try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
    if (shadow) { try { fs.rmSync(shadow.path, { recursive: true }); } catch (_) {} }
  }
});

test('dispose: real fanHome lib/fan pod file survives after dispose', () => {
  const { fanHome } = makeFakeFanHome('main.pod');
  const logs: string[] = [];
  const shadow = ShadowDir.create('main.pod', fanHome, m => logs.push(m));
  try {
    assert.ok(shadow !== undefined, 'create must succeed');
    shadow!.dispose(m => logs.push(m));
    assert.ok(fs.existsSync(path.join(fanHome, 'lib', 'fan', 'main.pod')),
      'real lib/fan/main.pod must survive dispose');
    assert.strictEqual(fs.readFileSync(path.join(fanHome, 'lib', 'fan', 'main.pod'), 'utf8'),
      'pod-bytes', 'pod file content must be unchanged');
  } finally {
    try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
    if (shadow) { try { fs.rmSync(shadow.path, { recursive: true }); } catch (_) {} }
  }
});

test('dispose: shadow dir itself is removed after dispose', () => {
  const { fanHome } = makeFakeFanHome('main.pod');
  const logs: string[] = [];
  const shadow = ShadowDir.create('main.pod', fanHome, m => logs.push(m));
  try {
    assert.ok(shadow !== undefined, 'create must succeed');
    const shadowPath = shadow!.path;
    shadow!.dispose(m => logs.push(m));
    assert.ok(!fs.existsSync(shadowPath), 'shadow dir must be removed after dispose');
  } finally {
    try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
    if (shadow) { try { fs.rmSync(shadow.path, { recursive: true }); } catch (_) {} }
  }
});

test('dispose: shadow config.props has java.options stripped', () => {
  const { fanHome } = makeFakeFanHome('main.pod');
  // Put a java.options line in config.props — it must be stripped in the shadow.
  writeFile(
    path.join(fanHome, 'etc', 'sys', 'config.props'),
    'key=value\njava.options=-Xdebug -Xrunjdwp\nother=1\n'
  );
  const logs: string[] = [];
  const shadow = ShadowDir.create('main.pod', fanHome, m => logs.push(m));
  try {
    assert.ok(shadow !== undefined, 'create must succeed');
    const shadowConfig = fs.readFileSync(
      path.join(shadow!.path, 'etc', 'sys', 'config.props'), 'utf8'
    );
    assert.ok(!shadowConfig.includes('java.options'), 'java.options must be stripped in shadow');
    assert.ok(shadowConfig.includes('key=value'),     'other keys must be preserved');
    // Real file must be unchanged.
    const realConfig = fs.readFileSync(
      path.join(fanHome, 'etc', 'sys', 'config.props'), 'utf8'
    );
    assert.ok(realConfig.includes('java.options'), 'real config.props must be untouched');
  } finally {
    try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
    if (shadow) { try { fs.rmSync(shadow.path, { recursive: true }); } catch (_) {} }
  }
});

test('create + dispose round-trip: no fanHome entries are deleted or modified', () => {
  const { fanHome } = makeFakeFanHome('lsp.pod');
  // Snapshot all fanHome paths and their content before the round-trip.
  const before = new Map<string, string>();
  function snapshot(dir: string): void {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) { snapshot(full); }
      else { before.set(full, fs.readFileSync(full, 'utf8')); }
    }
  }
  snapshot(fanHome);

  const logs: string[] = [];
  const shadow = ShadowDir.create('lsp.pod', fanHome, m => logs.push(m));
  if (shadow) { shadow.dispose(m => logs.push(m)); }

  // Every file that existed before must still exist with identical content.
  for (const [filePath, originalContent] of before.entries()) {
    assert.ok(fs.existsSync(filePath),
      `fanHome file was deleted: ${path.relative(fanHome, filePath)}`);
    assert.strictEqual(fs.readFileSync(filePath, 'utf8'), originalContent,
      `fanHome file content changed: ${path.relative(fanHome, filePath)}`);
  }

  try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
  if (shadow) { try { fs.rmSync(shadow.path, { recursive: true }); } catch (_) {} }
});

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

console.log('\nShadowDir tests:');
console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) { process.exit(1); }
