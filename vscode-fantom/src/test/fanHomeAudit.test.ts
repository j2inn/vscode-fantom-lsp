import * as assert from 'assert';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { auditFanHome, snapshotFanHome } from '../fanHomeAudit';

function test(name: string, fn: () => void): void {
  try { fn(); console.log(`  ✓ ${name}`); } catch (e) {
    console.error(`  ✗ ${name}`); console.error(e); process.exitCode = 1;
  }
}

function makeHome(): string {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'audit-home-'));
  fs.mkdirSync(path.join(home, 'etc', 'sys'), { recursive: true });
  fs.writeFileSync(path.join(home, 'etc', 'sys', 'config.props'), 'a=b');
  fs.mkdirSync(path.join(home, 'lib', 'fan'), { recursive: true });
  fs.writeFileSync(path.join(home, 'lib', 'fan', 'sys.pod'), 'pod');
  return home;
}

test('audit reports no loss for an unchanged installation', () => {
  const home = makeHome();
  try {
    const first = auditFanHome('a', home, () => {});
    const second = auditFanHome('b', home, () => {}, first.snapshot);
    assert.deepStrictEqual(second.losses, []);
  } finally { fs.rmSync(home, { recursive: true }); }
});

test('audit reports a missing etc folder and logs an ERROR line', () => {
  const home = makeHome();
  try {
    const first = auditFanHome('a', home, () => {});
    fs.rmSync(path.join(home, 'etc'), { recursive: true });
    const logs: string[] = [];
    const second = auditFanHome('b', home, m => logs.push(m), first.snapshot);
    assert.strictEqual(second.losses.length, 1);
    assert.ok(second.losses[0].startsWith('etc is MISSING'));
    assert.ok(logs.some(l => l.includes('ERROR') && l.includes('etc is MISSING')));
  } finally { fs.rmSync(home, { recursive: true, force: true }); }
});

test('audit reports a shrunk folder', () => {
  const home = makeHome();
  try {
    const first = auditFanHome('a', home, () => {});
    fs.rmSync(path.join(home, 'lib', 'fan', 'sys.pod'));
    const second = auditFanHome('b', home, () => {}, first.snapshot);
    assert.ok(second.losses.some(l => l.startsWith('lib') && l.includes('shrank')));
  } finally { fs.rmSync(home, { recursive: true }); }
});

test('snapshot of a missing dir uses -1', () => {
  const snap = snapshotFanHome(path.join(os.tmpdir(), 'does-not-exist-xyz'));
  assert.strictEqual(snap.fileCounts['etc'], -1);
});
