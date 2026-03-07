**
** DiagnosticUnusedVarValidator - Warns on unused local variables and private fields.
**
class DiagnosticUnusedVarValidator
{
  LspDiagnostic[] checkUnusedVars(Str source)
  {
    diagnostics := LspDiagnostic[,]
    lines := source.splitLines
    modifierWords := ["public", "private", "protected", "internal",
                      "static", "const", "final", "abstract",
                      "virtual", "override", "native", "once", "readonly"]

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      trimmed := line.trim

      if (trimmed.isEmpty || trimmed.startsWith("//") ||
          trimmed.startsWith("**") || trimmed.startsWith("*")) continue

      indent := 0
      while (indent < line.size && line[indent] == ' ') indent++

      walrusIdx := trimmed.index(":=")

      if (trimmed.startsWith("private "))
      {
        if (trimmed.contains("(")) continue

        fieldDecl := walrusIdx != null ? trimmed[0..<walrusIdx].trim : trimmed
        if (fieldDecl.contains("{")) continue

        stripped := fieldDecl["private ".size..-1].trim
        modifierWords.each |mod|
        {
          while (stripped.startsWith("${mod} "))
            stripped = stripped[mod.size + 1 ..-1].trim
        }

        words := stripped.split(' ').findAll |w| { !w.isEmpty }
        if (words.size < 2) continue

        fieldName := words[-1]
        if (fieldName.isEmpty || !fieldName[0].isLower) continue
        if (fieldName == "_" || fieldName == "it" || fieldName.startsWith("_")) continue

        if (!isNameUsedInFile(lines, fieldName, i))
        {
          col := findIdentifierPos(line, fieldName) ?: 0
          range := LspRange(LspPosition(i, col), LspPosition(i, col + fieldName.size))
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.warning,
            "'${fieldName}' is declared but never used", "fantom"))
        }
        continue
      }

      if (walrusIdx != null && indent >= 4)
      {
        if (trimmed.startsWith("for ") || trimmed.startsWith("for(")) continue
        if (trimmed.startsWith("catch ") || trimmed.startsWith("catch(")) continue

        lhs := trimmed[0..<walrusIdx].trim
        if (lhs.isEmpty) continue

        stripped := lhs
        modifierWords.each |mod|
        {
          while (stripped.startsWith("${mod} "))
            stripped = stripped[mod.size + 1 ..-1].trim
        }

        words := stripped.split(' ').findAll |w| { !w.isEmpty }
        if (words.size != 1) continue

        varName := words[0]
        if (varName.isEmpty || !varName[0].isLower) continue
        if (varName == "_" || varName == "it" || varName.startsWith("_")) continue

        if (!isNameUsedAfterLine(lines, varName, i))
        {
          col := findIdentifierPos(line, varName) ?: 0
          range := LspRange(LspPosition(i, col), LspPosition(i, col + varName.size))
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.warning,
            "'${varName}' is declared but never used", "fantom"))
        }
      }
    }

    return diagnostics
  }

  private Int? findIdentifierPos(Str line, Str word)
  {
    idx := 0
    while (true)
    {
      found := line.index(word, idx)
      if (found == null) return null
      endPos := found + word.size
      beforeOk := found == 0 || !LspUtil.isIdentifierChar(line[found - 1])
      afterOk  := endPos >= line.size || !LspUtil.isIdentifierChar(line[endPos])
      if (beforeOk && afterOk) return found
      idx = found + 1
    }
    return null
  }

  private Bool isNameUsedInFile(Str[] lines, Str name, Int excludeLine)
  {
    for (i := 0; i < lines.size; i++)
    {
      if (i == excludeLine) continue
      ln := lines[i].trim
      if (ln.startsWith("//") || ln.startsWith("**") || ln.startsWith("*")) continue
      if (containsIdentifier(lines[i], name)) return true
    }
    return false
  }

  private Bool isNameUsedAfterLine(Str[] lines, Str name, Int fromLine)
  {
    for (i := fromLine + 1; i < lines.size; i++)
    {
      ln := lines[i].trim
      if (ln.startsWith("//") || ln.startsWith("**") || ln.startsWith("*")) continue
      if (containsIdentifier(lines[i], name)) return true
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
