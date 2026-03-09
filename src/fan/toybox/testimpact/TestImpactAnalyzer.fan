
**
** Public facade for the Test Impact Analysis subsystem.
**
** Orchestrates the full pipeline:
**   TiGitReader → TiProjectScanner → TiDependencyGraph → TiBfsEngine → TestImpactAnalysis
**
** All implementation details are hidden behind internal TiXxx classes.
** Callers interact only with this class and TestImpactAnalysis.
**
class TestImpactAnalyzer
{
  **
  ** Return the names of test classes affected by the diff between ref1 and ref2.
  **
  static Str[] findAffectedTestsFromGitDiff(File podRoot, Str ref1, Str ref2, File testDir)
  {
    hunks := TiGitReader(podRoot).readHunks(ref1, ref2)
    if (hunks == null) return Str[,]
    return runPipeline(podRoot, hunks, testDir).tests
  }

  **
  ** Return test classes affected by the given changed files (whole-file granularity).
  ** Converts each file to a synthetic hunk that covers all lines.
  **
  static Str[] findAffectedTests(File podRoot, File[] changedFiles, File testDir)
  {
    hunks := DiffHunk[,]
    changedFiles.each |f| { hunks.add(DiffHunk(f, 1, Int.maxVal)) }
    return runPipeline(podRoot, hunks, testDir).tests
  }

  **
  ** Run the full analysis (with dependency chains) for the diff between ref1 and ref2.
  **
  static TestImpactAnalysis analyzeImpactFromGitDiff(File podRoot, Str ref1, Str ref2, File testDir)
  {
    hunks := TiGitReader(podRoot).readHunks(ref1, ref2)
    if (hunks == null) return TestImpactAnalysis.empty
    return runPipeline(podRoot, hunks, testDir)
  }

  **
  ** Convenience: render analysis as a Mermaid LR diagram string.
  **
  static Str buildMermaidDiagram(TestImpactAnalysis analysis)
  {
    return TiMermaidRenderer().render(analysis).join("\n")
  }

  // ---- Private pipeline ----

  private static TestImpactAnalysis runPipeline(File podRoot, DiffHunk[] hunks, File testDir)
  {
    analyzer  := TiFanFileAnalyzer()
    scanner   := TiProjectScanner()
    fileInfos := scanner.scan(podRoot, testDir, analyzer)
    graph     := TiDependencyGraph.build(fileInfos)
    return TiBfsEngine().run(hunks, fileInfos, graph, testDir)
  }
}
