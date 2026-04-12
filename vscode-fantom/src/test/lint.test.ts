/**
 * Lint correctness tests — verifies that all TypeScript source files pass
 * ESLint with zero errors and that the configured rules enforce expected style.
 *
 * No VS Code dependency — runs with plain Node.js after TypeScript compilation:
 *   node out/test/lint.test.js
 */

import * as assert from 'assert';
import * as path from 'path';
import { spawnSync } from 'child_process';

const projectRoot = path.join(__dirname, '../..');
// Resolve the actual ESLint JS entry point so we can invoke it with `node`
// directly — avoids shell-script wrapper issues in node_modules/.bin/.
const eslintMain = require.resolve('eslint', { paths: [projectRoot] });
const eslintBin  = path.join(path.dirname(path.dirname(eslintMain)), 'bin', 'eslint.js');

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
// Helper: lint an in-memory snippet by piping it via stdin.
// Uses --stdin-filename src/__test__.ts so the project .eslintrc.json applies.
// ---------------------------------------------------------------------------

function lintSnippet(code: string): { errors: number; warnings: number } {
  const result = spawnSync(
    'node',
    [eslintBin, '--format', 'json', '--stdin', '--stdin-filename',
      path.join(projectRoot, 'src', '__test__.ts')],
    { cwd: projectRoot, encoding: 'utf8', input: code }
  );
  const json: Array<{ errorCount: number; warningCount: number }> =
    JSON.parse(result.stdout || '[]');
  return {
    errors:   json.reduce((n, r) => n + r.errorCount,   0),
    warnings: json.reduce((n, r) => n + r.warningCount, 0),
  };
}

// ---------------------------------------------------------------------------
// Tests: all production source files must have zero lint errors
// ---------------------------------------------------------------------------

console.log('\nLint tests:\n');

test('all source files pass lint with zero errors', () => {
  const result = spawnSync(
    'node',
    [eslintBin, 'src/**/*.ts', '--format', 'stylish'],
    { cwd: projectRoot, encoding: 'utf8' }
  );
  assert.strictEqual(
    result.status, 0,
    `ESLint reported errors:\n${result.stdout}\n${result.stderr}`
  );
});

// ---------------------------------------------------------------------------
// Tests: rules catch intended violations
// ---------------------------------------------------------------------------

// Use `export` on top-level declarations so @typescript-eslint/no-unused-vars
// does not flag the symbol itself — only the rule under test should fire.

test('double-quoted strings are flagged', () => {
  const { errors } = lintSnippet('export const x = "hello";\n');
  assert.ok(errors > 0, 'double-quoted string should produce an error');
});

test('single-quoted strings are accepted', () => {
  const { errors } = lintSnippet("export const x = 'hello';\n");
  assert.strictEqual(errors, 0, 'single-quoted string should produce no errors');
});

test('missing semicolon is flagged', () => {
  const { errors } = lintSnippet('export const x = 1\n');
  assert.ok(errors > 0, 'missing semicolon should produce an error');
});

test('while(true) with break is allowed', () => {
  const { errors } = lintSnippet([
    'export function loop(): void {',
    '  while (true) {',
    '    break;',
    '  }',
    '}',
    '',
  ].join('\n'));
  assert.strictEqual(errors, 0, 'while(true) with break must not be flagged');
});

test('_prefixed unused parameters are allowed', () => {
  const { errors } = lintSnippet([
    'export function handler(_event: unknown): void {',
    '  return;',
    '}',
    '',
  ].join('\n'));
  assert.strictEqual(errors, 0, '_prefixed unused params must not be flagged');
});

test('unprefixed unused variable is flagged', () => {
  // Local variable inside an exported function — must still be flagged.
  const { errors } = lintSnippet([
    'export function bar(): void {',
    '  const neverUsed = 1;',
    '}',
    '',
  ].join('\n'));
  assert.ok(errors > 0, 'unused variable without _ prefix must be flagged');
});

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) { process.exit(1); }
