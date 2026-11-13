/**
 * Unit tests for removalSafety.
 *
 * No VS Code dependency — runs with plain Node.js after TypeScript compilation:
 *   node out/test/removalSafety.test.js
 */

import * as assert from 'assert';
import {
  isUnusedImportLineSafeToDelete,
  isUnusedVariableSafeToDelete,
  unusedVariableName,
} from '../removalSafety';

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

console.log('\nremovalSafety tests:');

test('extracts the variable name from the diagnostic message', () => {
  assert.strictEqual(unusedVariableName("'count' is declared but never used"), 'count');
  assert.strictEqual(unusedVariableName('something else'), undefined);
});

test('a using line is safe to delete', () => {
  assert.ok(isUnusedImportLineSafeToDelete('using sys::Str'));
  assert.ok(isUnusedImportLineSafeToDelete('  using concurrent'));
});

test('a line that is no longer a using line is not safe to delete', () => {
  assert.ok(!isUnusedImportLineSafeToDelete('class Foo'));
  assert.ok(!isUnusedImportLineSafeToDelete('  x := 1'));
  assert.ok(!isUnusedImportLineSafeToDelete(''));
});

test('a plain local with a literal initializer is safe to delete', () => {
  assert.ok(isUnusedVariableSafeToDelete('    x := 5', 'x'));
  assert.ok(isUnusedVariableSafeToDelete('    Str s := "a"', 's'));
  assert.ok(isUnusedVariableSafeToDelete('    Str? s := null', 's'));
  assert.ok(isUnusedVariableSafeToDelete('    xs := [1, 2,\n      3]', 'xs'));
});

test('an initializer with a call is kept because of possible side effects', () => {
  assert.ok(!isUnusedVariableSafeToDelete('    x := doWork()', 'x'));
  assert.ok(!isUnusedVariableSafeToDelete('    x := Foo()', 'x'));
});

test('a member declaration is not deleted', () => {
  assert.ok(!isUnusedVariableSafeToDelete('  private Str x := "a"', 'x'));
  assert.ok(!isUnusedVariableSafeToDelete('  static const Int x := 1', 'x'));
});

test('a line that no longer declares the variable is not deleted', () => {
  assert.ok(!isUnusedVariableSafeToDelete('    y := 5', 'x'));
  assert.ok(!isUnusedVariableSafeToDelete('    echo("x := 5")', 'x'));
});

test('a variable name with regex characters does not break matching', () => {
  assert.ok(!isUnusedVariableSafeToDelete('    a := 1', 'a.b'));
});

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) { process.exit(1); }
