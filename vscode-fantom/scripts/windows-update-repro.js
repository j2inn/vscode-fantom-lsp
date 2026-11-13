/**
 * Reproduces, on a Windows CI runner, what a VS Code update does to a running
 * extension host and the temp-dir cleanup that can follow, then checks that
 * the Fantom installation (fanPath) is untouched.
 *
 * Steps:
 *   1. Build a fake Fantom installation (etc/, lib/fan, lib/java, bin/fan.bat).
 *   2. Start a real VS Code with the extension and a workspace whose
 *      fan.config.json points at it; wait until the shadow dir exists.
 *   3. Kill the whole VS Code process tree abruptly (what an updater does).
 *   4. Wipe the orphaned shadow dir the ways external tools do: cmd rd /s /q,
 *      PowerShell Remove-Item -Recurse -Force, Node fs.rmSync.
 *   5. Restart VS Code (the extension sweeps orphans) and kill it again.
 *   6. Fail if any file of the installation disappeared.
 *
 * Usage: node scripts/windows-update-repro.js <workDir>
 * The forensic log of the extension is copied to <workDir>/artifacts.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const { downloadAndUnzipVSCode } = require('@vscode/test-electron');

const WAIT_MS = 120000;
const POLL_MS = 1000;
const SHADOW_PREFIX = 'fantom-lsp-shadow-';

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
function write(file, text) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); }

/** Lists every file below dir (relative paths), without following links. */
function listFiles(dir, base = dir, out = []) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return out; }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) { listFiles(full, base, out); } else { out.push(path.relative(base, full)); }
  }
  return out.sort();
}

function makeFakeFanHome(root, bundledPod) {
  const home = path.join(root, 'fantom');
  write(path.join(home, 'etc', 'sys', 'config.props'), 'java.options=-Xmx64m\n');
  write(path.join(home, 'etc', 'sys', 'units.txt'), 'units\n');
  write(path.join(home, 'etc', 'build', 'config.props'), 'build\n');
  write(path.join(home, 'etc', 'util', 'a.props'), 'a\n');
  write(path.join(home, 'lib', 'java', 'sys.jar'), 'jar');
  write(path.join(home, 'lib', 'java', 'ext', 'x.jar'), 'jar');
  write(path.join(home, 'lib', 'fan', 'sys.pod'), 'pod');
  fs.copyFileSync(bundledPod, path.join(home, 'lib', 'fan', 'vscodeFantomLsp.pod'));
  write(path.join(home, 'bin', 'fan.bat'), '@echo off\r\nping -n 600 127.0.0.1 >nul\r\n');
  write(path.join(home, 'bin', 'fan'), '');
  return home;
}

function shadowDirs() {
  return fs.readdirSync(os.tmpdir()).filter(n => n.startsWith(SHADOW_PREFIX)).map(n => path.join(os.tmpdir(), n));
}

function forensicLog(userData) {
  const gs = path.join(userData, 'User', 'globalStorage');
  const hits = [];
  const walk = d => { try { for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const f = path.join(d, e.name);
    if (e.isDirectory()) walk(f); else if (e.name === 'fantom-forensics.log') hits.push(f);
  } } catch (_) {} };
  walk(gs);
  return hits[0];
}

async function waitFor(what, pred) {
  const end = Date.now() + WAIT_MS;
  while (Date.now() < end) { if (pred()) return; await sleep(POLL_MS); }
  throw new Error(`timeout waiting for ${what}`);
}

function startCode(codeExe, ctx) {
  const child = spawn(codeExe, [
    ctx.workspace, '--user-data-dir', ctx.userData, '--extensions-dir', ctx.extDir,
    '--extensionDevelopmentPath', ctx.extPath, '--disable-gpu', '--disable-workspace-trust',
    '--skip-welcome', '--skip-release-notes', '--disable-updates', '--new-window',
  ], { stdio: 'ignore', detached: false });
  return child;
}

function killTree(child) {
  console.log(`  taskkill /F /T /PID ${child.pid} (abrupt kill, as an updater would)`);
  spawnSync('taskkill', ['/F', '/T', '/PID', String(child.pid)], { stdio: 'inherit' });
}

function wipe(dir, how) {
  console.log(`  wipe ${dir} via ${how}`);
  if (how === 'cmd') spawnSync('cmd', ['/c', 'rd', '/s', '/q', dir], { stdio: 'inherit' });
  else if (how === 'powershell') spawnSync('powershell', ['-NoProfile', '-Command', `Remove-Item -LiteralPath '${dir}' -Recurse -Force`], { stdio: 'inherit' });
  else fs.rmSync(dir, { recursive: true, force: true });
}

async function main() {
  const work = path.resolve(process.argv[2] || path.join(os.tmpdir(), 'update-repro'));
  fs.rmSync(work, { recursive: true, force: true });
  const extPath = path.resolve(__dirname, '..');
  const artifacts = path.join(work, 'artifacts');
  fs.mkdirSync(artifacts, { recursive: true });

  const fanHome = makeFakeFanHome(work, path.join(extPath, 'bundled-pods', 'vscodeFantomLsp.pod'));
  const baseline = listFiles(fanHome);
  console.log(`fake fantom: ${fanHome} (${baseline.length} files)`);

  const workspace = path.join(work, 'workspace');
  write(path.join(workspace, 'build.fan'), 'using build\nclass Build : BuildPod { new make() { podName = "p" ; version = Version("1.0") ; srcDirs = [`fan/`] } }\n');
  write(path.join(workspace, 'fan.config.json'), JSON.stringify({ fanPath: fanHome }));
  const ctx = { workspace, userData: path.join(work, 'ud'), extDir: path.join(work, 'ext'), extPath };

  const codeExe = await downloadAndUnzipVSCode();
  console.log(`vscode: ${codeExe}`);

  const failures = [];
  const check = label => {
    const now = listFiles(fanHome);
    const lost = baseline.filter(f => !now.includes(f));
    console.log(`check [${label}]: ${lost.length === 0 ? 'OK' : 'LOST ' + lost.join(', ')}`);
    if (lost.length) failures.push(`${label}: ${lost.join(', ')}`);
  };

  for (const how of ['cmd', 'powershell', 'node']) {
    console.log(`\n=== scenario: kill + external wipe via ${how} ===`);
    const code = startCode(codeExe, ctx);
    await waitFor('shadow dir', () => shadowDirs().length > 0);
    console.log(`  shadow dirs: ${shadowDirs().join(', ')}`);
    check(`running-${how}`);
    killTree(code);
    await sleep(3000);
    check(`after-kill-${how}`);
    shadowDirs().forEach(d => wipe(d, how));
    check(`after-wipe-${how}`);
  }

  console.log('\n=== scenario: kill, restart (sweep of orphans), kill ===');
  let code = startCode(codeExe, ctx);
  await waitFor('shadow dir', () => shadowDirs().length > 0);
  killTree(code);
  await sleep(3000);
  const orphans = shadowDirs();
  console.log(`  orphans left by kill: ${orphans.length}`);
  code = startCode(codeExe, ctx);
  await waitFor('sweep of the orphans', () => orphans.every(o => !fs.existsSync(o)));
  check('after-restart-sweep');
  killTree(code);
  shadowDirs().forEach(d => wipe(d, 'node'));
  check('final');

  const log = forensicLog(ctx.userData);
  if (log) {
    for (const f of fs.readdirSync(path.dirname(log)).filter(n => n.startsWith('fantom-forensics.log'))) {
      fs.copyFileSync(path.join(path.dirname(log), f), path.join(artifacts, f));
    }
    console.log(`\nforensic log (incl. rotated files) -> ${artifacts}`);
  }
  else console.log('\nWARNING: no forensic log found');

  if (failures.length) { console.error(`\nFAIL: installation lost files:\n${failures.join('\n')}`); process.exit(1); }
  console.log('\nPASS: installation untouched in every scenario');
}

main().catch(e => { console.error(e); process.exit(1); });
