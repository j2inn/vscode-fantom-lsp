**
** DiagnosticMethodParamValidator - Validates method call argument counts.
**
class DiagnosticMethodParamValidator
{
  ** Completion definitions for looking up method signatures
  private const CompletionDefs defs := CompletionDefs.cur

  **
  ** Validate method calls have the correct number of parameters.
  ** Scans for var.method(args) patterns, resolves the variable type,
  ** looks up the method in CompletionDefs, and checks argument count.
  **
  LspDiagnostic[] validateMethodParams(Str source, ProjectIndex index)
  {
    diagnostics := LspDiagnostic[,]
    lines := source.splitLines

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      trimmed := line.trim

      // Skip comments and blank lines
      if (trimmed.isEmpty || trimmed.startsWith("//") || trimmed.startsWith("**")) continue
      if (trimmed.startsWith("using ")) continue

      // Find method call patterns: varName.methodName(...)
      calls := findMethodCalls(line)
      lineIdx := i
      calls.each |call|
      {
        // Skip static type calls (TypeName.method) — these are calls on
        // types, not instances. The method signatures may differ from what
        // YML defines for instances (e.g., NavTree.find vs List.find).
        if (call.varName.size > 0 && call.varName[0].isUpper) return

        // Resolve the variable's type
        typeName := resolveVarType(call.varName, source, lineIdx, index)
        if (typeName == null) return

        // Look up the type's completions in YML
        items := defs.itemsFor(typeName)
        if (items == null) return

        // Find the method definition
        methodItem := items.find |item| { item.label == call.methodName }
        if (methodItem == null) return
        if (methodItem.detail == null) return

        // Parse expected parameter count from the detail string
        paramInfo := parseMethodParams(methodItem.detail)
        if (paramInfo == null) return

        // Count actual arguments
        actualCount := call.argCount
        if (call.hasTrailingClosure) actualCount++

        if (actualCount < paramInfo.minArgs)
        {
          col := call.callStart
          endCol := call.callEnd.min(line.size)
          range := LspRange(LspPosition(lineIdx, col), LspPosition(lineIdx, endCol))
          expected := paramInfo.minArgs == paramInfo.maxArgs
            ? "${paramInfo.minArgs}" : "${paramInfo.minArgs}-${paramInfo.maxArgs}"
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.error,
            "'${call.methodName}' expects ${expected} argument(s), but got ${actualCount}", "fantom"))
        }
        else if (actualCount > paramInfo.maxArgs)
        {
          col := call.callStart
          endCol := call.callEnd.min(line.size)
          range := LspRange(LspPosition(lineIdx, col), LspPosition(lineIdx, endCol))
          expected := paramInfo.minArgs == paramInfo.maxArgs
            ? "${paramInfo.minArgs}" : "${paramInfo.minArgs}-${paramInfo.maxArgs}"
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.error,
            "'${call.methodName}' expects ${expected} argument(s), but got ${actualCount}", "fantom"))
        }
      }
    }

    return diagnostics
  }

  **
  ** Find all var.method(args) call patterns in a line.
  ** Returns a list of MethodCall descriptors.
  **
  private MethodCall[] findMethodCalls(Str line)
  {
    calls := MethodCall[,]
    pos := 0

    while (pos < line.size)
    {
      if (line[pos] == '"')
      {
        pos++
        while (pos < line.size && line[pos] != '"')
        {
          if (line[pos] == '\\') pos++
          pos++
        }
        pos++
        continue
      }

      if (line[pos] == '`')
      {
        pos++
        while (pos < line.size && line[pos] != '`')
        {
          if (line[pos] == '\\') pos++
          pos++
        }
        pos++
        continue
      }

      if (pos + 1 < line.size && line[pos] == '/' && line[pos + 1] == '/')
        break

      if (line[pos].isAlpha || line[pos] == '_')
      {
        varStart := pos
        while (pos < line.size && (line[pos].isAlphaNum || line[pos] == '_'))
          pos++
        varName := line[varStart ..< pos]

        if (pos < line.size && line[pos] == '.')
        {
          pos++

          if (pos < line.size && (line[pos].isAlpha || line[pos] == '_'))
          {
            methodStart := pos
            while (pos < line.size && (line[pos].isAlphaNum || line[pos] == '_'))
              pos++
            methodName := line[methodStart ..< pos]

            if (methodName.size > 0 && methodName[0].isLower)
            {
              restPos := pos
              while (restPos < line.size && line[restPos].isSpace) restPos++

              if (restPos < line.size && line[restPos] == '(')
              {
                parenStart := restPos
                parenEnd := findMatchingParen(line, parenStart)
                if (parenEnd != null)
                {
                  argStr := line[parenStart + 1 ..< parenEnd].trim
                  argCount := argStr.isEmpty ? 0 : countArgs(argStr)
                  callEnd := parenEnd + 1

                  afterParen := callEnd
                  while (afterParen < line.size && line[afterParen].isSpace) afterParen++
                  hasClosure := afterParen < line.size &&
                                ((line[afterParen] == '|' && (afterParen + 1 >= line.size || line[afterParen + 1] != '|')) ||
                                 line[afterParen] == '{')

                  calls.add(MethodCall {
                    it.varName = varName
                    it.methodName = methodName
                    it.argCount = argCount
                    it.hasTrailingClosure = hasClosure
                    it.callStart = varStart
                    it.callEnd = callEnd
                  })
                  pos = callEnd
                }
              }
              else if (restPos < line.size && line[restPos] == '|' &&
                       (restPos + 1 >= line.size || line[restPos + 1] != '|'))
              {
                calls.add(MethodCall {
                  it.varName = varName
                  it.methodName = methodName
                  it.argCount = 0
                  it.hasTrailingClosure = true
                  it.callStart = varStart
                  it.callEnd = pos
                })
              }
            }
          }
        }
        continue
      }
      pos++
    }

    return calls
  }

  **
  ** Find the matching closing parenthesis, handling nesting.
  **
  private Int? findMatchingParen(Str line, Int openPos)
  {
    depth := 0
    inStr := false
    i := openPos
    while (i < line.size)
    {
      ch := line[i]
      // Block comment: /* ... */
      if (!inStr && ch == '/' && i + 1 < line.size && line[i + 1] == '*')
      {
        i += 2
        while (i + 1 < line.size && !(line[i] == '*' && line[i + 1] == '/')) i++
        i++
        continue
      }
      // Double-quoted string literal
      if (ch == '"') { inStr = !inStr; i++; continue }
      if (ch == '\\' && inStr) { i += 2; continue }
      // Single-quoted character literal: 'x' or '\n' etc.
      if (ch == '\'' && !inStr)
      {
        i++
        if (i < line.size && line[i] == '\\') i++
        while (i < line.size && line[i] != '\'') i++
        i++
        continue
      }
      if (inStr) { i++; continue }
      if (ch == '(' || ch == '[') depth++
      else if (ch == ')' || ch == ']') { depth--; if (depth == 0) return i }
      i++
    }
    return null
  }

  **
  ** Count the number of arguments in an argument string.
  ** Handles nested parens, brackets, closures, string literals,
  ** single-quoted character literals, and block comments.
  **
  private Int countArgs(Str argStr)
  {
    if (argStr.trim.isEmpty) return 0
    depth := 0
    pipeDepth := 0
    inStr := false
    count := 1
    i := 0

    while (i < argStr.size)
    {
      ch := argStr[i]
      // Block comment: /* ... */
      if (!inStr && ch == '/' && i + 1 < argStr.size && argStr[i + 1] == '*')
      {
        i += 2
        while (i + 1 < argStr.size && !(argStr[i] == '*' && argStr[i + 1] == '/')) i++
        i++
        continue
      }
      // Double-quoted string literal
      if (ch == '"') { inStr = !inStr; i++; continue }
      if (ch == '\\' && inStr) { i += 2; continue }
      if (inStr) { i++; continue }
      // Single-quoted character literal: 'x' or '\n' etc.
      if (ch == '\'')
      {
        i++
        if (i < argStr.size && argStr[i] == '\\') i++
        while (i < argStr.size && argStr[i] != '\'') i++
        i++
        continue
      }
      if (ch == '(' || ch == '[' || ch == '{') depth++
      else if (ch == ')' || ch == ']' || ch == '}') depth--
      else if (ch == '|') pipeDepth = pipeDepth == 0 ? 1 : 0
      else if (ch == ',' && depth == 0 && pipeDepth == 0) count++
      i++
    }
    return count
  }

  **
  ** Resolve a variable's type by scanning source for declarations.
  ** Delegate to shared TypeResolver utility.
  **
  private Str? resolveVarType(Str varName, Str source, Int currentLine, ProjectIndex index)
  {
    return TypeResolver.resolveVarType(varName, source, currentLine, index)
  }

  **
  ** Parse method signature from the detail string to get parameter info.
  **
  private MethodParamInfo? parseMethodParams(Str detail)
  {
    parenOpen := detail.index("(")
    if (parenOpen == null) return null

    parenClose := detail.indexr(")")
    if (parenClose == null) return null

    paramStr := detail[parenOpen + 1 ..< parenClose].trim
    if (paramStr.isEmpty) return MethodParamInfo { it.minArgs = 0; it.maxArgs = 0 }

    params := splitParams(paramStr)
    minArgs := 0
    maxArgs := params.size

    params.each |p|
    {
      trimP := p.trim
      if (!trimP.contains(":=")) minArgs++
    }

    return MethodParamInfo { it.minArgs = minArgs; it.maxArgs = maxArgs }
  }

  **
  ** Split a parameter string by commas, respecting nested | and < > structures.
  **
  private Str[] splitParams(Str paramStr)
  {
    params := Str[,]
    depth := 0
    pipeDepth := 0
    current := StrBuf()

    for (i := 0; i < paramStr.size; i++)
    {
      ch := paramStr[i]
      if (ch == '|') pipeDepth = pipeDepth == 0 ? 1 : 0
      else if (ch == '(' || ch == '[' || ch == '<') depth++
      else if (ch == ')' || ch == ']' || ch == '>') depth--
      else if (ch == ',' && depth == 0 && pipeDepth == 0)
      {
        params.add(current.toStr)
        current.clear
        continue
      }
      current.addChar(ch)
    }
    if (current.size > 0) params.add(current.toStr)
    return params
  }
}

internal class MethodCall
{
  Str varName := ""
  Str methodName := ""
  Int argCount := 0
  Bool hasTrailingClosure := false
  Int callStart := 0
  Int callEnd := 0
}

internal class MethodParamInfo
{
  Int minArgs := 0
  Int maxArgs := 0
}
