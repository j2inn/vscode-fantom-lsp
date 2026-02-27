/**
 * Unit tests for getDeclarationEndLine.
 *
 * No VS Code dependency — runs with plain Node.js after TypeScript compilation:
 *   node out/test/declarationRange.test.js
 */

import * as assert from 'assert';
import { getDeclarationEndLine } from '../declarationRange';

// Helper: build a getLine function from an array of strings.
function lines(...ls: string[]): [(i: number) => string, number] {
  return [i => ls[i], ls.length];
}

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

function eq(actual: number, expected: number, msg?: string): void {
  assert.strictEqual(actual, expected, msg ?? `expected ${expected}, got ${actual}`);
}

// ---------------------------------------------------------------------------
// Single-line declarations
// ---------------------------------------------------------------------------

test('single-line simple value', () => {
  const [getLine, count] = lines(
    '  x := 42',
    '  doSomething()',
  );
  eq(getDeclarationEndLine(getLine, count, 0), 0);
});

test('single-line with balanced parens', () => {
  const [getLine, count] = lines(
    '  x := Type.make("hello")',
    '  useIt()',
  );
  eq(getDeclarationEndLine(getLine, count, 0), 0);
});

test('single-line with balanced braces on same line', () => {
  const [getLine, count] = lines(
    '  x := Type { it.field = 1 }',
    '  useIt()',
  );
  eq(getDeclarationEndLine(getLine, count, 0), 0);
});

test('single-line string with no brackets', () => {
  const [getLine, count] = lines(
    '  x := "hello world"',
    '  useIt()',
  );
  eq(getDeclarationEndLine(getLine, count, 0), 0);
});

// ---------------------------------------------------------------------------
// Multi-line list / map literals
// ---------------------------------------------------------------------------

test('multi-line list literal', () => {
  const [getLine, count] = lines(
    '  x := [',
    '    "item1",',
    '    "item2",',
    '  ]',
    '  useIt()',
  );
  eq(getDeclarationEndLine(getLine, count, 0), 3);
});

test('multi-line map literal', () => {
  const [getLine, count] = lines(
    '  x := Str:Int[:',
    '    "a": 1,',
    '    "b": 2,',
    '  ]',
    '  return x',
  );
  eq(getDeclarationEndLine(getLine, count, 0), 3);
});

test('multi-line nested list', () => {
  const [getLine, count] = lines(
    '  x := [',
    '    [1, 2, 3],',
    '    [4, 5, 6],',
    '  ]',
    '  return x',
  );
  eq(getDeclarationEndLine(getLine, count, 0), 3);
});

// ---------------------------------------------------------------------------
// Fantom with-blocks (next-line opening brace)
// ---------------------------------------------------------------------------

test('with-block on next line after plain type', () => {
  const [getLine, count] = lines(
    '  x := SomeType',
    '  {',
    '    it.field = "val"',
    '  }',
    '  return x',
  );
  eq(getDeclarationEndLine(getLine, count, 0), 3);
});

test('with-block on next line after constructor call', () => {
  const [getLine, count] = lines(
    '  x := SomeType.make("arg")',
    '  {',
    '    it.field = "val"',
    '  }',
    '  return x',
  );
  eq(getDeclarationEndLine(getLine, count, 0), 3);
});

test('with-block on next line after chained call', () => {
  const [getLine, count] = lines(
    '  x := builder.build()',
    '  {',
    '    it.a = 1',
    '    it.b = 2',
    '  }',
    '  useIt(x)',
  );
  eq(getDeclarationEndLine(getLine, count, 0), 4);
});

test('with-block with blank line between decl and brace', () => {
  const [getLine, count] = lines(
    '  x := SomeType',
    '',
    '  {',
    '    it.field = 1',
    '  }',
    '  return x',
  );
  eq(getDeclarationEndLine(getLine, count, 0), 4);
});

// ---------------------------------------------------------------------------
// With-block on SAME line (open brace on declaration line)
// ---------------------------------------------------------------------------

test('with-block brace on same line as decl', () => {
  const [getLine, count] = lines(
    '  x := SomeType {',
    '    it.field = 1',
    '  }',
    '  return x',
  );
  eq(getDeclarationEndLine(getLine, count, 0), 2);
});

// ---------------------------------------------------------------------------
// Non-with-block: closing brace on next line belongs to method, not decl
// ---------------------------------------------------------------------------

test('closing method brace on next line is not part of decl', () => {
  const [getLine, count] = lines(
    '  x := "hello"',
    '}',           // closing brace of enclosing method — NOT part of x
  );
  eq(getDeclarationEndLine(getLine, count, 0), 0);
});

test('next line starts with } — single-line decl', () => {
  const [getLine, count] = lines(
    '  x := compute()',
    '  }',   // unrelated closing brace
  );
  eq(getDeclarationEndLine(getLine, count, 0), 0);
});

// ---------------------------------------------------------------------------
// Declaration not at line 0 (startLine parameter)
// ---------------------------------------------------------------------------

test('startLine offset works correctly', () => {
  const [getLine, count] = lines(
    '  a := 1',          // line 0 — not our declaration
    '  b := [',          // line 1 — startLine
    '    "x",',          // line 2
    '  ]',               // line 3
    '  use(b)',          // line 4
  );
  eq(getDeclarationEndLine(getLine, count, 1), 3);
});

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

console.log('\nDeclarationRange tests:');
// (tests already ran above via test() calls)

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) { process.exit(1); }
