**
** DiagnosticNullableUsageValidator - Warns on nullable usage without null guards.
**
class DiagnosticNullableUsageValidator
{
  LspDiagnostic[] checkNullableUsage(Str source)
  {
    diagnostics := LspDiagnostic[,]
    lines := source.splitLines

    nullableVars := Str:Bool[:]
    safeVars := Str:Bool[:]
    condSafeDepths := Str:Int[:]
    braceDepth := 0
    inMethodBody := false

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      trimmed := line.trim

      if (trimmed.isEmpty || trimmed.startsWith("//") ||
          trimmed.startsWith("**") || trimmed.startsWith("*")) continue

      indent := 0
      while (indent < line.size && line[indent] == ' ') indent++

      if (indent == 2)
      {
        if (trimmed.contains("(") && !trimmed.startsWith("@") &&
            !trimmed.startsWith("**") && !trimmed.startsWith("//"))
        {
          nullableVars = Str:Bool[:]
          safeVars = Str:Bool[:]
          condSafeDepths = Str:Int[:]
          braceDepth = 0
          inMethodBody = false
          parseNullableParams(trimmed, nullableVars)
        }
        if (trimmed == "{") inMethodBody = true
        if (trimmed == "}") inMethodBody = false
        continue
      }

      if (!inMethodBody) continue

      opens := 0; closes := 0
      for (ci := 0; ci < trimmed.size; ci++)
      {
        ch := trimmed[ci]
        if (ch == '{') opens++
        else if (ch == '}') closes++
      }

      braceDepth += opens

      walrusIdx := trimmed.index(":=")
      if (walrusIdx != null && !trimmed.startsWith("for ") && !trimmed.startsWith("for("))
      {
        lhs := trimmed[0..<walrusIdx].trim
        words := lhs.split(' ').findAll |w| { !w.isEmpty }
        if (words.size >= 2)
        {
          typeWord := words[-2]
          varName  := words[-1]
          if (!typeWord.isEmpty && typeWord.endsWith("?") && typeWord[0].isUpper &&
              !varName.isEmpty && varName[0].isLower)
            nullableVars[varName] = true
        }
      }

      nullEqVar := extractNullEqualVar(trimmed)
      if (nullEqVar != null && nullableVars.containsKey(nullEqVar) &&
          !safeVars.containsKey(nullEqVar))
      {
        if (lineOrNextHasEarlyExit(lines, i))
          safeVars[nullEqVar] = true
      }

      nullNeqVar := extractNullNotEqualVar(trimmed)
      if (nullNeqVar != null && nullableVars.containsKey(nullNeqVar) &&
          !safeVars.containsKey(nullNeqVar))
      {
        condSafeDepths[nullNeqVar] = opens > 0 ? braceDepth : braceDepth + 1
      }

      nullableVars.keys.each |varName|
      {
        if (safeVars.containsKey(varName)) return

        if (condSafeDepths.containsKey(varName))
        {
          condDepth := condSafeDepths[varName] ?: 0
          if (braceDepth >= condDepth) return
        }

        usageCol := findNullableUsage(line, varName)
        if (usageCol != null)
        {
          range := LspRange(LspPosition(i, usageCol), LspPosition(i, usageCol + varName.size))
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.warning,
            "'${varName}' might be null", "fantom"))
        }
      }

      braceDepth -= closes
      if (braceDepth < 0) braceDepth = 0

      if (closes > 0)
      {
        toRemove := Str[,]
        condSafeDepths.each |minDepth, varName|
        {
          if (braceDepth < minDepth) toRemove.add(varName)
        }
        toRemove.each |varName| { condSafeDepths.remove(varName) }
      }
    }

    return diagnostics
  }

  private Void parseNullableParams(Str trimmedLine, Str:Bool nullableVars)
  {
    parenOpen := trimmedLine.index("(")
    if (parenOpen == null) return
    parenClose := trimmedLine.indexr(")")
    if (parenClose == null || parenClose <= parenOpen) return

    paramStr := trimmedLine[parenOpen + 1 ..< parenClose].trim
    if (paramStr.isEmpty) return

    paramStr.split(',').each |param|
    {
      p := param.trim
      if (p.isEmpty) return

      defIdx := p.index(":=")
      core := defIdx != null ? p[0..<defIdx].trim : p

      parts := core.split(' ').findAll |w| { !w.isEmpty }
      if (parts.size >= 2)
      {
        typeWord  := parts[0]
        paramName := parts[-1]
        if (!typeWord.isEmpty && typeWord.endsWith("?") && typeWord[0].isUpper &&
            !paramName.isEmpty && paramName[0].isLower)
          nullableVars[paramName] = true
      }
    }
  }

  private Str? extractNullEqualVar(Str trimmed)
  {
    eqIdx := trimmed.index(" == null")
    if (eqIdx != null && eqIdx > 0)
    {
      end := eqIdx
      start := end - 1
      while (start > 0 && LspUtil.isIdentifierChar(trimmed[start - 1])) start--
      if (start < end)
      {
        varName := trimmed[start..<end]
        if (!varName.isEmpty && varName[0].isLower) return varName
      }
    }

    nullEqIdx := trimmed.index("null == ")
    if (nullEqIdx != null)
    {
      start := nullEqIdx + "null == ".size
      end := start
      while (end < trimmed.size && LspUtil.isIdentifierChar(trimmed[end])) end++
      if (start < end)
      {
        varName := trimmed[start..<end]
        if (!varName.isEmpty && varName[0].isLower) return varName
      }
    }
    return null
  }

  private Str? extractNullNotEqualVar(Str trimmed)
  {
    neIdx := trimmed.index(" != null")
    if (neIdx != null && neIdx > 0)
    {
      end := neIdx
      start := end - 1
      while (start > 0 && LspUtil.isIdentifierChar(trimmed[start - 1])) start--
      if (start < end)
      {
        varName := trimmed[start..<end]
        if (!varName.isEmpty && varName[0].isLower) return varName
      }
    }

    nullNeIdx := trimmed.index("null != ")
    if (nullNeIdx != null)
    {
      start := nullNeIdx + "null != ".size
      end := start
      while (end < trimmed.size && LspUtil.isIdentifierChar(trimmed[end])) end++
      if (start < end)
      {
        varName := trimmed[start..<end]
        if (!varName.isEmpty && varName[0].isLower) return varName
      }
    }
    return null
  }

  private Bool lineOrNextHasEarlyExit(Str[] lines, Int lineIdx)
  {
    trimmed := lines[lineIdx].trim
    if (trimmed.contains("return") || trimmed.contains("throw") ||
        trimmed.contains("continue") || trimmed.contains("break"))
      return true

    for (j := lineIdx + 1; j < lines.size && j <= lineIdx + 3; j++)
    {
      next := lines[j].trim
      if (next.isEmpty || next.startsWith("//") || next.startsWith("**")) continue
      if (next.startsWith("return") || next.startsWith("throw") ||
          next.startsWith("continue") || next.startsWith("break"))
        return true
      break
    }
    return false
  }

  private Int? findNullableUsage(Str line, Str varName)
  {
    if (line.index("${varName} == null") != null ||
        line.index("${varName} != null") != null ||
        line.index("null == ${varName}") != null ||
        line.index("null != ${varName}") != null ||
        line.index("${varName} ?:") != null)
      return null

    idx := 0
    while (true)
    {
      found := line.index(varName, idx)
      if (found == null) return null

      endPos := found + varName.size
      beforeOk := found == 0 || !LspUtil.isIdentifierChar(line[found - 1])
      if (!beforeOk) { idx = found + 1; continue }

      if (endPos >= line.size) return null

      nextChar := line[endPos]
      if (nextChar == '?') { idx = found + 1; continue }
      if (nextChar != '.') { idx = found + 1; continue }

      return found
    }
    return null
  }
}
