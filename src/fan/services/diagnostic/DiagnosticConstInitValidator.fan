**
** DiagnosticConstInitValidator - Warns when a const static field initializer
** references a field from a different class.
**
** In Fantom, const static fields are initialized when a class is first loaded.
** If class B contains:
**
**   const static Str v2 := A.v1
**
** and class A has not been loaded yet when B's static initializer runs,
** 'A.v1' evaluates to null (A's statics haven't been set). Compilation
** succeeds but the runtime value of 'v2' will be null.
**
class DiagnosticConstInitValidator
{
  LspDiagnostic[] checkCrossClassConstInit(Str source)
  {
    diagnostics := LspDiagnostic[,]
    lines := source.splitLines
    curClass := ""

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      trimmed := line.trim

      if (trimmed.isEmpty || trimmed.startsWith("//") ||
          trimmed.startsWith("**") || trimmed.startsWith("*")) continue

      // Track the current class / mixin name as we scan
      detected := parseClassName(trimmed)
      if (detected != null) curClass = detected

      // Only inspect lines that declare a const static field with an initializer
      if (!containsIdentifier(trimmed, "const")) continue
      if (!containsIdentifier(trimmed, "static")) continue
      walrusIdx := trimmed.index(":=")
      if (walrusIdx == null) continue

      rhs := trimmed[walrusIdx + 2 ..-1].trim

      crossRef := findCrossClassRef(rhs, curClass)
      if (crossRef == null) continue

      // Locate the cross-class reference in the original (non-trimmed) line,
      // searching only in the RHS portion so we don't match the type annotation.
      walrusInLine := line.index(":=")
      searchFrom := walrusInLine != null ? walrusInLine : 0
      col := line.index(crossRef, searchFrom) ?: 0

      range := LspRange(
        LspPosition(i, col),
        LspPosition(i, col + crossRef.size)
      )

      dotIdx := crossRef.index(".")
      refClass := dotIdx != null ? crossRef[0..<dotIdx] : crossRef

      diagnostics.add(LspDiagnostic(
        range,
        DiagnosticSeverity.warning,
        "const static initializer references '${crossRef}': '${refClass}' may not be loaded yet, causing a null value at runtime",
        "fantom"
      ))
    }

    return diagnostics
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  **
  ** Return the class/mixin name declared on the given trimmed line, or null.
  **
  private Str? parseClassName(Str trimmed)
  {
    keywords := ["class ", "mixin "]
    for (ki := 0; ki < keywords.size; ki++)
    {
      kw := keywords[ki]
      idx := trimmed.index(kw)
      if (idx == null) continue
      // 'class'/'mixin' must not be part of a longer identifier
      if (idx > 0 && LspUtil.isIdentifierChar(trimmed[idx - 1])) continue

      rest := trimmed[idx + kw.size ..-1].trim
      end := 0
      while (end < rest.size && LspUtil.isIdentifierChar(rest[end])) end++
      if (end > 0 && rest[0].isUpper) return rest[0..<end]
    }
    return null
  }

  **
  ** Scan 'rhs' for the first 'UpperCaseName.fieldName' pattern where
  ** 'UpperCaseName' differs from 'curClass'.
  ** Method calls (identifier immediately followed by '(') are skipped —
  ** they load the target class on entry and are not subject to this issue.
  **
  private Str? findCrossClassRef(Str rhs, Str curClass)
  {
    idx := 0
    while (idx < rhs.size)
    {
      dotPos := rhs.index(".", idx)
      if (dotPos == null) break
      if (dotPos == 0) { idx = 1; continue }

      // Walk back to collect the identifier before the dot
      start := dotPos - 1
      while (start > 0 && LspUtil.isIdentifierChar(rhs[start - 1])) start--
      className := rhs[start..<dotPos]

      // Must be an uppercase identifier (type name, not a variable)
      if (className.isEmpty || !className[0].isUpper)
      {
        idx = dotPos + 1
        continue
      }

      // Same class reference — not a cross-class issue
      if (className == curClass)
      {
        idx = dotPos + 1
        continue
      }

      // Walk forward to collect the identifier after the dot
      fieldStart := dotPos + 1
      fieldEnd := fieldStart
      while (fieldEnd < rhs.size && LspUtil.isIdentifierChar(rhs[fieldEnd])) fieldEnd++

      if (fieldStart == fieldEnd)
      {
        idx = dotPos + 1
        continue
      }

      // Skip method calls: they trigger class loading and are safe
      if (fieldEnd < rhs.size && rhs[fieldEnd] == '(')
      {
        idx = dotPos + 1
        continue
      }

      return "${className}.${rhs[fieldStart..<fieldEnd]}"
    }
    return null
  }

  **
  ** Return true if 'word' appears in 'line' as a standalone identifier
  ** (not a substring of a longer identifier).
  **
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
