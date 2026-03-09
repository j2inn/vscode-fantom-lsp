
// ============================================================================
// IImpactRenderer implementations — Strategy Pattern
// ============================================================================

**
** Renders the impact analysis as a plain list of affected test class names.
** One name per line, suitable for piping directly to fant.
**
class TiPlainRenderer : IImpactRenderer
{
  override Str[] render(TestImpactAnalysis analysis)
  {
    return analysis.tests
  }
}

// ----------------------------------------------------------------------------

**
** Renders the impact analysis as annotated dependency chains.
**
** Format per line:
**   TestClass: SeedType (source.fan) → Intermediate → TestClass
**
class TiGraphRenderer : IImpactRenderer
{
  override Str[] render(TestImpactAnalysis analysis)
  {
    if (analysis.tests.isEmpty)
      return ["No affected tests found."]

    lines := Str[,]
    analysis.tests.each |t|
    {
      path := analysis.paths[t]
      if (path == null || path.isEmpty)
      {
        lines.add(t + ": " + t)
      }
      else
      {
        seed    := path.first
        file    := analysis.typeToFile[seed]
        label   := file != null ? "${seed} (${file})" : seed
        rest    := path.size > 1 ? path[1..-1] : Str[,]
        labeled := Str[,]
        labeled.add(label)
        labeled.addAll(rest)
        lines.add(t + ": " + labeled.join(" \u2192 "))
      }
    }
    return lines
  }
}

// ----------------------------------------------------------------------------

**
** Renders the impact analysis as a Mermaid LR diagram.
** Changed (seed) nodes are styled blue; test nodes are styled orange.
**
class TiMermaidRenderer : IImpactRenderer
{
  override Str[] render(TestImpactAnalysis analysis)
  {
    buf := StrBuf()
    buf.add("graph LR\n")

    Str:Bool testNodes := [:]
    Str:Bool seedNodes := [:]
    analysis.tests.each |t| { testNodes[t] = true }
    analysis.paths.each |path, t|
    {
      if (!path.isEmpty) seedNodes[path.first] = true
    }

    // Collect unique edges from all dependency paths
    Str:Bool edgeSet := [:]
    analysis.paths.each |path, t|
    {
      for (i := 0; i < path.size - 1; i++)
        edgeSet["    ${path[i]} --> ${path[i+1]}\n"] = true
    }

    // Emit node declarations with role labels
    Str:Bool allNodes := [:]
    analysis.paths.vals.each |path| { path.each |n| { allNodes[n] = true } }
    allNodes.keys.each |node|
    {
      label := node
      if (seedNodes.containsKey(node) && testNodes.containsKey(node))
        label = "${node} (changed + test)"
      else if (seedNodes.containsKey(node))
        label = "${node} (changed)"
      else if (testNodes.containsKey(node))
        label = "${node} (test)"
      buf.add("    ${node}[\"${label}\"]\n")
    }

    // Emit edges
    edgeSet.keys.each |e| { buf.add(e) }

    // Emit style classes
    if (!testNodes.isEmpty)
    {
      buf.add("    classDef testNode fill:#f96,stroke:#333,color:#000\n")
      testNodes.keys.each |n| { buf.add("    class ${n} testNode\n") }
    }
    if (!seedNodes.isEmpty)
    {
      buf.add("    classDef changedNode fill:#6af,stroke:#333,color:#000\n")
      seedNodes.keys.each |n|
      {
        if (!testNodes.containsKey(n)) buf.add("    class ${n} changedNode\n")
      }
    }

    return [buf.toStr]
  }
}
