import * as fs from 'fs';
import * as path from 'path';

/** Sub-folders of a Fantom installation whose disappearance we want to detect. */
const AUDITED_DIRS = ['etc', path.join('lib', 'fan'), path.join('lib', 'java'), 'bin'];

/** Cheap summary of the audited folders of a Fantom installation. */
export interface FanHomeSnapshot {
  fanHome: string;
  takenAt: string;
  /** Relative dir -> number of files below it, or -1 when the dir is missing. */
  fileCounts: { [dir: string]: number };
}

/** Counts files below `dir` without following links; -1 if `dir` does not exist. */
function countFiles(dir: string): number {
  let entries: fs.Dirent[];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return -1; }
  let total = 0;
  for (const entry of entries) {
    if (entry.isDirectory()) {
      total += Math.max(0, countFiles(path.join(dir, entry.name)));
    } else {
      total++;
    }
  }
  return total;
}

/** Takes a snapshot of the audited folders of `fanHome`. */
export function snapshotFanHome(fanHome: string): FanHomeSnapshot {
  const fileCounts: { [dir: string]: number } = {};
  for (const rel of AUDITED_DIRS) {
    fileCounts[rel] = countFiles(path.join(fanHome, rel));
  }
  return { fanHome, takenAt: new Date().toISOString(), fileCounts };
}

/** Describes every audited folder that shrank or vanished between two snapshots. */
export function describeLosses(before: FanHomeSnapshot, after: FanHomeSnapshot): string[] {
  const losses: string[] = [];
  for (const rel of AUDITED_DIRS) {
    const was = before.fileCounts[rel];
    const now = after.fileCounts[rel];
    if (was === undefined || was < 0 || now >= was) { continue; }
    losses.push(now < 0
      ? `${rel} is MISSING (had ${was} files at ${before.takenAt})`
      : `${rel} shrank from ${was} to ${now} files (since ${before.takenAt})`);
  }
  return losses;
}

/** One-line summary of a snapshot for logs. */
export function formatSnapshot(phase: string, snap: FanHomeSnapshot): string {
  const counts = AUDITED_DIRS.map(rel => `${rel}=${snap.fileCounts[rel]}`).join(' ');
  return `[audit:${phase}] pid=${process.pid} fanHome=${snap.fanHome} ${counts}`;
}

/**
 * Takes a snapshot, logs it, and compares it with `previous`. Any loss is
 * logged as an ERROR line. Returns the new snapshot and the loss descriptions.
 */
export function auditFanHome(
  phase: string,
  fanHome: string,
  log: (msg: string) => void,
  previous?: FanHomeSnapshot,
): { snapshot: FanHomeSnapshot; losses: string[] } {
  const snapshot = snapshotFanHome(fanHome);
  log(formatSnapshot(phase, snapshot));
  const losses = previous && previous.fanHome === fanHome ? describeLosses(previous, snapshot) : [];
  for (const loss of losses) {
    log(`ERROR [audit:${phase}] FAN_HOME content lost: ${loss}`);
  }
  return { snapshot, losses };
}
