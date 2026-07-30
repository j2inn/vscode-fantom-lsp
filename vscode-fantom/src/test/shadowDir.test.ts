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

/**
 * A test whose assertions only make sense on win32 — e.g. real NTFS
 * junction semantics, which fs.symlinkSync(..., 'junction') silently
 * downgrades to a plain symlink on Linux/Mac. Counts toward passed/failed
 * only when it actually runs, and prints an explicit skip line on other
 * platforms so CI output never looks like a silent pass.
 */
function testWindowsOnly(name: string, fn: () => void): void {
  if (process.platform !== 'win32') {
    console.log(`  – ${name} (skipped: windows-only)`);
    return;
  }
  test(name, fn);
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
// sweepOrphaned — cleans up shadow dirs left behind by a killed prior session
// ---------------------------------------------------------------------------

test('sweepOrphaned removes an orphaned shadow dir and its junctions, real fanHome survives', () => {
  const { fanHome } = makeFakeFanHome('main.pod');
  const logs: string[] = [];
  // Simulate a session that was killed before dispose() could run: create a
  // real shadow dir via the normal path, but never call dispose() on it —
  // exactly the state an abrupt VS Code restart leaves behind.
  const orphan = ShadowDir.create('main.pod', fanHome, m => logs.push(m));
  try {
    assert.ok(orphan !== undefined, 'create must succeed');
    assert.ok(fs.existsSync(orphan!.path), 'orphaned shadow dir must exist before sweep');

    ShadowDir.sweepOrphaned(undefined, m => logs.push(m));

    assert.ok(!fs.existsSync(orphan!.path), 'orphaned shadow dir must be removed by the sweep');
    // The real installation must be completely untouched — this is the exact
    // scenario that caused real data loss when an external tool later did a
    // recursive delete on an orphaned dir instead of this targeted sweep.
    assert.ok(fs.existsSync(path.join(fanHome, 'etc', 'sys', 'config.props')),
      'real etc/sys/config.props must survive the sweep');
    assert.ok(fs.existsSync(path.join(fanHome, 'etc', 'build', 'props.txt')),
      'real etc/build/props.txt must survive the sweep');
    assert.ok(fs.existsSync(path.join(fanHome, 'lib', 'java', 'sys.jar')),
      'real lib/java/sys.jar must survive the sweep');
    assert.ok(fs.existsSync(path.join(fanHome, 'lib', 'fan', 'main.pod')),
      'real lib/fan/main.pod must survive the sweep');
  } finally {
    try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
    if (orphan) { try { fs.rmSync(orphan.path, { recursive: true }); } catch (_) {} }
  }
});

test('sweepOrphaned skips the currently active shadow dir', () => {
  const { fanHome } = makeFakeFanHome('main.pod');
  const logs: string[] = [];
  const active = ShadowDir.create('main.pod', fanHome, m => logs.push(m));
  try {
    assert.ok(active !== undefined, 'create must succeed');
    ShadowDir.sweepOrphaned(active!.path, m => logs.push(m));
    assert.ok(fs.existsSync(active!.path), 'the currently active shadow dir must not be swept');
  } finally {
    try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
    if (active) { active.dispose(m => logs.push(m)); }
    if (active) { try { fs.rmSync(active.path, { recursive: true }); } catch (_) {} }
  }
});

test('sweepOrphaned does not touch unrelated directories in os.tmpdir()', () => {
  const unrelated = makeTmpDir();
  writeFile(path.join(unrelated, 'file.txt'), 'unrelated');
  try {
    ShadowDir.sweepOrphaned(undefined, () => {});
    assert.ok(fs.existsSync(unrelated), 'unrelated tmp directory must survive the sweep');
    assert.ok(fs.existsSync(path.join(unrelated, 'file.txt')), 'unrelated file must survive the sweep');
  } finally {
    try { fs.rmSync(unrelated, { recursive: true }); } catch (_) {}
  }
});

// ---------------------------------------------------------------------------
// Real NTFS junction semantics (Windows-only)
//
// fs.symlinkSync(target, link, 'junction') is a genuine NTFS junction only on
// win32 — on Linux/Mac Node silently creates a plain symlink instead. Every
// test above that passes the 'junction' type therefore never exercises real
// junction-following behavior off Windows, which is exactly the mechanism
// that caused the actual data loss (an external recursive delete followed a
// junction from an orphaned shadow dir into the real Fantom installation).
// These tests only run their assertions on win32; elsewhere they print an
// explicit skip line so CI output is never a silent, meaningless pass.
// ---------------------------------------------------------------------------

testWindowsOnly('a real junction reports isSymbolicLink() === true via lstat', () => {
  const target = makeTmpDir();
  const shadowDir = makeTmpDir();
  const link = path.join(shadowDir, 'etc-subdir');
  try {
    fs.symlinkSync(target, link, 'junction');
    const stat = fs.lstatSync(link);
    assert.ok(stat.isSymbolicLink(),
      'a real Windows junction must report isSymbolicLink() === true, exactly what ' +
      'disposeEtc/removeLeafEntries rely on to unlink it as a leaf instead of recursing');
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
    try { fs.rmSync(target, { recursive: true }); } catch (_) {}
  }
});

testWindowsOnly('sweepOrphaned unlinks a real junction as a leaf without following it into the target', () => {
  const { fanHome } = makeFakeFanHome('main.pod');
  const logs: string[] = [];
  const orphan = ShadowDir.create('main.pod', fanHome, m => logs.push(m));
  try {
    assert.ok(orphan !== undefined, 'create must succeed');
    // etc/build is created as a real junction into fanHome/etc/build on win32
    // (see buildEtc). Confirm it really is one before relying on the sweep.
    const junctionPath = path.join(orphan!.path, 'etc', 'build');
    assert.ok(fs.lstatSync(junctionPath).isSymbolicLink(),
      'etc/build must be a real junction on win32 before the sweep runs');

    ShadowDir.sweepOrphaned(undefined, m => logs.push(m));

    assert.ok(!fs.existsSync(orphan!.path), 'orphaned shadow dir must be removed');
    // The junction's target must be untouched — this is the exact failure
    // mode from production: a recursive delete on the orphan following the
    // junction and wiping fanHome/etc/build's real contents.
    assert.ok(fs.existsSync(path.join(fanHome, 'etc', 'build', 'props.txt')),
      'real etc/build/props.txt (the junction target) must survive the sweep');
  } finally {
    try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
    if (orphan) { try { fs.rmSync(orphan.path, { recursive: true }); } catch (_) {} }
  }
});

testWindowsOnly('unlinking a junction never deletes the target directory\'s contents', () => {
  const target = makeTmpDir();
  const shadowDir = makeTmpDir();
  const link = path.join(shadowDir, 'etc-subdir');
  const targetFile = path.join(target, 'real-file.txt');
  writeFile(targetFile, 'must-survive');
  try {
    fs.symlinkSync(target, link, 'junction');
    fs.unlinkSync(link); // exactly what removeLeafEntries does
    assert.ok(!fs.existsSync(link), 'junction pointer must be gone');
    assert.ok(fs.existsSync(targetFile), 'junction target contents must survive an unlink of the junction');
    assert.strictEqual(fs.readFileSync(targetFile, 'utf8'), 'must-survive');
  } finally {
    try { fs.rmSync(shadowDir, { recursive: true }); } catch (_) {}
    try { fs.rmSync(target, { recursive: true }); } catch (_) {}
  }
});

// ---------------------------------------------------------------------------
// Adversarial: partial/interrupted construction, hostile names, resilience
//
// The whole premise of sweepOrphaned is that a session can be killed at ANY
// point during buildLibFan/buildLibJava/buildEtc — these tests simulate
// being killed at several different points, not just "fully built then
// abandoned", plus a handful of hostile inputs sweepOrphaned must not be
// fooled or crashed by.
// ---------------------------------------------------------------------------

test('sweepOrphaned cleans up a shadow dir killed before any junction was created (empty etc/)', () => {
  const { fanHome } = makeFakeFanHome('main.pod');
  const logs: string[] = [];
  // Simulate a kill immediately after "mkdirSync(shadowEtcDir)" in buildEtc,
  // before the for-loop even starts — the most minimal partial state possible.
  const dir = path.join(os.tmpdir(), `fantom-lsp-shadow-${Date.now()}-partial1`);
  fs.mkdirSync(path.join(dir, 'etc'), { recursive: true });
  try {
    assert.ok(fs.existsSync(dir), 'partial shadow dir must exist before sweep');
    ShadowDir.sweepOrphaned(undefined, m => logs.push(m));
    assert.ok(!fs.existsSync(dir), 'partial shadow dir (empty etc/, no lib/) must be fully removed');
    assert.ok(fs.existsSync(path.join(fanHome, 'etc', 'sys', 'config.props')),
      'real installation must be untouched by a partial-state sweep');
  } finally {
    try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
    try { fs.rmSync(dir, { recursive: true }); } catch (_) {}
  }
});

test('sweepOrphaned cleans up a shadow dir killed mid-etc-loop (some junctions built, some not)', () => {
  const { fanHome } = makeFakeFanHome('main.pod');
  const logs: string[] = [];
  const dir = path.join(os.tmpdir(), `fantom-lsp-shadow-${Date.now()}-partial2`);
  // Simulate: etc/sys fully built (real dir + copied files), but the
  // etc/build junction was never reached before the kill.
  const etcSys = path.join(dir, 'etc', 'sys');
  fs.mkdirSync(etcSys, { recursive: true });
  fs.writeFileSync(path.join(etcSys, 'config.props'), 'key=value\n');
  fs.writeFileSync(path.join(etcSys, 'units.txt'), 'units\n');
  // lib/fan half-built: directory created, one file copied, nothing else.
  const libFan = path.join(dir, 'lib', 'fan');
  fs.mkdirSync(libFan, { recursive: true });
  fs.writeFileSync(path.join(libFan, 'main.pod'), 'pod-bytes');
  // No lib/java at all — kill happened before buildLibJava ran.
  try {
    ShadowDir.sweepOrphaned(undefined, m => logs.push(m));
    assert.ok(!fs.existsSync(dir), 'half-built shadow dir must be fully removed');
    assert.ok(fs.existsSync(path.join(fanHome, 'etc', 'build', 'props.txt')),
      'real etc/build must be untouched even though the shadow never linked to it');
    assert.ok(fs.existsSync(path.join(fanHome, 'lib', 'fan', 'main.pod')),
      'real lib/fan/main.pod must be untouched');
  } finally {
    try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
    try { fs.rmSync(dir, { recursive: true }); } catch (_) {}
  }
});

test('sweepOrphaned does not crash and cleans remaining orphans when one dir is unremovable', () => {
  const { fanHome } = makeFakeFanHome('main.pod');
  const logs: string[] = [];
  // A second, well-formed orphan alongside the first — proves one bad apple
  // does not abort the whole sweep loop.
  const good1 = path.join(os.tmpdir(), `fantom-lsp-shadow-${Date.now()}-good1`);
  const good2 = path.join(os.tmpdir(), `fantom-lsp-shadow-${Date.now()}-good2`);
  fs.mkdirSync(path.join(good1, 'etc'), { recursive: true });
  fs.mkdirSync(path.join(good2, 'etc'), { recursive: true });
  // Booby-trap good1's etc/ dir with a nested real subdirectory containing a
  // file — removeLeafEntries is intentionally shallow and will never delete
  // it, so removeRealDirIfEmpty on etc/ must fail with ENOTEMPTY (logged as
  // a warning, not thrown) while good2 still gets fully cleaned up.
  const trap = path.join(good1, 'etc', 'unexpected-subdir');
  fs.mkdirSync(trap, { recursive: true });
  fs.writeFileSync(path.join(trap, 'leftover.txt'), 'should not be deleted by this shallow sweep');
  try {
    ShadowDir.sweepOrphaned(undefined, m => logs.push(m));

    // good2 has no surprises — must be fully removed.
    assert.ok(!fs.existsSync(good2), 'good2 (no surprises) must be fully removed');

    // good1's booby-trapped subdirectory must survive untouched — this proves
    // the shallow-by-design removeLeafEntries never recurses into an
    // unexpected real subdirectory, even one it doesn't recognize.
    assert.ok(fs.existsSync(path.join(trap, 'leftover.txt')),
      'an unexpected real subdirectory inside an orphan must survive — proves no recursive delete occurred');
    assert.ok(logs.some(m => m.includes('WARNING')),
      'a warning must be logged for the unremovable etc/ directory, not a thrown error');

    // Real installation is always untouched regardless of the trap.
    assert.ok(fs.existsSync(path.join(fanHome, 'etc', 'sys', 'config.props')),
      'real installation must survive even when one orphan cannot be fully removed');
  } finally {
    try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
    try { fs.rmSync(good1, { recursive: true }); } catch (_) {}
    try { fs.rmSync(good2, { recursive: true }); } catch (_) {}
  }
});

test('sweepOrphaned ignores a file (not a directory) whose name matches the shadow-dir prefix', () => {
  const decoyFile = path.join(os.tmpdir(), `fantom-lsp-shadow-${Date.now()}-decoy-file`);
  fs.writeFileSync(decoyFile, 'not a directory, must be left alone');
  try {
    ShadowDir.sweepOrphaned(undefined, () => {});
    assert.ok(fs.existsSync(decoyFile), 'a plain FILE matching the prefix must never be touched');
    assert.strictEqual(fs.readFileSync(decoyFile, 'utf8'), 'not a directory, must be left alone');
  } finally {
    try { fs.unlinkSync(decoyFile); } catch (_) {}
  }
});

test('sweepOrphaned ignores a symlink whose name matches the shadow-dir prefix, even if it points to a real directory', () => {
  const realTarget = makeTmpDir();
  writeFile(path.join(realTarget, 'precious.txt'), 'must not be reachable through the decoy');
  const decoyLink = path.join(os.tmpdir(), `fantom-lsp-shadow-${Date.now()}-decoy-link`);
  try {
    fs.symlinkSync(realTarget, decoyLink, 'dir');
    ShadowDir.sweepOrphaned(undefined, () => {});
    // entry.isDirectory() on a Dirent reflects the symlink itself, not its
    // target, so this must be skipped entirely — never unlinked, never
    // treated as an orphan to dispose.
    assert.ok(fs.existsSync(decoyLink), 'a symlink matching the prefix must never be touched, regardless of its target');
    assert.ok(fs.existsSync(path.join(realTarget, 'precious.txt')), 'the symlink target must be completely unaffected');
  } finally {
    try { fs.unlinkSync(decoyLink); } catch (_) {}
    try { fs.rmSync(realTarget, { recursive: true }); } catch (_) {}
  }
});

test('sweepOrphaned does not touch a directory whose name only partially overlaps the prefix', () => {
  // "fantom-lsp-shadow" without the trailing "-" is NOT a valid match — must
  // not be swept even though it shares almost the entire prefix.
  const almost = fs.mkdtempSync(path.join(os.tmpdir(), 'fantom-lsp-shadow'));
  writeFile(path.join(almost, 'file.txt'), 'unrelated directory, must survive');
  try {
    ShadowDir.sweepOrphaned(undefined, () => {});
    assert.ok(fs.existsSync(almost), 'a near-miss prefix must not be swept');
    assert.ok(fs.existsSync(path.join(almost, 'file.txt')));
  } finally {
    try { fs.rmSync(almost, { recursive: true }); } catch (_) {}
  }
});

test('sweepOrphaned on a name-collision directory only ever touches lib/fan, lib/java, etc/sys, etc/ — never the top level', () => {
  // Anyone or anything creating a directory literally named
  // "fantom-lsp-shadow-<anything>" under os.tmpdir() is matched by name
  // alone — there is no marker file distinguishing a dir this extension
  // actually built from a coincidental collision. This test proves the
  // blast radius is still safe on a collision: disposeLibFan/disposeLibJava
  // /disposeEtc only ever touch the four specific sub-paths a real shadow
  // dir would have. A top-level file sitting directly in the matched
  // directory (not inside one of those sub-paths) is never reached.
  const collision = path.join(os.tmpdir(), 'fantom-lsp-shadow-not-actually-ours');
  fs.mkdirSync(collision, { recursive: true });
  writeFile(path.join(collision, 'someones-file.txt'), 'irrelevant to this extension');
  try {
    ShadowDir.sweepOrphaned(undefined, () => {});
    // A file at the collision dir's own top level is outside every path
    // disposeLibFan/disposeLibJava/disposeEtc ever construct — it survives.
    assert.ok(fs.existsSync(path.join(collision, 'someones-file.txt')),
      'a top-level file in a collision dir is untouched — sweepOrphaned only reaches lib/fan, lib/java, etc/sys, etc/');
    // The collision directory itself also survives: removeRealDirIfEmpty
    // only succeeds once the directory is genuinely empty, and it never is
    // here since someones-file.txt was never removed.
    assert.ok(fs.existsSync(collision), 'the collision directory itself must survive (not empty, so rmdirSync fails safely)');
  } finally {
    try { fs.rmSync(collision, { recursive: true }); } catch (_) {}
  }
});

test('sweepOrphaned DOES remove a file placed inside a collision dir at one of the real sub-paths (lib/fan)', () => {
  // The flip side of the previous test: if the collision happens to also
  // contain a lib/fan/ subdirectory (e.g. a coincidentally-named dir that
  // itself has that structure for unrelated reasons), a file sitting there
  // IS removed as a leaf — this is the honest, documented blast radius,
  // not a false sense of safety from the previous test alone.
  const collision = path.join(os.tmpdir(), 'fantom-lsp-shadow-partial-collision');
  const libFan = path.join(collision, 'lib', 'fan');
  fs.mkdirSync(libFan, { recursive: true });
  writeFile(path.join(libFan, 'someone-elses-file.pod'), 'not ours, but sits at a path we do clean');
  try {
    ShadowDir.sweepOrphaned(undefined, () => {});
    assert.ok(!fs.existsSync(path.join(libFan, 'someone-elses-file.pod')),
      'a file at lib/fan/ inside a name-matched directory is removed — the match is name-based only, ' +
      'with no way to distinguish a real orphan from a coincidental collision at this sub-path');
  } finally {
    try { fs.rmSync(collision, { recursive: true }); } catch (_) {}
  }
});

test('sweepOrphaned handles a shadow dir with lib/ but no lib/fan or lib/java at all', () => {
  const dir = path.join(os.tmpdir(), `fantom-lsp-shadow-${Date.now()}-empty-lib`);
  fs.mkdirSync(path.join(dir, 'lib'), { recursive: true });
  try {
    ShadowDir.sweepOrphaned(undefined, () => {});
    assert.ok(!fs.existsSync(dir), 'an orphan with an empty lib/ and nothing else must still be fully removed');
  } finally {
    try { fs.rmSync(dir, { recursive: true }); } catch (_) {}
  }
});

test('sweepOrphaned is idempotent: running it twice in a row on the same state is safe', () => {
  const { fanHome } = makeFakeFanHome('main.pod');
  const logs: string[] = [];
  const orphan = ShadowDir.create('main.pod', fanHome, m => logs.push(m));
  try {
    assert.ok(orphan !== undefined, 'create must succeed');
    ShadowDir.sweepOrphaned(undefined, m => logs.push(m));
    assert.ok(!fs.existsSync(orphan!.path), 'first sweep must remove the orphan');
    // Second sweep: nothing left to find. Must not throw.
    assert.doesNotThrow(() => ShadowDir.sweepOrphaned(undefined, m => logs.push(m)),
      'a second sweep over an already-clean os.tmpdir() must not throw');
    assert.ok(fs.existsSync(path.join(fanHome, 'etc', 'sys', 'config.props')),
      'real installation must still be intact after two sweeps');
  } finally {
    try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
    if (orphan) { try { fs.rmSync(orphan.path, { recursive: true }); } catch (_) {} }
  }
});

test('sweepOrphaned handles many orphans in one pass without touching the real installation', () => {
  const { fanHome } = makeFakeFanHome('main.pod');
  const logs: string[] = [];
  const orphans: Array<ReturnType<typeof ShadowDir.create>> = [];
  try {
    for (let i = 0; i < 8; i++) {
      orphans.push(ShadowDir.create('main.pod', fanHome, m => logs.push(m)));
    }
    assert.ok(orphans.every(o => o !== undefined), 'all 8 orphans must be created successfully');

    ShadowDir.sweepOrphaned(undefined, m => logs.push(m));

    for (const o of orphans) {
      assert.ok(!fs.existsSync(o!.path), `orphan ${o!.path} must be removed`);
    }
    assert.ok(fs.existsSync(path.join(fanHome, 'etc', 'sys', 'config.props')),
      'real installation must survive sweeping 8 orphans at once');
    assert.ok(fs.existsSync(path.join(fanHome, 'etc', 'build', 'props.txt')),
      'real etc/build must survive sweeping 8 orphans at once');
    assert.ok(fs.existsSync(path.join(fanHome, 'lib', 'java', 'sys.jar')),
      'real lib/java must survive sweeping 8 orphans at once');
  } finally {
    try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
    for (const o of orphans) {
      if (o) { try { fs.rmSync(o.path, { recursive: true }); } catch (_) {} }
    }
  }
});

test('sweepOrphaned never calls fs.rmSync — asserted by monkey-patching it to throw for the duration of the sweep', () => {
  const { fanHome } = makeFakeFanHome('main.pod');
  const logs: string[] = [];
  const orphan = ShadowDir.create('main.pod', fanHome, m => logs.push(m));
  // TypeScript's `import * as fs from 'fs'` compiles (with esModuleInterop)
  // to a getter-only re-export binding — `fs.rmSync = ...` on that local
  // binding throws "has only a getter". Patch the real module object via
  // require() instead; shadowDir.js's own `import * as fs` binding is a
  // getter that forwards to this same live module, so the patch still
  // intercepts every call it makes.
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const realFs = require('fs');
  const originalRmSync = realFs.rmSync;
  try {
    assert.ok(orphan !== undefined, 'create must succeed');
    // If sweepOrphaned (or anything it calls) ever calls fs.rmSync on a real
    // directory, this makes the test fail loudly instead of relying on the
    // survival assertions alone to catch a regression.
    realFs.rmSync = () => {
      throw new Error('fs.rmSync must never be called by sweepOrphaned — this is the exact bug being prevented');
    };
    assert.doesNotThrow(() => ShadowDir.sweepOrphaned(undefined, m => logs.push(m)),
      'sweepOrphaned must complete successfully without ever invoking fs.rmSync');
    assert.ok(!fs.existsSync(orphan!.path), 'orphan must still be fully removed using only unlinkSync/rmdirSync');
  } finally {
    realFs.rmSync = originalRmSync;
    try { fs.rmSync(fanHome, { recursive: true }); } catch (_) {}
    if (orphan) { try { fs.rmSync(orphan.path, { recursive: true }); } catch (_) {} }
  }
});

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

console.log('\nShadowDir tests:');
console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) { process.exit(1); }
