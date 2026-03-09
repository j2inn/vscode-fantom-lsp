
**
** Result of a complete test impact analysis.
** Links affected test class names to their BFS dependency chains.
**
class TestImpactAnalysis
{
  ** Affected test class names.
  Str[] tests

  ** For each affected test type, the BFS chain: [changedType, ..., testType].
  Str:Str[] paths

  ** Maps each type name to the basename of the source file that defines it.
  Str:Str typeToFile

  new make(Str[] tests, Str:Str[] paths, Str:Str typeToFile)
  {
    this.tests      = tests
    this.paths      = paths
    this.typeToFile = typeToFile
  }

  ** Convenience factory for an empty (no-impact) result.
  static TestImpactAnalysis empty()
  {
    Str:Str[] p := [:]
    Str:Str   t := [:]
    return TestImpactAnalysis(Str[,], p, t)
  }
}
