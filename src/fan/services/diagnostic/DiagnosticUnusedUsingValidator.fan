**
** DiagnosticUnusedUsingValidator - Warns on unused using imports.
**
class DiagnosticUnusedUsingValidator
{
  **
  ** Warn on 'using' imports that are never referenced in the file.
  **
  LspDiagnostic[] checkUnusedUsings(Str source)
  {
    diagnostics := LspDiagnostic[,]
    lines := source.splitLines

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      trimmed := line.trim
      if (!trimmed.startsWith("using ")) continue

      rest := trimmed["using ".size..-1].trim
      if (rest.contains("[java]")) continue

      colonIdx := rest.index("::")
      if (colonIdx != null)
      {
        typeName := rest[colonIdx + 2..-1].trim
        if (typeName.isEmpty || !typeName[0].isUpper) continue

        spaceIdx := typeName.index(" ")
        if (spaceIdx != null) typeName = typeName[0..<spaceIdx]

        if (!isTypeUsedInSource(typeName, lines, i))
        {
          range := LspRange(LspPosition(i, 0), LspPosition(i, line.size))
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.warning,
            "Unused import '${typeName}'", "fantom"))
        }
      }
      else
      {
        podName := rest
        spaceIdx := podName.index(" ")
        if (spaceIdx != null) podName = podName[0..<spaceIdx]
        if (podName == "sys") continue

        pod := Pod.find(podName, false)
        if (pod == null) continue

        anyUsed := pod.types.any |t|
        {
          t.isPublic && isTypeUsedInSource(t.name, lines, i)
        }
        if (!anyUsed)
        {
          range := LspRange(LspPosition(i, 0), LspPosition(i, line.size))
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.warning,
            "Unused import '${podName}'", "fantom"))
        }
      }
    }

    return diagnostics
  }

  private Bool isTypeUsedInSource(Str typeName, Str[] lines, Int usingLineIdx)
  {
    for (i := 0; i < lines.size; i++)
    {
      if (i == usingLineIdx) continue
      line := lines[i].trim
      if (line.startsWith("using ")) continue
      if (line.startsWith("//") || line.startsWith("**") || line.startsWith("*")) continue
      if (containsIdentifier(line, typeName)) return true
    }
    return false
  }

  private Bool containsIdentifier(Str line, Str word)
  {
    idx := 0
    while (true)
    {
      found := line.index(word, idx)
      if (found == null) return false
      endPos := found + word.size
      beforeOk := found == 0 || !LspUtil.isIdentifierChar(line[found - 1])
      afterOk  := endPos >= line.size || !LspUtil.isIdentifierChar(line[endPos])
      if (beforeOk && afterOk) return true
      idx = found + 1
    }
    return false
  }
}
