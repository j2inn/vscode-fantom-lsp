// Minimal build file — present so the extension's workspaceContains:build.fan
// activation event fires when this directory is opened as the test workspace.
using build

class Build : BuildPod
{
  new make()
  {
    podName = "testPod"
    version = Version("1.0")
    srcDirs = [`fan/`]
  }
}
