# vscode-fantom-lsp – Claude Code Instructions

## Environment

- Fantom runtime: `/home/agiustij2/Public/fantom-1.0.83/bin/fan` (version 1.0.83)
- `FAN_HOME` for build/test: set to a local Fantom/FIN installation that has all required pods

## Build & Test Commands

Always prefix with `FAN_HOME=...` and use the full `fan` path:

```sh
# Compile Fantom LSP pod
FAN_HOME=/path/to/fantom-installation \
  /path/to/fantom/bin/fan build.fan compile

# Run all tests
FAN_HOME=/path/to/fantom-installation \
  /path/to/fantom/bin/fan build.fan test

# After changing LspServer.fan or any Fantom source, also rebundle the pod:
cp /path/to/fantom-installation/lib/fan/vscodeFantomLsp.pod \
   vscode-fantom/bundled-pods/vscodeFantomLsp.pod

# Compile TypeScript extension
cd vscode-fantom && pnpm run compile
```

## Comment & Documentation Style

- All comments in source code, commit messages, and documentation must be **project-agnostic**.
  Never reference specific customer names, company names, or proprietary project names.
- Use generic placeholders in examples: `myPod`, `MyClass`, `/path/to/fantom`, `example.com`.
- README and inline documentation must describe features in terms of the Fantom language
  and standard tooling only — not in terms of any particular deployment or customer.

## AST-First Policy

**Never use heuristic text/regex parsing when the Fantom compiler or AST can be used instead.**

- `ProjectIndex` indexes every symbol (types, methods, fields, locals, params) using the Fantom compiler AST via `AstIndex.parse()`. Use this indexed data as the source of truth.
- When you need method boundaries, local variable scope, type names, or symbol locations, query the index (`getMethodBounds`, `findDefinition`, `findEnclosingMethod`, `getBaseTypeChain`, etc.) — do not re-derive them by scanning source text.
- Text-based scanning (`ReferencesScanner`) is only acceptable for finding *occurrence positions* of an already-resolved symbol name. The *identity* of the symbol (what method it belongs to, what type it has) must come from the index.
- If the index lacks a needed query method, add it to `ProjectIndex` using the indexed symbols — do not add heuristic text parsing to scanner/service code.

Examples of what **not** to do:
- Detecting method boundaries by scanning for `Void foo(` patterns in source text
- Re-deriving variable types by scanning `:=` assignments when `symbol.typeStr` is already indexed
- Checking if a name is a type by looking for uppercase first letter instead of `index.hasType(name)`

## Command Palette Policy

Whenever a new command is added to the `contributes.commands` array in
`vscode-fantom/package.json`, **also update the Commands table in `README.md`**:

- Add a row to the `## 🛠️ Commands` table.
- Columns: **Command** (display title), **Shortcut** (from `contributes.keybindings`, `—` if none), **Description**.
- Keep rows sorted: commands with keyboard shortcuts first (ordered by shortcut), then the rest alphabetically.

## Fantom Coding Style

- **Use `while` instead of `for` when the loop index is manipulated inside the block body.**
  If any statement inside the loop changes the iteration variable (e.g. `i++`, `i += 2`,
  an inner `while` that advances `i`), write the loop as an explicit `while` with `i` declared
  before the loop. `for` is only appropriate when the index advances solely via the for-header
  increment and is never touched inside the body.

  ```fantom
  // Preferred — index manipulation is explicit and visible
  i := 0
  while (i < str.size)
  {
    ch := str[i]
    if (ch == '\\') { i += 2; continue }
    i++
  }

  // Avoid — index manipulation hidden inside a for-body is error-prone
  for (i := 0; i < str.size; i++)
  {
    ch := str[i]
    if (ch == '\\') { i++; continue }   // double-advance is subtle
  }
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

| Topic                  | Linux            | Windows                                  |
| ---------------------- | ---------------- | ---------------------------------------- |
| Java executable        | `java`           | `java.exe`                               |
| Classpath separator    | `:`              | `;`                                      |
| Path separator         | `/`              | `\` (use `path.join`)                    |
| Shell flag for `spawn` | `false`          | `true` for `.bat` scripts                |
| Symlinks               | `fs.symlinkSync` | May need admin rights; fall back to copy |

### 3. Path handling

Always use `path.join()` / `path.resolve()` — never string-concatenate paths.

### 4. Java setup flow

- `vscode-fantom/src/javaSetup.ts` handles Java resolution, startup check,
  and debug-adapter JAR auto-compilation.
- Uses `Platform` for all OS-specific names (java exe, javac, jar, classpath sep).
- At extension startup `checkJavaAndBuildAdapterAtStartup()` is called non-blocking:
  checks Java availability, shows a warning popup if Java is missing, and builds
  the debug adapter JAR from `bundled-debug/java-src/` if it does not yet exist.
- The JAR is **not bundled** in the repository — it is always compiled locally from
  the bundled Java sources at first activation.
- When a debug session starts, `ensureDebugAdapterJar()` verifies the JAR is present
  and offers a one-click "Rebuild now" button if it is missing.
- Users can force a rebuild at any time via **Fantom: Rebuild debugger** (Command Palette).
