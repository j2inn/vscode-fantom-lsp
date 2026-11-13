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

        // 'using pod::Foo as Bar' makes the file refer to the type as 'Bar'
        usedName := typeName
        spaceIdx := typeName.index(" ")
        if (spaceIdx != null)
        {
          aliasPart := typeName[spaceIdx..-1].trim
          typeName = typeName[0..<spaceIdx]
          usedName = typeName
          if (aliasPart.startsWith("as ")) usedName = aliasPart["as ".size..-1].trim
        }

        if (!isTypeUsedInSource(usedName, lines, i))
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
      if (LspUtil.containsWord(line, typeName)) return true
    }
    return false
  }

}
