# vscode-fantom-lsp – Claude Code Instructions

## Environment

- Fantom runtime: `/home/agiustij2/Public/fantom-1.0.82/bin/fan` (version 1.0.82)
- `FAN_HOME` for build/test: `/home/agiustij2/Documents/sources/panasonic/commercialcloud/FIN_519/`

## Build & Test Commands

Always prefix with `FAN_HOME=...` and use the full `fan` path:

```sh
# Compile
FAN_HOME=/home/agiustij2/Documents/sources/panasonic/commercialcloud/FIN_519 \
  /home/agiustij2/Public/fantom-1.0.82/bin/fan build.fan compile

# Run all tests
FAN_HOME=/home/agiustij2/Documents/sources/panasonic/commercialcloud/FIN_519 \
  /home/agiustij2/Public/fantom-1.0.82/bin/fan build.fan test
```

## Testing Policy

- Always run `build.fan test` after fixing a bug or adding a feature.
- Every bug fix must be accompanied by a regression test in the relevant `src/test/` file.
  - Diagnostic false-positive fixes → `DiagnosticServiceTest.fan`
  - Add tests near the relevant section (e.g. "Map Type Resolution", "Method Parameter Validation").
- All tests must pass before considering the fix complete.
