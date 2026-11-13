/**
 * Unit tests for configSafety.
 *
 * No VS Code dependency — runs with plain Node.js after TypeScript compilation:
 *   node out/test/configSafety.test.js
 */

import * as assert from 'assert';
import { hasShellMetacharacters, isSafeBuildTarget } from '../configSafety';

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

console.log('\nconfigSafety tests:');

test('plain build targets are safe', () => {
  for (const t of ['compile', 'test', 'build.fan', 'myPod::Main', 'run-tests', 'v1.2']) {
    assert.ok(isSafeBuildTarget(t), t);
  }
});

test('build targets with shell syntax are rejected', () => {
  for (const t of ['compile & calc', 'a|b', 'a;b', 'a b', '$(x)', '`x`', 'a>out', '', 'a\nb']) {
    assert.ok(!isSafeBuildTarget(t), JSON.stringify(t));
  }
});

test('ordinary paths have no shell metacharacters', () => {
  assert.ok(!hasShellMetacharacters('C:\\Program Files (x86)\\fantom'));
  assert.ok(!hasShellMetacharacters('/home/user/fantom-1.0.83'));
});

test('paths with cmd.exe metacharacters are flagged', () => {
  for (const p of ['C:\\a & calc', 'C:\\a|b', 'C:\\a>b', 'C:\\a^b', 'C:\\%PATH%', 'C:\\"x', 'a\nb']) {
    assert.ok(hasShellMetacharacters(p), JSON.stringify(p));
  }
});

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) { process.exit(1); }
