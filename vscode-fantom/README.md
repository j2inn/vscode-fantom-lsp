# 👻 VSCode Fantom LSP

[![License: AFL-3.0](https://img.shields.io/badge/license-AFL--3.0-blue?style=flat-square)](https://opensource.org/licenses/AFL-3.0)
[![AI assisted](https://img.shields.io/badge/AI%20assisted-Claude%20by%20Anthropic-D97757?style=flat-square&logo=anthropic&logoColor=white)](https://claude.ai/claude-code)
[![AI assisted](https://img.shields.io/badge/AI%20assisted-Qwen2.5%20Coder%2030B-6B6EF9?style=flat-square&logo=openai&logoColor=white)](https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct)

> **Unofficial** Language Server Protocol support for [Fantom](https://fantom.org/) in Visual Studio Code.

---

## 🏢 About J2 Innovations & FIN Framework

[**J2 Innovations**](https://www.j2inn.com/) is a technology company that created **FIN Framework** — a cutting-edge open platform for smart buildings, smart equipment control, and IoT systems. FIN powers supervisory & control solutions, microBMS, equipment optimization, and edge-to-cloud connectivity, and is trusted by major OEM partners including Siemens, SageGlass, and Coster Group.

**FIN Framework is built on [Fantom](https://fantom.org/)** — a JVM-based, object-oriented programming language. All FIN application code, connectors, and extensions are written in Fantom, making a productive Fantom development environment essential for anyone building on the FIN platform.

This extension was created to improve the day-to-day developer experience when working with FIN Framework and Fantom projects in Visual Studio Code. It brings real-time diagnostics, autocompletion, go-to-definition, hover documentation, and a full debugger — all tailored to the Fantom ecosystem that powers FIN.

---

This extension brings a rich developer experience to Fantom projects inside VSCode — syntax highlighting, real-time diagnostics, autocompletion, hover docs, go-to-definition, **debugging with breakpoints and variable inspection**, and more. It is powered by a Fantom LSP server written entirely in Fantom itself (`vscodeFantomLsp`), automatically deployed into your Fantom installation when the extension activates.

⚠️ This is an **unofficial, community-driven** project. It is not affiliated with or endorsed by the Fantom language authors or J2 Innovations.

---

## ✨ Features

### ✅ Implemented

| Feature                                   | Description                                                                                                                |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| 🔍 **Go to Definition**                   | Jump to the definition of types, methods, and fields across project files                                                  |
| 💡 **Auto Completion**                    | Context-aware suggestions triggered on `.` (dot) and keyword prefix                                                        |
| ⇥ **Tab Completion**                      | Complete identifiers and keywords without reaching for the mouse                                                           |
| 🔁 **Duplicate `static const` detection** | Warns when two or more static const fields share the same string value across the project                                  |
| 🗑️ **Unused variable detection**          | Highlights variables that are declared but never read                                                                      |
| 🧹 **Unused import detection**            | Warns on `using` statements that are not referenced in the file                                                            |
| 🎯 **Hover information**                  | Shows type signatures and pod documentation when hovering over a symbol                                                    |
| 🚨 **Real-time diagnostics**              | Syntax errors and type errors from the Fantom compiler, debounced while typing                                             |
| 🔗 **Cross-file validation**              | Detects unresolved type references across all project source files                                                         |
| 🏗️ **Build integration**                  | Runs `fan build.fan` on save and reports compiler errors with clickable file links                                         |
| 🖊️ **Syntax highlighting**                | Full TextMate grammar for `.fan` files                                                                                     |
| 🧩 **Remove Unused Imports**              | Command to remove all unused `using` lines in a file or the whole project                                                  |
| 🧩 **Remove Unused Variables**            | Command to remove all unused variable declarations in a file or the whole project                                          |
| 📊 **Status bar diagnostics**             | Live error and warning counts in the VSCode status bar                                                                     |
| 🖋️ **Source formatter**                   | Format on demand or on save — indentation, blank-line limits, space collapsing, line wrapping, and `.editorconfig` support |
| 🐛 **Debugger (DAP)**                     | Set breakpoints, step through code, and inspect variables in Fantom programs on the JVM                                    |

---

## 📋 Requirements

- **Fantom** ≥ 1.0.80 installed locally — [Download](https://fantom.org/sidewalk/topic/2782)
- **Java JDK** (not just JRE) available in your `PATH` or via `JAVA_HOME` — the debugger needs the `jdk.jdi` module (JDK 9+)
- **VSCode** ≥ 1.75.0

> Don't have Fantom? Run the helper script included in this repo:
>
> ```bash
> ./install-fantom.sh
> ```
>
> It fetches and unpacks the latest Fantom release for you.

---

## 🚀 Installation

### From the VSIX (recommended)

1. Download the latest `.vsix` from the [Releases](../../releases) page.
2. In VSCode open the Command Palette (`Ctrl+Shift+P`) → **Extensions: Install from VSIX…**
3. Select the downloaded file.

Or install from the terminal:

```bash
code --install-extension fantom-language-support-${TAG}.vsix
```

### From Source

```bash
# 1. Build the LSP pod (requires Fantom installed and in PATH)
fan build.fan

# 2. Build the debug adapter JAR (requires JDK 11+)
cd vscode-fantom
bash debug-adapter/build.sh

# 3. Install Node.js dependencies and build the extension
pnpm install
pnpm run compile

# 4. Package (optional)
pnpm dlx @vscode/vsce package
```

---

## ⚙️ Configuration

The extension looks for configuration in two places, in priority order:

### 1. `fan.config.json` (project-level, recommended)

Create a `fan.config.json` file in the **root of your workspace**. The extension will offer to create a skeleton automatically on first activation if the file is missing.

```json
{
  "fanPath": "/opt/fantom-1.0.82",
  "fanTargetBuild": "compile",
  "debounceTime": 1000,
  "enableUnusedImport": true
}
```

| Key                  | Type      | Default | Description                                                                                                                                                                                            |
| -------------------- | --------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `fanPath`            | `string`  | `""`    | Absolute path to your Fantom installation directory (the folder that contains `bin/fan`). When empty or set to the placeholder value, the extension falls back to the `FAN_HOME` environment variable. |
| `finPath`            | `string`  | `""`    | Direct path to the `fin` executable (e.g. `/opt/fin/bin/fin`). When set, the debugger prefers this over `fanPath` for launch configurations.                                                           |
| `fanTargetBuild`     | `string`  | `""`    | The build target passed to `fan build.fan <target>` on every save. Leave empty to run the default target.                                                                                              |
| `debounceTime`       | `number`  | `2000`  | Milliseconds to wait after the last keystroke before running diagnostics. Lower values give faster feedback; higher values are gentler on large projects. Minimum: `100`.                              |
| `enableUnusedImport` | `boolean` | `true`  | When `false`, unused `using` import warnings are suppressed entirely.                                                                                                                                  |

> 💾 The LSP server restarts automatically whenever `fan.config.json` is saved.

### 2. `FAN_HOME` environment variable (global fallback)

If `fanPath` is not set (or left as the placeholder) in `fan.config.json`, the extension reads the `FAN_HOME` environment variable:

```bash
# ~/.bashrc / ~/.zshrc
export FAN_HOME=/opt/fantom-1.0.82
export PATH=$FAN_HOME/bin:$PATH
```

**Resolution order** (first wins):

1. `fanPath` in `fan.config.json`
2. `FAN_HOME` environment variable
3. Extension shows a warning and does not start

### 3. VSCode settings (`settings.json`)

Additional settings available through the VSCode UI or `settings.json`:

| Setting                                | Type      | Default | Description                                                                                                                                |
| -------------------------------------- | --------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `fantom.javaPath`                      | `string`  | `""`    | Full path to the `java` executable. Defaults to `$JAVA_HOME/bin/java`, then just `java` from `PATH`.                                       |
| `fantom.suppressJavaWarning`           | `boolean` | `false` | Suppress the startup warning when Java is not found. Enable this if you do not use the Fantom debugger.                                    |
| `fantom.suppressWarningPopup`          | `boolean` | `false` | Suppress the "Warnings found" notification popup shown at startup when the build produces warnings.                                        |
| `fantom.useBuiltInLspPod`              | `boolean` | `true`  | Use the `vscodeFantomLsp` bundled with the extension (recommended). Set to `false` only if you have built and installed your own LSP pod.  |
| `fantom.pedanticMode`                  | `boolean` | `false` | Warn on local variable declarations that lack an explicit type annotation (neither a type on the left side nor an `as` cast on the right). |
| `fantom.trace.server`                  | `string`  | `"off"` | Trace LSP message traffic: `"off"`, `"messages"`, or `"verbose"`. Useful for debugging the extension itself.                               |
| `fantom.format.enable`                 | `boolean` | `true`  | Enable the Fantom formatter (Format Document / Format Selection).                                                                          |
| `fantom.format.formatOnSave`           | `boolean` | `false` | Automatically format Fantom files on save.                                                                                                 |
| `fantom.format.indentSize`             | `number`  | `2`     | Spaces per indentation level (ignored when `useTabs` is `true`).                                                                           |
| `fantom.format.useTabs`                | `boolean` | `false` | Use tab characters for indentation instead of spaces.                                                                                      |
| `fantom.format.insertFinalNewline`     | `boolean` | `true`  | Ensure the file ends with a newline character.                                                                                             |
| `fantom.format.trimTrailingWhitespace` | `boolean` | `true`  | Remove trailing whitespace from each line.                                                                                                 |
| `fantom.format.maxBlankLines`          | `number`  | `1`     | Maximum consecutive blank lines to preserve. `0` keeps all blank lines.                                                                    |
| `fantom.format.respectEditorConfig`    | `boolean` | `true`  | Let `.editorconfig` files override the settings above.                                                                                     |
| `fantom.format.collapseSpaces`         | `boolean` | `true`  | Collapse runs of two or more spaces into one in code regions (outside strings and comments).                                               |
| `fantom.format.maxLineLength`          | `number`  | `0`     | Wrap lines that exceed this length. `0` disables wrapping.                                                                                 |

---

## 🛠️ Commands

Access these from the Command Palette (`Ctrl+Shift+P`):

| Command                                            | Description                                                                                                   |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| **Fantom: Remove Unused Imports in File**          | Deletes all unused `using` lines in the current file and saves                                                |
| **Fantom: Remove Unused Imports in Project**       | Deletes unused `using` lines across every `.fan` file in the project                                          |
| **Fantom: Remove Unused Variables in File**        | Deletes unused variable declarations in the current file                                                      |
| **Fantom: Remove Unused Variables in Project**     | Deletes unused variable declarations across the whole project                                                 |
| **Fantom: Create launch.json for Fantom Debugger** | Creates `.vscode/launch.json` with default Launch and Attach configurations pre-filled from `fan.config.json` |
| **Fantom: Format Entire Project**                  | Formats every `.fan` file in the project using the configured formatter settings                              |
| **Fantom: Rebuild debugger**                       | Recompiles the debug adapter JAR from bundled Java sources (useful after a JDK upgrade or a corrupt build)    |

---

## 🏗️ How It Works

```
VSCode Extension (TypeScript)
        │
        │  stdio (LSP protocol)
        ▼
  vscodeFantomLsp  ─── fan vscodeFantomLsp::Main
        │
        ├── ProjectIndex      (AST index of all .fan sources)
        ├── DiagnosticService (single-file + cross-file analysis)
        ├── CompletionService (dot-completion, keyword suggestions)
        ├── DefinitionService (go-to-definition)
        ├── HoverService      (type signatures, pod docs)
        └── fan build.fan     (real compiler, error reporting)

VSCode Extension (TypeScript)
        │
        │  stdin/stdout (DAP protocol)
        ▼
  fantom-debug-adapter.jar
        │
        │  JDWP / TCP
        ▼
  JVM running your Fantom program
```

On activation the extension:

1. Reads `fan.config.json` (or falls back to `FAN_HOME`).
2. Deploys (or updates) `vscodeFantomLsp` into `$FAN_HOME/lib/fan/`.
3. Spawns the LSP server via `fan vscodeFantomLsp::Main`.
4. Registers the Fantom debug adapter so it is available immediately in the Run & Debug panel.
5. The server indexes all `.fan` sources from `build.fan`'s `srcDirs`, pre-loads available pods, runs diagnostics, and performs an initial build check — all in the background so the editor stays responsive.

### Diagnostics lifecycle

- **While typing** — changes are debounced (`debounceTime` ms). No analysis runs until typing pauses.
- **After the debounce window** — single-file analysis runs immediately for fast feedback.
- **On save** — a full project re-index, cross-file validation, and `fan build.fan` all run together.

---

## 🖋️ Formatter

The extension includes a full source formatter for Fantom files, implemented inside the LSP server (`FormatterService`). It supports **Format Document**, **Format Selection**, and optional **format on save**.

### Activating the formatter

- **Format Document** — `Shift+Alt+F` (or Command Palette → `Format Document`)
- **Format Selection** — select code, then `Ctrl+K Ctrl+F`
- **Format on Save** — enable `fantom.format.formatOnSave` in settings (see below)

> The formatter respects VS Code's standard `editor.formatOnSave` setting too: when `fantom.format.formatOnSave` is enabled, the extension hooks into the save pipeline independently so you do not need to enable `editor.formatOnSave` globally.

### What the formatter does

#### Indentation

Indentation is re-computed by tracking brace depth (`{` / `}`). Braces inside string literals and `//` comments are ignored. The unit is controlled by `fantom.format.indentSize` (spaces) or `fantom.format.useTabs` (tabs).

#### Blank line limiting

Consecutive blank lines are reduced to at most `fantom.format.maxBlankLines` (default `1`). Set to `0` to remove all consecutive blanks, or keep the default to allow one blank line between declarations.

#### Trailing whitespace and final newline

When `fantom.format.trimTrailingWhitespace` is `true` (default), trailing spaces and tabs are stripped from every line. When `fantom.format.insertFinalNewline` is `true` (default), a newline is added at the end of the file if one is missing.

#### Line-ending preservation

The formatter detects the dominant line ending in the file (`LF`, `CRLF`, or CR-only) and uses the same style in the output. A Windows CRLF file stays CRLF after formatting; a Unix LF file stays LF.

#### Space collapsing

When `fantom.format.collapseSpaces` is `true` (default), runs of two or more consecutive spaces are collapsed to a single space in **code regions** — spaces inside string literals and `//` comments are never touched.

All Fantom string literal types are handled:

| Type                 | Example                 | Spaces inside |
| -------------------- | ----------------------- | ------------- |
| Double-quoted        | `"hello   world"`       | preserved     |
| Triple-quoted        | `"""hello   world"""`   | preserved     |
| Single-quoted (char) | `' '`                   | preserved     |
| Backtick (DSL / URI) | `` `path/to   thing` `` | preserved     |

Example:

```fantom
// Before
return val ?        0 : 1

// After
return val ? 0 : 1
```

#### Line wrapping

When `fantom.format.maxLineLength` is set to a positive value, lines that exceed that length are split automatically. The formatter looks for the best split point before the limit, in this priority order:

| Priority | Split point                                   | Example                                        |
| -------- | --------------------------------------------- | ---------------------------------------------- |
| 1        | Comma inside parentheses / brackets           | `foo(a, b, c)` → split after `,`               |
| 2        | `&&` or `\|\|` operator (any nesting depth)   | `if (a && b)` → split before `&&`              |
| 3        | Ternary `?` surrounded by spaces (at depth 0) | `x ? y : z` → split before `?`                 |
| 4        | Word boundary inside a string literal         | `"long string"` → split with `+` concatenation |

String literal splitting produces a concatenation expression:

```fantom
// Before (exceeds maxLineLength)
msg := "hello world this is a very long string"

// After
msg := "hello world this" +
  "is a very long string"
```

The split is at the last word-boundary space before the column limit. Backtick (DSL) strings are **never** split — their content (URIs, raw values) must remain intact. Continuation lines are indented one level deeper than the base line.

### `.editorconfig` support

When `fantom.format.respectEditorConfig` is `true` (default), the formatter walks up the directory tree from the file being formatted and applies the first matching `.editorconfig` section. Supported properties:

| `.editorconfig` key         | Maps to                  |
| --------------------------- | ------------------------ |
| `indent_style = tab`        | `useTabs = true`         |
| `indent_style = space`      | `useTabs = false`        |
| `indent_size` / `tab_width` | `indentSize`             |
| `trim_trailing_whitespace`  | `trimTrailingWhitespace` |
| `insert_final_newline`      | `insertFinalNewline`     |
| `max_blank_lines`           | `maxBlankLines`          |

The `.editorconfig` walk stops at `root = true` or at the workspace root, whichever comes first. Per-file `.editorconfig` values override the VS Code settings for that file only.

---

## 🐛 Debugger

The extension includes a full **Debug Adapter Protocol (DAP)** implementation that lets you set breakpoints, step through code, and inspect variables in Fantom programs running on the JVM.

> **Prerequisite**: A JDK (not just a JRE) is required — the debugger uses JDI, which is part of the JDK tools (`jdk.jdi` module, available in JDK 9+).

### How it works

#### The debug chain

```
VS Code  ←DAP/JSON-RPC→  fantom-debug-adapter.jar  ←JDWP/TCP→  JVM (your Fantom program)
```

1. **VS Code** communicates with the debug adapter using the [Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/) over stdin/stdout.
2. **`fantom-debug-adapter.jar`** (bundled with this extension) translates those commands into JDI calls. JDI (Java Debug Interface) is available in every JDK.
3. **The JVM** exposes a JDWP server socket when started with `-agentlib:jdwp=...`. The adapter connects to that socket to set breakpoints, read variables, and control execution.

#### How `.fan` source files map to running code

Fantom compiles `.fan` files to standard JVM `.class` bytecode. Two standard attributes enable source-level debugging:

- **`SourceFile`** — records the short filename (e.g. `MyService.fan`) in each `.class` file.
- **`LineNumberTable`** — maps each bytecode instruction back to its original Fantom line number.

These attributes are always emitted by the Fantom compiler with no special build flags needed.

#### What is and is not inspectable

| Item                    | Available        | Notes                                                                             |
| ----------------------- | ---------------- | --------------------------------------------------------------------------------- |
| `this` fields           | ✅               | All instance fields shown under the "this" scope                                  |
| Local variables         | ✅ (best-effort) | Shown when `LocalVariableTable` is present; otherwise method parameters are shown |
| Variable types          | ✅               | Proper Fantom type names (`myPod::MyClass`, `sys::List`, etc.)                    |
| Variable values         | ✅               | Calls Fantom's `toStr()` — shows the actual value, not `fan.sys.List@123`         |
| Step over / into / out  | ✅               | Works at the Fantom source line level                                             |
| Line breakpoints        | ✅               | Click the gutter in any `.fan` file                                               |
| Watch expressions       | ✅               | Supports `varName`, `this.field`, and `a.b.c` chains                              |
| Conditional breakpoints | ❌               | Not yet implemented                                                               |

---

### Java configuration

The JVM must be started with the JDWP agent to allow debugger connections.

#### Option A — `config.props` (for `fan` and `fin`)

Edit `<fanHome>/etc/sys/config.props`:

```properties
java.options=-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=5005
```

| JDWP option           | Meaning                                                                        |
| --------------------- | ------------------------------------------------------------------------------ |
| `transport=dt_socket` | Use a TCP socket                                                               |
| `server=y`            | JVM opens the server socket                                                    |
| `suspend=n`           | Program starts immediately; debugger can attach at any time                    |
| `suspend=y`           | JVM waits for a debugger before starting — useful for debugging initialization |
| `address=5005`        | TCP port                                                                       |

If you already have other JVM flags on `java.options`, separate them with a **space** (not a comma):

```properties
java.options=-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=5005 -Dfile.encoding=UTF8
```

> **Cleanup**: Remove the `java.options` line when done. With `suspend=y` left in place the program will hang on startup waiting for a debugger.

#### Option B — `JAVA_TOOL_OPTIONS` environment variable

Works for `attach` mode when you start the process manually before connecting:

```bash
export JAVA_TOOL_OPTIONS="-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=5005"
fin
```

> **Do not use `JAVA_TOOL_OPTIONS` with launch mode.** In launch mode the JDWP agent is injected via `java.options` in a temporary shadow `config.props`, which is scoped to that one JVM and never inherited by child processes. Using `JAVA_TOOL_OPTIONS` in parallel causes a port conflict and a `bind failed: Address already in use` error.

---

### Quick start — Attach mode (recommended for FIN)

**Step 1.** Enable JDWP in `<fanHome>/etc/sys/config.props`:

```properties
java.options=-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=5005
```

**Step 2.** Start your program normally:

```bash
fin
# or: fan myPod::Main
```

You will see `Listening for transport dt_socket at address: 5005` confirming the port is open.

**Step 3.** Create `.vscode/launch.json`:

> **Tip**: Run **Fantom: Create launch.json for Fantom Debugger** from the Command Palette (`Ctrl+Shift+P`) to generate this file automatically. The extension also offers to create it on first activation when `fan.config.json` is present and no `launch.json` exists.

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "fantom",
      "request": "attach",
      "name": "Attach to Fantom / FIN",
      "host": "localhost",
      "port": 5005,
      "sourceDir": "${workspaceFolder}"
    }
  ]
}
```

**Step 4.** Press **F5** to connect.

**Step 5.** Click the gutter next to a line in any `.fan` file to set a breakpoint.

> **VS Code tip**: If gutter clicks don't place breakpoints, add this to `settings.json`:
>
> ```json
> "debug.allowBreakpointsEverywhere": true
> ```

---

### Launch mode — VS Code starts the process

In launch mode **VS Code starts the Fantom/FIN process for you** when you press **F5**. You do not need to touch `config.props` or start anything manually.

#### What happens when you press F5

1. The adapter picks a **free TCP port** automatically (defaults to 5005, falls back to any free ephemeral port if 5005 is already in use — e.g. by a running FIN server).
2. A **temporary shadow `FAN_HOME`** is created in `/tmp/fantom-debug-home-*/`:
   - Every top-level entry from your real `FAN_HOME` is symlinked except `etc/` and `var/`.
   - `etc/sys/config.props` is rewritten: `java.options` from the original is stripped (prevents double-JDWP conflicts) and a fresh JDWP agent line for the chosen port is injected. `debug=true` is also added so any pods rebuilt with `preLaunchRebuild` emit full local variable info.
   - `var/` is a real directory with only sub-directories symlinked — lock files like `vm.lock` are created fresh, completely isolated from any running FIN server.
3. Your executable is launched with `FAN_HOME` pointing to the shadow directory.
4. The adapter attaches JDI to the JDWP port and is ready for breakpoints.
5. When you press **Stop** (or close the session), the entire process group is killed with `SIGKILL` and the shadow directory is deleted.

> Because JDWP is injected via `java.options` in the shadow `config.props` — not via `JAVA_TOOL_OPTIONS` — it affects only the launched JVM and is never inherited by child processes or the running FIN server.

#### Step 1. Create `fan.config.json` (if not already present)

```json
{
  "fanPath": "/path/to/fantom"
}
```

#### Step 2. Create `.vscode/launch.json`

**Plain `fan` launcher** (explicit `mainClass` required):

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "fantom",
      "request": "launch",
      "name": "Launch Fantom",
      "fanExe": "/path/to/fantom/bin/fan",
      "mainClass": "myPod::Main",
      "sourceDir": "${workspaceFolder}"
    }
  ]
}
```

**`fin` launcher** (already embeds its entry point — `mainClass` must be empty):

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "fantom",
      "request": "launch",
      "name": "Launch FIN",
      "fanExe": "/path/to/fin/bin/fin",
      "mainClass": "",
      "sourceDir": "${workspaceFolder}"
    }
  ]
}
```

> **Why `"mainClass": ""`?**  
> The `fin` script wraps `fanlaunch Fan finStackHost "$@"` — the pod name is hardcoded inside the script. Passing an extra `finStackHost::Main` argument after `-noAuth` confuses FIN's argument parser. Leave `mainClass` empty and rely on the script's built-in entry point.

**`fin` with `-noAuth`**:

```json
{
  "type": "fantom",
  "request": "launch",
  "name": "Launch FIN (no auth)",
  "fanExe": "/path/to/fin/bin/fin",
  "mainClass": "",
  "launcherArgs": ["-noAuth"],
  "sourceDir": "${workspaceFolder}"
}
```

**With local variable support** (`preLaunchRebuild` rebuilds your pod with `debug=true` before each session):

```json
{
  "type": "fantom",
  "request": "launch",
  "name": "Launch FIN (full debug)",
  "fanExe": "/path/to/fin/bin/fin",
  "mainClass": "",
  "launcherArgs": ["-noAuth"],
  "sourceDir": "${workspaceFolder}",
  "preLaunchRebuild": true
}
```

> **`preLaunchRebuild`** runs `fan build.fan` in `sourceDir` using the shadow `FAN_HOME` (which has `debug=true`) so the rebuilt pod contains `LocalVariableTable` bytecode attributes. Without this, only method parameters are visible in the Variables panel — local variables like `room11`, `room12` are invisible. Set it to `true` the first time you debug and whenever you do a clean build; afterwards you can set it back to `false` to skip the overhead.

#### Step 3. Press F5

The Debug Console shows the exact command being run:

```
[Fantom Debug] Launching: /path/to/fin -noAuth
```

If you see unexpected extra tokens after your arguments, check the `mainClass` field — it must be `""` for `fin`.

#### Step 4. Set breakpoints and click the gutter in any `.fan` file

> **VS Code tip**: If gutter clicks don't work, add to `settings.json`:
>
> ```json
> "debug.allowBreakpointsEverywhere": true
> ```

#### Step 5. Stop debugging

Press the **Stop** button (red square) or `Shift+F5`. The launched process and all its children are terminated immediately via `SIGKILL` on Linux/macOS.

---

### Launch configuration reference

#### `launch`

| Key                | Type     | Default              | Description                                                                                                                                                                                                               |
| ------------------ | -------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fanExe`           | string   | auto-detected        | Path to `fan` or `fin`. Auto-filled from `fan.config.json` (`finPath` first, then `fanPath/bin/fan`)                                                                                                                      |
| `mainClass`        | string   | `""`                 | Fantom class to run, e.g. `myPod::Main`. **Leave empty for `fin`** — `fin` already embeds its entry point; passing an extra class name after launcher args confuses its argument parser.                                  |
| `launcherArgs`     | string[] | `[]`                 | Arguments inserted between the executable and `mainClass`, e.g. `["-noAuth"]` → `fin -noAuth`. These are passed **to the launcher script itself**, before the Fantom pod name.                                            |
| `args`             | string[] | `[]`                 | Arguments appended after `mainClass` — passed to the Fantom program's `main()` method.                                                                                                                                    |
| `sourceDir`        | string   | `${workspaceFolder}` | Root directory searched for `.fan` source files (used for source ↔ JVM class mapping).                                                                                                                                    |
| `debugPort`        | number   | `5005`               | Preferred JDWP port. If the port is already in use the adapter automatically picks a free ephemeral port.                                                                                                                 |
| `noDebug`          | boolean  | `false`              | Launch without attaching the debugger (plain run).                                                                                                                                                                        |
| `preLaunchRebuild` | boolean  | `false`              | Run `fan build.fan` in `sourceDir` before launching, using a shadow `FAN_HOME` with `debug=true`. This makes local variables (beyond method parameters) visible in the debugger. Only needed after a clean/release build. |

#### `attach`

| Key         | Type   | Default              | Description                                     |
| ----------- | ------ | -------------------- | ----------------------------------------------- |
| `host`      | string | `localhost`          | Hostname or IP of the running JVM               |
| `port`      | number | `5005`               | JDWP port to connect to                         |
| `sourceDir` | string | `${workspaceFolder}` | Root directory searched for `.fan` source files |

---

### Source file mapping

When the JVM reports a stopped location it provides only the short filename (e.g. `MyService.fan`) and the JVM class name (e.g. `fan.myPod.MyService`). The adapter searches `sourceDir` in this order:

1. `<sourceDir>/<podName>/fan/<File.fan>` — standard Fantom pod layout
2. `<sourceDir>/<podName>/<File.fan>`
3. `<sourceDir>/fan/<File.fan>` — single-pod workspace
4. Full recursive walk under `sourceDir` — fallback for non-standard layouts

Set `sourceDir` to the root of your source tree. For a multi-pod workspace this is typically `${workspaceFolder}`.

---

### Building the debug adapter from source

The debug adapter JAR is pre-built and bundled at `vscode-fantom/bundled-debug/fantom-debug-adapter.jar`. To rebuild (requires JDK 11+, no Maven needed):

```bash
cd vscode-fantom
pnpm run build-debug-adapter
# or directly:
bash debug-adapter/build.sh
```

This downloads Gson, compiles all Java source files, and packages a self-contained fat JAR.

---

## 🐛 Troubleshooting

| Symptom                                            | What to check                                                                                                                                                                                                                 |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| _"Extension idle"_ on startup                      | The workspace has no `build.fan`, no `.fan` files, and no `fan.config.json`. Add one.                                                                                                                                         |
| _"fanPath not configured and FAN_HOME is not set"_ | Set `fanPath` in `fan.config.json` or export `FAN_HOME` in your shell profile.                                                                                                                                                |
| _"fan executable not found"_                       | Make sure `bin/fan` (or `bin/fan.bat` on Windows) exists in your Fantom directory.                                                                                                                                            |
| No completions / wrong completions                 | Check that your file is inside the `srcDirs` listed in `build.fan`. Files outside srcDirs are not indexed.                                                                                                                    |
| Build errors not appearing                         | Set `fanTargetBuild` in `fan.config.json` to match your build target (e.g. `"compile"`).                                                                                                                                      |
| Diagnostics too slow / too fast                    | Tune `debounceTime` in `fan.config.json` (default 2000 ms).                                                                                                                                                                   |
| LSP server crashes                                 | Open the **Fantom Language Server** output channel in VSCode and look for error messages. Enable `fantom.trace.server: "verbose"` for full protocol traces.                                                                   |
| Debug adapter JAR not found                        | Run `bash vscode-fantom/debug-adapter/build.sh` to build it. Requires JDK 11+.                                                                                                                                                |
| Breakpoints never hit                              | Confirm JDWP is enabled on the JVM (see Java configuration above). Check the port matches between `config.props` and `launch.json`.                                                                                           |
| Variables show `<not found>`                       | The variable is out of scope or the frame is no longer active. Check the Call Stack panel to select the correct frame.                                                                                                        |
| Local variables not shown (only method params)     | Rebuild your pod with `debug=true`: either set `"preLaunchRebuild": true` in `launch.json`, or manually build with `debug=true` in `etc/sys/config.props`.                                                                    |
| Program hangs on startup                           | You left `suspend=y` in `java.options`. Change to `suspend=n` or remove the line.                                                                                                                                             |
| `bind failed: Address already in use`              | Port 5005 is taken by the running FIN server's own JDWP listener. In launch mode the adapter picks a free port automatically. In attach mode use a different port. Do **not** set `JAVA_TOOL_OPTIONS` when using launch mode. |
| `-noAuth` or other launcher flags ignored          | Set `"mainClass": ""` in `launch.json` when using `fin`. The `fin` script already embeds its entry point; a non-empty `mainClass` is appended after your flags and confuses FIN's argument parser.                            |
| FIN process keeps running after Stop               | Ensure you are using the latest JAR (rebuild with `bash debug-adapter/build.sh`). Launched sessions are always force-killed on disconnect.                                                                                    |

## 🤖 AI-Assisted Development

This project is developed with the assistance of AI coding tools.

All AI-generated code is reviewed, tested against the full Fantom test suite (`fan build.fan test`), and compiled clean before being committed.

---

## 🤝 Contributing

Contributions are welcome! The LSP server lives in `src/fan/` and is written in Fantom. The VSCode extension glue code is in `vscode-fantom/src/`.

```bash
# Run Fantom tests
fan build.fan test

# Run extension grammar tests
cd vscode-fantom && pnpm run test:grammar
```

---

## 📜 License

[Academic Free License 3.0](https://opensource.org/licenses/AFL-3.0)

---

> 👻 _Happy coding with Fantom!_
