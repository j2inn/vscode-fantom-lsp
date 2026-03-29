# vscode-fantom-lsp – Claude Code Instructions

## Environment

- Fantom runtime: `/home/agiustij2/Public/fantom-1.0.82/bin/fan` (version 1.0.82)
- `FAN_HOME` for build/test: `/home/agiustij2/Documents/sources/panasonic/commercialcloud/FIN_519/`

## Build & Test Commands

Always prefix with `FAN_HOME=...` and use the full `fan` path:

```sh
# Compile Fantom LSP pod
FAN_HOME=/home/agiustij2/Documents/sources/panasonic/commercialcloud/FIN_519 \
  /home/agiustij2/Public/fantom-1.0.82/bin/fan build.fan compile

# Run all tests
FAN_HOME=/home/agiustij2/Documents/sources/panasonic/commercialcloud/FIN_519 \
  /home/agiustij2/Public/fantom-1.0.82/bin/fan build.fan test

# After changing LspServer.fan or any Fantom source, also rebundle the pod:
cp /home/agiustij2/Documents/sources/panasonic/commercialcloud/FIN_519/lib/fan/vscodeFantomLsp.pod \
   vscode-fantom/bundled-pods/vscodeFantomLsp.pod

# Compile TypeScript extension
cd vscode-fantom && pnpm run compile
```

## Testing Policy

- Always run `build.fan test` after fixing a bug or adding a feature.
- Every bug fix must be accompanied by a regression test in the relevant `src/test/` file.
  - Diagnostic false-positive fixes → `DiagnosticServiceTest.fan`
  - Add tests near the relevant section (e.g. "Map Type Resolution", "Method Parameter Validation").
- All tests must pass before considering the fix complete.

## Security Audits

Run after every `pnpm install` or dependency change:

```sh
cd vscode-fantom && pnpm audit
```

**Policy:** zero known vulnerabilities allowed. Fix vulnerabilities by adding overrides to the
`pnpm.overrides` section in [vscode-fantom/package.json](vscode-fantom/package.json):

```json
"pnpm": {
  "overrides": {
    "vulnerable-package": "^safe.version"
  }
}
```

Then run `pnpm install && pnpm audit` to confirm clean.
All current vulnerabilities are in devDependencies (never shipped in the VSIX) but must still
be pinned to safe versions via overrides.

## Cross-Platform Rules (Windows & Linux)

The extension must work on **both Windows and Linux**. Follow these rules strictly:

### 1. Strategy pattern for OS differences

Any code that behaves differently on Windows vs Linux **must** live in a dedicated
file using the platform strategy pattern. Never add inline `process.platform === 'win32'`
checks to new feature code.

- **Interface**: `vscode-fantom/src/platform.ts`
- **Linux impl**: `vscode-fantom/src/platform/linuxPlatform.ts`
- **Windows impl**: `vscode-fantom/src/platform/windowsPlatform.ts`
- Obtain the current platform via `getPlatform()` from `./platform`.

Add new properties/methods to the interface when a new OS difference is introduced,
then implement them in both platform files.

### 2. Common pitfalls

| Topic | Linux | Windows |
|-------|-------|---------|
| Java executable | `java` | `java.exe` |
| Classpath separator | `:` | `;` |
| Path separator | `/` | `\` (use `path.join`) |
| Shell flag for `spawn` | `false` | `true` for `.bat` scripts |
| Symlinks | `fs.symlinkSync` | May need admin rights; fall back to copy |

### 3. Path handling

Always use `path.join()` / `path.resolve()` — never string-concatenate paths.

### 4. Java setup flow

- `vscode-fantom/src/javaSetup.ts` handles Java resolution, startup check,
  and debug-adapter JAR auto-compilation.
- Uses `Platform` for all OS-specific names (java exe, javac, jar, classpath sep).
- At extension startup `checkJavaAtStartup()` is called non-blocking.
- When a debug session starts, `ensureDebugAdapterJar()` auto-builds the JAR
  from `bundled-debug/java-src/` if the pre-built JAR is missing.
