
**
** Main entry point for the Fantom Language Server
**
class Main
{
  **
  ** Main method - starts the LSP server
  **
  static Void main(Str[] args := Str#.emptyList)
  {
    // --test-impact <pod-root> --diff <ref1> <ref2> [--test-dir <path>]
    // Outputs test class names affected by the git diff between two refs.
    // <ref1>/<ref2> can be commit hashes or branch names.
    // --test-dir defaults to <pod-root>/test/
    if (!args.isEmpty && args[0] == "--test-impact")
    {
      if (args.size < 5 || args[2] != "--diff")
      {
        Env.cur.err.printLine("Usage: fan vscodeFantomLsp --test-impact <pod-root> --diff <ref1> <ref2> [--test-dir <path>]")
        Env.cur.exit(1)
        return
      }
      podRoot := File.os(args[1]).normalize
      ref1    := args[3]
      ref2    := args[4]

      // Optional --test-dir (default: <pod-root>/test/)
      testDir := podRoot + `test/`
      tdIdx := args.index("--test-dir")
      if (tdIdx != null && tdIdx + 1 < args.size)
        testDir = File.os(args[tdIdx + 1]).normalize

      affected := TestImpactAnalyzer.findAffectedTestsFromGitDiff(podRoot, ref1, ref2, testDir)
      affected.each |t| { echo(t) }
      return
    }

    try
    {
      LspProtocol.logInfo("Starting Fantom Language Server")

      // Service wiring via LspModule (simple IoC registry)
      module := LspModule()
      server := module.server

      // Get stdin
      in := Env.cur.in

      // Main loop - read messages from stdin
      while (true)
      {
        // Read message
        message := LspProtocol.readMessage(in)
        if (message == null) break  // EOF

        // Handle message
        server.handleMessage(message)

        // Check for exit
        if (message["method"] == "exit")
          break
      }

      LspProtocol.logInfo("Fantom Language Server stopped")
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Fatal error: $e")
      e.trace
    }
  }
}
