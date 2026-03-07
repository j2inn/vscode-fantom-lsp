**
** DiagnosticDuplicateConstValidator - Detects duplicate static const string values.
**
class DiagnosticDuplicateConstValidator
{
  [Str:LspDiagnostic[]] checkDuplicateConstValues([Str:Str] sources)
  {
    valueMap := Str:Str[][:]

    sources.each |source, fileUri|
    {
      lines := source.splitLines
      for (i := 0; i < lines.size; i++)
      {
        line := lines[i]
        trimmed := line.trim

        if (trimmed.isEmpty || trimmed.startsWith("//") ||
            trimmed.startsWith("**") || trimmed.startsWith("*")) continue

        if (!containsIdentifier(trimmed, "const")) continue

        walrusIdx := trimmed.index(":=")
        if (walrusIdx == null) continue

        rhs := trimmed[walrusIdx + 2 ..-1].trim
        if (rhs.isEmpty || rhs[0] != '"') continue

        strVal := extractStringLiteral(rhs)
        if (strVal == null || strVal.size < 5) continue

        lhs := trimmed[0..<walrusIdx].trim
        words := lhs.split(' ').findAll |w| { !w.isEmpty }
        varName := words.isEmpty ? "" : words[-1]

        record := "${fileUri}\t${i}\t${varName}"
        existing := valueMap[strVal]
        if (existing == null) { existing = Str[,]; valueMap[strVal] = existing }
        existing.add(record)
      }
    }

    result := Str:LspDiagnostic[][:]
    valueMap.each |occList, strVal|
    {
      if (occList.size < 2) return

      displayVal := strVal.size > 30 ? strVal[0..29] + "..." : strVal

      occList.each |record|
      {
        parts := record.split('\t')
        fileUri := parts[0]
        lineNum := parts[1].toInt(10, false) ?: 0
        varName := parts.size > 2 ? parts[2] : ""

        source := sources[fileUri] ?: ""
        srcLines := source.splitLines
        lineText := lineNum < srcLines.size ? srcLines[lineNum] : ""
        col := varName.isEmpty ? 0 : (findIdentifierPos(lineText, varName) ?: 0)

        range := LspRange(
          LspPosition(lineNum, col),
          LspPosition(lineNum, col + varName.size)
        )
        msg := "Duplicate const value \"${displayVal}\" found in ${occList.size} places"
        diag := LspDiagnostic(range, DiagnosticSeverity.warning, msg, "fantom")

        if (!result.containsKey(fileUri)) result[fileUri] = LspDiagnostic[,]
        result[fileUri].add(diag)
      }
    }

    return result
  }

  private Str? extractStringLiteral(Str s)
  {
    if (s.isEmpty || s[0] != '"') return null
    buf := StrBuf()
    i := 1
    while (i < s.size)
    {
      ch := s[i]
      if (ch == '\\') { i += 2; continue }
      if (ch == '"') return buf.toStr
      buf.addChar(ch)
      i++
    }
    return null
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
