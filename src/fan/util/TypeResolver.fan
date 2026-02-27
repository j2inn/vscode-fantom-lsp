
**
** TypeResolver - Resolves variable types from source code context.
** Used by DiagnosticService (param validation) and HoverService (type display).
**
class TypeResolver
{
  ** Completion definitions for resolving type aliases
  private static const CompletionDefs defs := CompletionDefs.cur

  **
  ** Resolve a variable's type by scanning source for declarations.
  ** Returns a qualified type name (e.g. "sys::Str") or simple name, or null.
  **
  static Str? resolveVarType(Str varName, Str source, Int currentLine, ProjectIndex index)
  {
    lines := source.splitLines

    // Scan backwards for variable declarations
    for (i := currentLine; i >= 0 && i >= currentLine - 100; i--)
    {
      if (i >= lines.size) continue
      line := lines[i].trim
      if (line.isEmpty || line.startsWith("//") || line.startsWith("**")) continue

      // Check for explicit type declaration: Type varName :=
      typeName := extractDeclaredType(line, varName)
      if (typeName != null)
      {
        resolved := defs.resolveAlias(typeName)
        return resolved ?: (index.hasType(typeName) ? typeName : null)
      }

      // Check for := assignment and infer type from RHS
      rhsType := inferTypeFromAssignment(line, varName, index)
      if (rhsType != null) return rhsType
    }

    // Check method parameters
    for (i := currentLine; i >= 0 && i >= currentLine - 50; i--)
    {
      if (i >= lines.size) continue
      line := lines[i].trim

      parenOpen := line.index("(")
      if (parenOpen == null) continue
      parenClose := line.index(")", parenOpen)
      if (parenClose == null) continue
      beforeParen := line[0..<parenOpen].trim
      if (!beforeParen.contains(" ")) continue

      paramStr := line[parenOpen + 1 ..< parenClose]
      params := paramStr.split(',')
      param := params.find |p|
      {
        p.trim.endsWith(varName) || p.trim.endsWith("${varName})")
      }
      if (param != null)
      {
        words := param.trim.split(' ').findAll |w| { !w.isEmpty }
        if (words.size >= 2)
        {
          typePart := words[0]
          if (typePart.endsWith("?")) typePart = typePart[0..<typePart.size - 1]
          if (typePart.size > 0 && typePart[0].isUpper)
          {
            resolved := defs.resolveAlias(typePart)
            return resolved ?: (index.hasType(typePart) ? typePart : null)
          }
        }
      }
    }

    return null
  }

  **
  ** Extract the explicit type from "Type varName" or "Type varName :=" declarations.
  **
  static Str? extractDeclaredType(Str line, Str varName)
  {
    idx := findWordInLine(line, varName)
    if (idx == null) return null

    // Verify varName is in a declaration context, not just used in an
    // expression (e.g. dbUnits[2] inside a method call).  After the
    // variable name, we expect := , whitespace, end-of-line, ), or comma.
    endIdx := idx + varName.size
    if (endIdx < line.size)
    {
      afterCh := line[endIdx]
      if (afterCh == '[' || afterCh == '.' || afterCh == '(') return null
    }

    before := line[0..<idx].trim

    // Strip modifiers
    modifiers := ["public", "private", "protected", "internal",
                  "static", "const", "final", "abstract",
                  "virtual", "override", "native", "once", "readonly"]
    modifiers.each |mod|
    {
      while (before.startsWith(mod + " ") || before.startsWith(mod + "\t"))
        before = before[mod.size + 1 ..-1].trim
    }

    if (before.isEmpty) return null
    // Map type: Str:Dict[] or [Str:Dict] — must check for ':' before '[]' check
    if (before.contains(":") &&
        (before.startsWith("[") || before.index(":") < (before.index("[]") ?: before.size)))
      return "Map"
    if (before.endsWith("[]")) return "List"
    if (before.startsWith("[") && before.endsWith("]")) return "List"

    typeName := before.endsWith("?") ? before[0..<before.size - 1] : before
    if (typeName.isEmpty || !typeName[0].isUpper) return null

    // Must be a simple identifier (no spaces, parens, etc.)
    if (typeName.contains(" ") || typeName.contains("(") || typeName.contains(")")) return null

    angleIdx := typeName.index("<")
    if (angleIdx != null) typeName = typeName[0..<angleIdx]

    return typeName
  }

  **
  ** Infer type from RHS of an assignment: varName := expr
  **
  static Str? inferTypeFromAssignment(Str line, Str varName, ProjectIndex index)
  {
    idx := findWordInLine(line, varName)
    if (idx == null) return null

    afterVar := idx + varName.size
    assignIdx := line.index(":=", afterVar)
    if (assignIdx == null) return null

    rhs := line[assignIdx + 2 ..-1].trim

    if (rhs.startsWith("\"")) return "sys::Str"
    if (rhs.startsWith("["))
    {
      if (rhs.startsWith("[:]")) return "sys::Map"
      // Check for map literal
      bracketEnd := rhs.index("]")
      if (bracketEnd != null)
      {
        inner := rhs[1..<bracketEnd]
        if (inner.contains(":")) return "sys::Map"
      }
      return "sys::List"
    }
    // Typed list/map literals: Type[,] or Type[:] or Type[expr, ...]
    bracketIdx := rhs.index("[")
    if (bracketIdx != null && bracketIdx > 0)
    {
      beforeBracket := rhs[0..<bracketIdx]
      if (beforeBracket.size > 0 && beforeBracket[0].isUpper &&
          beforeBracket.all |ch| { ch.isAlphaNum || ch == '_' || ch == '?' })
      {
        afterBracket := rhs[bracketIdx..-1]
        if (afterBracket.startsWith("[:]")) return "sys::Map"
        return "sys::List"
      }
    }
    if (rhs == "true" || rhs == "false" ||
        rhs.startsWith("true ") || rhs.startsWith("false "))
      return "sys::Bool"

    // Numeric
    if (rhs.size > 0 && (rhs[0].isDigit || (rhs[0] == '-' && rhs.size > 1 && rhs[1].isDigit)))
    {
      if (rhs.contains(".") || rhs.endsWith("f") || rhs.endsWith("F"))
        return "sys::Float"
      return "sys::Int"
    }

    // Constructor: TypeName(...)
    parenIdx := rhs.index("(")
    if (parenIdx != null && parenIdx > 0)
    {
      ctorName := rhs[0..<parenIdx].trim
      if (ctorName.size > 0 && ctorName[0].isUpper &&
          ctorName.all |ch| { ch.isAlphaNum || ch == '_' })
      {
        resolved := defs.resolveAlias(ctorName)
        if (resolved != null) return resolved
        if (index.hasType(ctorName)) return ctorName
      }
    }

    // Check for "as" cast: expr as TypeName or expr as TypeName[]
    asIdx := rhs.index(" as ")
    if (asIdx != null)
    {
      castType := rhs[asIdx + 4 ..-1].trim
      if (castType.endsWith("[]")) return "sys::List"
      if (castType.endsWith("?")) castType = castType[0..<castType.size - 1]
      if (castType.size > 0 && castType[0].isUpper)
      {
        resolved := defs.resolveAlias(castType)
        return resolved ?: (index.hasType(castType) ? castType : null)
      }
    }

    return null
  }

  **
  ** Find exact word position in a line (word boundary match).
  **
  static Int? findWordInLine(Str line, Str word)
  {
    idx := 0
    while (true)
    {
      found := line.index(word, idx)
      if (found == null) return null
      endPos := found + word.size
      beforeOk := found == 0 || !line[found - 1].isAlphaNum
      afterOk := endPos >= line.size || !line[endPos].isAlphaNum
      if (beforeOk && afterOk) return found
      idx = found + 1
    }
    return null
  }
}
