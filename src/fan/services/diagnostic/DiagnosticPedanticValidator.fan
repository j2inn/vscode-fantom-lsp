**
** DiagnosticPedanticValidator - Pedantic checks for explicit type declarations.
**
class DiagnosticPedanticValidator
{
  **
  ** Check for := declarations without explicit types.
  **
  LspDiagnostic[] checkUntypedDeclarations(Str source)
  {
    diagnostics := LspDiagnostic[,]
    lines := source.splitLines

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      trimmed := line.trim

      if (trimmed.isEmpty || trimmed.startsWith("//") ||
          trimmed.startsWith("**") || trimmed.startsWith("*") ||
          trimmed.startsWith("using ")) continue

      walrusIdx := trimmed.index(":=")
      if (walrusIdx == null) continue

      if (trimmed.startsWith("for ") || trimmed.startsWith("for(")) continue
      if (trimmed.startsWith("catch ") || trimmed.startsWith("catch(")) continue

      lhs := trimmed[0..<walrusIdx].trim
      rhs := trimmed[walrusIdx + 2 ..-1].trim

      if (lhs.isEmpty || rhs.isEmpty) continue

      stripped := lhs
      modifiers := ["public", "private", "protected", "internal",
                    "static", "const", "final", "abstract",
                    "virtual", "override", "native", "once", "readonly"]
      modifiers.each |mod|
      {
        while (stripped.startsWith("${mod} "))
          stripped = stripped[mod.size + 1 ..-1].trim
      }

      words := stripped.split(' ').findAll |w| { !w.isEmpty }
      hasExplicitType := words.size >= 2 && words[0].size > 0 && words[0][0].isUpper

      if (hasExplicitType) continue
      if (rhs.contains(" as ")) continue

      varName := words.size >= 1 ? words[-1] : lhs

      origWalrus := line.index(":=")
      if (origWalrus == null) continue

      varStart := line.index(varName)
      if (varStart == null) varStart = 0

      range := LspRange(
        LspPosition(i, varStart),
        LspPosition(i, origWalrus + 2)
      )
      diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.warning,
        "'${varName}' declared without explicit type", "fantom-pedantic"))
    }

    return diagnostics
  }
}
