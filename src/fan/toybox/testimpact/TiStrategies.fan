
**
** Strategy interface for analyzing a single .fan source file.
** Decouples the parsing logic from the impact pipeline so that
** alternative or mock implementations can be substituted.
**
internal mixin IFanFileAnalyzer
{
  ** Analyze the given .fan file and return its structural information.
  abstract FanFileInfo analyzeFile(File f)
}

// ---------------------------------------------------------------------------

**
** Strategy interface for rendering a TestImpactAnalysis to lines of output.
** Callers select a concrete renderer based on the desired output format
** (plain list, annotated graph chains, or Mermaid diagram).
**
mixin IImpactRenderer
{
  ** Render the analysis result.
  ** Returns one output element per list entry (print each with echo).
  abstract Str[] render(TestImpactAnalysis analysis)
}
