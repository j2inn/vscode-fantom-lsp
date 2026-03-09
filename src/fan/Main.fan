
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
    // --test-impact <pod-root> --diff <ref1> [<ref2>] [--test-dir <path>] [--graph] [--mermaid]
    // Outputs test class names affected by the git diff between two refs.
    // <ref1>/<ref2> can be commit hashes or branch names.
    // If only one ref is provided, the current branch (HEAD) is used as source (ref1)
    // and the given ref is used as target (ref2).
    // --test-dir defaults to <pod-root>/test/
    // --graph    prints the dependency chain that links each test to a changed type
    // --mermaid  prints a Mermaid LR graph of those chains
    if (!args.isEmpty && args[0] == "--test-impact")
    {
      if (args.size < 4 || args[2] != "--diff")
      {
        Env.cur.err.printLine("Usage: fan vscodeFantomLsp --test-impact <pod-root> --diff <ref1> [<ref2>] [--test-dir <path>] [--graph] [--mermaid]")
        Env.cur.exit(1)
        return
      }
      podRoot := File.os(args[1]).normalize
      // If a second ref is present (and is not a flag), use ref1/ref2 as given.
      // Otherwise default ref1 to HEAD (current branch) and treat the single arg as ref2.
      ref1 := (args.size > 4 && !args[4].startsWith("--")) ? args[3] : "HEAD"
      ref2 := (args.size > 4 && !args[4].startsWith("--")) ? args[4] : args[3]

      // Optional --test-dir (default: <pod-root>/test/)
      testDir := podRoot + `test/`
      tdIdx := args.index("--test-dir")
      if (tdIdx != null && tdIdx + 1 < args.size)
        testDir = File.os(args[tdIdx + 1]).normalize

      showGraph   := args.contains("--graph")
      showMermaid := args.contains("--mermaid")

      // Strategy Pattern: select the output renderer based on the requested format
      analysis := TestImpactAnalyzer.analyzeImpactFromGitDiff(podRoot, ref1, ref2, testDir)
      Str[] output := Str[,]
      if (showMermaid)    output = TiMermaidRenderer().render(analysis)
      else if (showGraph) output = TiGraphRenderer().render(analysis)
      else                output = TiPlainRenderer().render(analysis)
      output.each |line| { echo(line) }
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
