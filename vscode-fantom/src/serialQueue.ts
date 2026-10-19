/**
 * Runs async tasks strictly one at a time, in the order they were enqueued.
 *
 * Used for work that must never overlap with itself, such as restarting the
 * language server in response to file-watcher events (a single file save can
 * fire several events in quick succession).
 *
 * A task that throws or rejects does not stop later tasks from running.
 */
export class SerialQueue {
  private tail: Promise<void> = Promise.resolve();

  /** Appends `task` to the queue; resolves when that task has finished. */
  enqueue(task: () => Promise<void>): Promise<void> {
    const run = this.tail.then(task);
    this.tail = run.catch(() => undefined);
    return run;
  }
}
