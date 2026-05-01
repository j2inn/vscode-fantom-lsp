
**
** DiagnosticStaticContextValidator - Detects 'this' and bare instance field
** access inside static methods.
**
** Uses the AST when available; falls back to brace-counting text scan when the
** source cannot be parsed (e.g., the class extends an unresolvable project type).
** This ensures diagnostics are reported even when the Fantom compiler aborts
** early and its own errors are lost.
**
** Bare instance field detection works by cross-referencing identifiers inside
** a static method body against the instance fields of the class's project base
** types (supplied via baseTypes + index). Local variables and parameters that
** shadow a field name are excluded to avoid false positives.
**
class DiagnosticStaticContextValidator
{
  LspDiagnostic[] checkStaticContext(Str source, Str[] baseTypes, ProjectIndex index)
  {
    lines := source.splitLines

    ast := AstIndex.parse("file:///static-check.fan", source)
    if (ast != null)
      return checkViaAst(ast, lines, baseTypes, index)

    return checkViaText(lines, baseTypes, index)
  }

  // ---------------------------------------------------------------------------
  // AST-based path
  // ---------------------------------------------------------------------------

  private LspDiagnostic[] checkViaAst(AstIndex ast, Str[] lines, Str[] baseTypes, ProjectIndex index)
  {
    diagnostics := LspDiagnostic[,]

    ast.types.each |astType|
    {
      methods := astType.methods
      for (mi := 0; mi < methods.size; mi++)
      {
        m := methods[mi]
        if (!m.isStatic) continue

        startLine := m.line
        endLine   := lines.size - 1
        if (mi + 1 < methods.size)
          endLine = methods[mi + 1].line - 1

        astType.fields.each |f|
        {
          if (f.line > startLine && f.line <= endLine)
            endLine = f.line - 1
        }

        // Names that are local to this method (params + locals) — not bare-field accesses
        localNames := Str:Bool[:]
        m.params.each   |p| { localNames[p.name] = true }
        m.localVars.each |v| { localNames[v.name] = true }

        // Instance fields of this type itself that are accessible as bare names
        ownInstanceFields := Str:Bool[:]
        astType.fields.each |f| { if (!f.isStatic) ownInstanceFields[f.name] = true }

        scanLinesForStaticViolations(lines, startLine, endLine,
          localNames, ownInstanceFields, baseTypes, index, diagnostics)
      }
    }

    return diagnostics
  }

  // ---------------------------------------------------------------------------
  // Text-based fallback path
  // ---------------------------------------------------------------------------

  private LspDiagnostic[] checkViaText(Str[] lines, Str[] baseTypes, ProjectIndex index)
  {
    diagnostics := LspDiagnostic[,]
    inStaticMethod := false
    depth := 0
    methodEntryDepth := 0
    // Local names collected while scanning the current static method body
    localNames := Str:Bool[:]

    for (li := 0; li < lines.size; li++)
    {
      line := lines[li]
      trimmed := line.trim

      if (!inStaticMethod &&
          (trimmed.isEmpty || trimmed.startsWith("//") ||
           trimmed.startsWith("**") || trimmed.startsWith("*")))
      {
        depth += countBraces(line)
        continue
      }

      if (!inStaticMethod && isStaticMethodLine(trimmed))
      {
        inStaticMethod = true
        methodEntryDepth = depth
        localNames = Str:Bool[:]
        collectParamsFromDecl(trimmed, localNames)
        depth += countBraces(line)
        continue
      }

      depth += countBraces(line)

      if (inStaticMethod)
      {
        // Track local variable declarations to avoid false positives
        collectLocalVarDecl(trimmed, localNames)

        scanLinesForStaticViolations(lines, li, li,
          localNames, Str:Bool[:], baseTypes, index, diagnostics)

        if (depth <= methodEntryDepth)
        {
          inStaticMethod = false
          localNames = Str:Bool[:]
        }
      }
    }

    return diagnostics
  }

  // ---------------------------------------------------------------------------
  // Core scanner
  // ---------------------------------------------------------------------------

  **
  ** Scan lines[startLine..endLine] for:
  **   1. Standalone 'this' tokens
  **   2. Bare identifiers that are instance fields of the current class (ownInstanceFields)
  **      or of a project base type (via baseTypes + index), and are not shadowed by a local.
  **
  private Void scanLinesForStaticViolations(
    Str[] lines, Int startLine, Int endLine,
    Str:Bool localNames, Str:Bool ownInstanceFields,
    Str[] baseTypes, ProjectIndex index,
    LspDiagnostic[] out)
  {
    for (li := startLine; li <= endLine && li < lines.size; li++)
    {
      line := lines[li]

      // --- 'this' tokens ---
      findThisColumnsInLine(line).each |col|
      {
        out.add(LspDiagnostic(
          LspRange(LspPosition(li, col), LspPosition(li, col + 4)),
          DiagnosticSeverity.error,
          "Cannot access 'this' in static context",
          "fantom"
        ))
      }

      // --- bare instance field accesses ---
      fieldCols  := Int[,]
      fieldNames := Str[,]
      findBareInstanceFieldAccesses(line, localNames, ownInstanceFields, baseTypes, index,
        fieldCols, fieldNames)
      for (fi := 0; fi < fieldCols.size; fi++)
      {
        col  := fieldCols[fi]
        name := fieldNames[fi]
        out.add(LspDiagnostic(
          LspRange(LspPosition(li, col), LspPosition(li, col + name.size)),
          DiagnosticSeverity.error,
          "Cannot access instance field '${name}' in static context",
          "fantom"
        ))
      }
    }
  }

  **
  ** Appends to cols/names the bare identifiers on the line that are
  ** instance fields of the class or a base type, not shadowed by a local,
  ** and not preceded by a dot (i.e., not already a qualified access).
  **
  private Void findBareInstanceFieldAccesses(
    Str line,
    Str:Bool localNames,
    Str:Bool ownInstanceFields,
    Str[] baseTypes,
    ProjectIndex index,
    Int[] cols,
    Str[] names)
  {
    if (baseTypes.isEmpty && ownInstanceFields.isEmpty) return

    tokenCols  := Int[,]
    tokenNames := Str[,]
    extractIdentifierTokens(line, tokenCols, tokenNames)

    for (ti := 0; ti < tokenCols.size; ti++)
    {
      col  := tokenCols[ti]
      name := tokenNames[ti]

      if (localNames.containsKey(name)) continue

      isOwnField  := ownInstanceFields.containsKey(name)
      isBaseField := baseTypes.any |bt| { index.hasMember(bt, name) }
      if (!isOwnField && !isBaseField) continue

      // Skip if preceded by a dot (already qualified: obj.field)
      if (col > 0 && line[col - 1] == '.') continue

      // Skip if followed by '(' — it's a method call, not a field
      endCol := col + name.size
      if (endCol < line.size && line[endCol] == '(') continue

      cols.add(col)
      names.add(name)
    }
  }

  **
  ** Extract all standalone lowercase-starting identifier tokens from a line,
  ** skipping string literals and // comments. Appends to cols/names.
  **
  private Void extractIdentifierTokens(Str line, Int[] cols, Str[] names)
  {
    i := 0
    size := line.size
    inStr := false

    while (i < size)
    {
      ch := line[i]
      if (!inStr && ch == '"') { inStr = true; i++; continue }
      if (inStr)
      {
        if (ch == '\\') { i += 2; continue }
        if (ch == '"') inStr = false
        i++; continue
      }
      if (ch == '/' && i + 1 < size && line[i + 1] == '/') break
      if (ch == '*' && i + 1 < size && line[i + 1] == '*') break

      // Start of an identifier: must begin with a lowercase letter or underscore
      // (uppercase = type name, not a field access)
      if ((ch.isAlpha && ch.isLower) || ch == '_')
      {
        start := i
        while (i < size && LspUtil.isIdentifierChar(line[i])) i++
        name := line[start..<i]
        if (!isKeyword(name))
        {
          cols.add(start)
          names.add(name)
        }
        continue
      }
      i++
    }
  }

  // ---------------------------------------------------------------------------
  // Text-fallback helpers
  // ---------------------------------------------------------------------------

  private Bool isStaticMethodLine(Str trimmed)
  {
    if (trimmed.contains(":=")) return false
    if (!containsIdentifier(trimmed, "static")) return false
    return trimmed.contains("(")
  }

  **
  ** Collect parameter names from a method declaration line into localNames.
  ** E.g.: "static Void bar(Str x, Int y)" → adds "x", "y"
  **
  private Void collectParamsFromDecl(Str line, Str:Bool localNames)
  {
    open := line.index("(")
    close := line.index(")")
    if (open == null || close == null || close <= open) return
    inside := line[open+1..<close]
    inside.split(',').each |part|
    {
      tokens := part.trim.split(' ')
      if (tokens.size >= 2)
      {
        name := tokens.last.trim
        if (name.size > 0 && !name[0].isUpper)
          localNames[name] = true
      }
    }
  }

  **
  ** If the trimmed line is a local variable declaration (contains ":="),
  ** extract the LHS name and add it to localNames.
  **
  private Void collectLocalVarDecl(Str trimmed, Str:Bool localNames)
  {
    walrus := trimmed.index(":=")
    if (walrus == null) return
    lhs := trimmed[0..<walrus].trim
    // Strip type annotation: "Str x" → "x", bare "x" → "x"
    parts := lhs.split(' ')
    name := parts.last.trim
    if (name.size > 0 && !name[0].isUpper && !name.isEmpty)
      localNames[name] = true
  }

  private Int countBraces(Str line)
  {
    delta := 0
    i := 0
    size := line.size
    inStr := false
    while (i < size)
    {
      ch := line[i]
      if (!inStr && ch == '"') { inStr = true; i++; continue }
      if (inStr)
      {
        if (ch == '\\') { i += 2; continue }
        if (ch == '"') inStr = false
        i++; continue
      }
      if (ch == '/' && i + 1 < size && line[i + 1] == '/') break
      if (ch == '{') delta++
      else if (ch == '}') delta--
      i++
    }
    return delta
  }

  // ---------------------------------------------------------------------------
  // Shared helpers
  // ---------------------------------------------------------------------------

  private Int[] findThisColumnsInLine(Str line)
  {
    cols := Int[,]
    i := 0
    inString := false
    size := line.size
    while (i < size)
    {
      ch := line[i]
      if (!inString && ch == '"') { inString = true; i++; continue }
      if (inString)
      {
        if (ch == '\\') { i += 2; continue }
        if (ch == '"') inString = false
        i++; continue
      }
      if (ch == '/' && i + 1 < size && line[i + 1] == '/') break
      if (ch == '*' && i + 1 < size && line[i + 1] == '*') break
      if (ch == 't' && i + 3 < size &&
          line[i + 1] == 'h' && line[i + 2] == 'i' && line[i + 3] == 's')
      {
        beforeOk := i == 0 || !LspUtil.isIdentifierChar(line[i - 1])
        afterOk  := (i + 4 >= size) || !LspUtil.isIdentifierChar(line[i + 4])
        if (beforeOk && afterOk) cols.add(i)
        i += 4; continue
      }
      i++
    }
    return cols
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

  private Bool isKeyword(Str name)
  {
    switch (name)
    {
      case "if": case "else": case "return": case "for": case "while":
      case "true": case "false": case "null": case "this": case "super":
      case "new": case "try": case "catch": case "throw": case "finally":
      case "break": case "continue": case "switch": case "case": case "default":
      case "is": case "isnot": case "as": case "it": case "using": case "static":
      case "override": case "virtual": case "abstract": case "native":
      case "const": case "readonly": case "once":
        return true
      default:
        return false
    }
  }
}
