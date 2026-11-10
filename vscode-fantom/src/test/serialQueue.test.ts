/**
 * Unit tests for SerialQueue.
 *
 * No VS Code dependency — runs with plain Node.js after TypeScript compilation:
 *   node out/test/serialQueue.test.js
 */

import * as assert from 'assert';
import { SerialQueue } from '../serialQueue';

let passed = 0;
let failed = 0;

async function test(name: string, fn: () => Promise<void>): Promise<void> {
  try {
    await fn();
    console.log(`  ✓ ${name}`);
    passed++;
  } catch (e: any) {
    console.error(`  ✗ ${name}`);
    console.error(`    ${e.message}`);
    failed++;
  }
}

const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));

async function main(): Promise<void> {
  console.log('\nSerialQueue tests:');

  await test('tasks never overlap and run in enqueue order', async () => {
    const queue = new SerialQueue();
    const events: string[] = [];
    let running = 0;
    let maxRunning = 0;
    const makeTask = (id: string, ms: number) => async () => {
      running++;
      maxRunning = Math.max(maxRunning, running);
      events.push(`start ${id}`);
      await sleep(ms);
      events.push(`end ${id}`);
      running--;
    };
    await Promise.all([
      queue.enqueue(makeTask('a', 30)),
      queue.enqueue(makeTask('b', 5)),
      queue.enqueue(makeTask('c', 1)),
    ]);
    assert.strictEqual(maxRunning, 1, 'at most one task may run at a time');
    assert.deepStrictEqual(events,
      ['start a', 'end a', 'start b', 'end b', 'start c', 'end c']);
  });

  await test('a failing task rejects its own promise but does not block later tasks', async () => {
    const queue = new SerialQueue();
    let ran = false;
    const failing = queue.enqueue(async () => { throw new Error('boom'); });
    const next = queue.enqueue(async () => { ran = true; });
    await assert.rejects(failing, /boom/);
    await next;
    assert.ok(ran, 'task enqueued after a failure must still run');
  });

  console.log(`\n${passed} passed, ${failed} failed`);
  if (failed > 0) { process.exit(1); }
}

main();
