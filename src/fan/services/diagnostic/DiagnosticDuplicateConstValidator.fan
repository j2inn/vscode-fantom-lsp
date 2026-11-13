**
** DiagnosticDuplicateConstValidator - Detects duplicate static const string values.
**
class DiagnosticDuplicateConstValidator
{
  ** Duplicates are only reported within one pod: 'podOf' maps a file URI to
  ** its pod name, so equal values in different pods are not flagged.
  [Str:LspDiagnostic[]] checkDuplicateConstValues([Str:Str] sources, |Str->Str?|? podOf := null)
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

        if (!LspUtil.containsWord(trimmed, "const")) continue

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
        podName := podOf?.call(fileUri) ?: ""
        groupKey := podName + "\u0000" + strVal
        existing := valueMap[groupKey]
        if (existing == null) { existing = Str[,]; valueMap[groupKey] = existing }
        existing.add(record)
      }
    }

    result := Str:LspDiagnostic[][:]
    valueMap.each |occList, groupKey|
    {
      if (occList.size < 2) return
      strVal := groupKey[(groupKey.index("\u0000") + 1)..-1]

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
        col := varName.isEmpty ? 0 : (LspUtil.findWord(lineText, varName) ?: 0)

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

}
