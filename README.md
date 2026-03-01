# 👻 VSCode Fantom LSP

[![License: AFL-3.0](https://img.shields.io/badge/license-AFL--3.0-blue?style=flat-square)](https://opensource.org/licenses/AFL-3.0)
[![AI assisted](https://img.shields.io/badge/AI%20assisted-Qwen2.5%20Coder-6B6EF9?style=flat-square&logo=openai&logoColor=white)](https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct)
[![Buy me a coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-PayPal-00457C?style=flat-square&logo=paypal&logoColor=white)](paypal.me/AndreaTGiusti)

> **Unofficial** Language Server Protocol support for [Fantom](https://fantom.org/) in Visual Studio Code.

This extension brings a rich developer experience to Fantom projects inside VSCode — syntax highlighting, real-time diagnostics, autocompletion, hover docs, go-to-definition, and more. It is powered by a Fantom LSP server written entirely in Fantom itself (`vscodeFantomLsp`), automatically deployed into your Fantom installation when the extension activates.

⚠️ This is an **unofficial, community-driven** project. It is not affiliated with or endorsed by the Fantom language authors.

---

## ✨ Features

### ✅ Implemented

| Feature                                   | Description                                                                               |
| ----------------------------------------- | ----------------------------------------------------------------------------------------- |
| 🔍 **Go to Definition**                   | Jump to the definition of types, methods, and fields across project files                 |
| 💡 **Auto Completion**                    | Context-aware suggestions triggered on `.` (dot) and keyword prefix                       |
| ⇥ **Tab Completion**                      | Complete identifiers and keywords without reaching for the mouse                          |
| 🔁 **Duplicate `static const` detection** | Warns when two or more static const fields share the same string value across the project |
| 🗑️ **Unused variable detection**          | Highlights variables that are declared but never read                                     |
| 🧹 **Unused import detection**            | Warns on `using` statements that are not referenced in the file                           |
| 🎯 **Hover information**                  | Shows type signatures and pod documentation when hovering over a symbol                   |
| 🚨 **Real-time diagnostics**              | Syntax errors and type errors from the Fantom compiler, debounced while typing            |
| 🔗 **Cross-file validation**              | Detects unresolved type references across all project source files                        |
| 🏗️ **Build integration**                  | Runs `fan build.fan` on save and reports compiler errors with clickable file links        |
| 🖊️ **Syntax highlighting**                | Full TextMate grammar for `.fan` files                                                    |
| 🧩 **Remove Unused Imports**              | Command to remove all unused `using` lines in a file or the whole project                 |
| 🧩 **Remove Unused Variables**            | Command to remove all unused variable declarations in a file or the whole project         |
| 📊 **Status bar diagnostics**             | Live error and warning counts in the VSCode status bar                                    |

### 🔜 Coming Soon / Not Yet Implemented

| Feature         | Notes                                                      |
| --------------- | ---------------------------------------------------------- |
| 🐛 **Debugger** | A Fantom debug adapter is in the works — coming very soon! |

---

## 📋 Requirements

- **Fantom** ≥ 1.0.80 installed locally — [Download](https://fantom.org/sidewalk/topic/2782)
- **Java** (JDK or JRE) available in your `PATH` or via `JAVA_HOME`
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

# 2. Build the VSCode extension
cd vscode-fantom
npm install
npm run compile

# 3. Package (optional)
npx @vscode/vsce package
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

| Setting                   | Type      | Default | Description                                                                                                                                |
| ------------------------- | --------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `fantom.javaPath`         | `string`  | `""`    | Full path to the `java` executable. Defaults to `$JAVA_HOME/bin/java`, then just `java` from `PATH`.                                       |
| `fantom.useBuiltInLspPod` | `boolean` | `true`  | Use the `vscodeFantomLsp` bundled with the extension (recommended). Set to `false` only if you have built and installed your own LSP pod.  |
| `fantom.pedanticMode`     | `boolean` | `false` | Warn on local variable declarations that lack an explicit type annotation (neither a type on the left side nor an `as` cast on the right). |
| `fantom.trace.server`     | `string`  | `"off"` | Trace LSP message traffic: `"off"`, `"messages"`, or `"verbose"`. Useful for debugging the extension itself.                               |

---

## 🛠️ Commands

Access these from the Command Palette (`Ctrl+Shift+P`):

| Command                                        | Description                                                          |
| ---------------------------------------------- | -------------------------------------------------------------------- |
| **Fantom: Remove Unused Imports in File**      | Deletes all unused `using` lines in the current file and saves       |
| **Fantom: Remove Unused Imports in Project**   | Deletes unused `using` lines across every `.fan` file in the project |
| **Fantom: Remove Unused Variables in File**    | Deletes unused variable declarations in the current file             |
| **Fantom: Remove Unused Variables in Project** | Deletes unused variable declarations across the whole project        |

---

## 🏗️ How It Works

```
VSCode Extension (TypeScript)
        │
        │  stdio (LSP protocol)
        ▼
  vscodeFantomLsp  ─── fan lsp::Main
        │
        ├── ProjectIndex      (AST index of all .fan sources)
        ├── DiagnosticService (single-file + cross-file analysis)
        ├── CompletionService (dot-completion, keyword suggestions)
        ├── DefinitionService (go-to-definition)
        ├── HoverService      (type signatures, pod docs)
        └── fan build.fan     (real compiler, error reporting)
```

On activation the extension:

1. Reads `fan.config.json` (or falls back to `FAN_HOME`).
2. Deploys (or updates) `vscodeFantomLsp` into `$FAN_HOME/lib/fan/`.
3. Spawns the LSP server via `fan lsp::Main`.
4. The server indexes all `.fan` sources from `build.fan`'s `srcDirs`, pre-loads available pods, runs diagnostics, and performs an initial build check — all in the background so the editor stays responsive.

### Diagnostics lifecycle

- **While typing** — changes are debounced (`debounceTime` ms). No analysis runs until typing pauses.
- **After the debounce window** — single-file analysis runs immediately for fast feedback.
- **On save** — a full project re-index, cross-file validation, and `fan build.fan` all run together.

---

## 🐛 Troubleshooting

| Symptom                                            | What to check                                                                                                                                               |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| _"Extension idle"_ on startup                      | The workspace has no `build.fan`, no `.fan` files, and no `fan.config.json`. Add one.                                                                       |
| _"fanPath not configured and FAN_HOME is not set"_ | Set `fanPath` in `fan.config.json` or export `FAN_HOME` in your shell profile.                                                                              |
| _"fan executable not found"_                       | Make sure `bin/fan` (or `bin/fan.bat` on Windows) exists in your Fantom directory.                                                                          |
| No completions / wrong completions                 | Check that your file is inside the `srcDirs` listed in `build.fan`. Files outside srcDirs are not indexed.                                                  |
| Build errors not appearing                         | Set `fanTargetBuild` in `fan.config.json` to match your build target (e.g. `"compile"`).                                                                    |
| Diagnostics too slow / too fast                    | Tune `debounceTime` in `fan.config.json` (default 2000 ms).                                                                                                 |
| LSP server crashes                                 | Open the **Fantom Language Server** output channel in VSCode and look for error messages. Enable `fantom.trace.server: "verbose"` for full protocol traces. |

---

## 🤝 Contributing

Contributions are welcome! The LSP server lives in `src/fan/` and is written in Fantom. The VSCode extension glue code is in `vscode-fantom/src/`.

```bash
# Run Fantom tests
fan build.fan test

# Run extension grammar tests
cd vscode-fantom && npm run test:grammar
```

---

## ☕ Support

If this extension saves you time and you'd like to say thanks, a coffee is always appreciated! 👻

[![Buy me a coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-PayPal-00457C?style=for-the-badge&logo=paypal&logoColor=white)](paypal.me/AndreaTGiusti)

---

## 📜 License

[Academic Free License 3.0](https://opensource.org/licenses/AFL-3.0)

---

> 👻 _Happy coding with Fantom!_
