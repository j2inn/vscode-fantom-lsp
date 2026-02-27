#! /usr/bin/env fan

using build

**
** Build: vscode-fantom-lsp
**
class Build : BuildPod
{
  new make()
  {
    podName = "vscode-fantom-lsp"
    summary = "Language Server Protocol for Fantom"
    meta    = ["org.name":     "Fantom",
               "org.uri":      "https://fantom.org/",
               "proj.name":    "Fantom Core",
               "proj.uri":     "https://fantom.org/",
               "license.name": "Academic Free License 3.0",
               "vcs.name":     "Git",
               "vcs.uri":      "https://github.com/fantom-lang/fantom"]
    depends = ["sys 1.0", "compiler 1.0", "util 1.0", "concurrent 1.0"]
    srcDirs = [`src/fan/`, `src/fan/protocol/`, `src/fan/services/`, `src/fan/compiler/`, `src/fan/util/`, `src/test/`]
    resDirs = [`src/res/`]
    docSrc  = true
  }
}
