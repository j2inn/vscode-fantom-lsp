
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
      rhsType := inferTypeFromAssignment(line, varName, source, i, index)
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
      // '?' means null-safe access (foo?.bar) or nullable cast — not a declaration
      if (afterCh == '[' || afterCh == '.' || afterCh == '(' || afterCh == '?') return null
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
    // Guard: varName appears as a dict-literal value (KEY : varName) — before ends
    // with ':'; or varName is on the RHS of another assignment (other := ... varName)
    // — before contains ':='.  Neither is a type declaration for varName.
    if (before.endsWith(":") || before.contains(":=")) return null
    // [MapType][] → List of maps (e.g. [Str:Obj?][] → List, not Map)
    if (before.startsWith("[") && before.endsWith("][]")) return "List"
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
  ** source and lineNum are needed for resolving method call return types.
  **
  static Str? inferTypeFromAssignment(Str line, Str varName, Str source, Int lineNum, ProjectIndex index)
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
      // Check for typed list/map literal: [Type][...] pattern
      // e.g. [Str:Obj?][,] is a List (of maps), not a Map
      bracketEnd := rhs.index("]")
      if (bracketEnd != null)
      {
        afterBracket := bracketEnd + 1
        if (afterBracket < rhs.size && rhs[afterBracket] == '[')
        {
          // [Type][:] → typed empty Map; [Type][,] or [Type][...] → typed List
          rest := rhs[afterBracket..-1]
          if (rest.startsWith("[:]")) return "sys::Map"
          return "sys::List"
        }
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
        if (resolved != null) return resolved
        if (index.hasType(castType)) return castType
        // Check using-pod types (e.g. "as Number", "as Ref", "as Dict")
        if (UsingPodIndex.fromSource(source).hasType(castType)) return castType
      }
    }

    // Method call chain: receiver.method(args) or bare method call
    rhsType := inferReturnTypeFromMethodCall(rhs, source, lineNum, index)
    if (rhsType != null) return rhsType

    // Field/property access without parens: receiver.field
    rhsType = inferTypeFromMemberAccess(rhs, source, lineNum, index)
    if (rhsType != null) return rhsType

    return null
  }

  **
  ** Try to infer the return type from a method-call expression on the RHS.
  ** Handles: receiver.method(args), TypeName.method(args), and bare method(args).
  ** First tries to resolve the receiver's type and look up the method slot.
  ** Falls back to searching the method name across all pods from 'using' statements.
  **
  private static Str? inferReturnTypeFromMethodCall(Str rhs, Str source, Int lineNum, ProjectIndex index)
  {
    // Must contain a '(' to be a call
    parenIdx := rhs.index("(")
    if (parenIdx == null || parenIdx == 0) return null

    // Everything before the first '(' is: receiver.methodName (or just methodName)
    beforeParen := rhs[0..<parenIdx].trim
    dotIdx := beforeParen.indexr(".")

    // Bare method call with no receiver (e.g. "methodName(args)")
    if (dotIdx == null)
    {
      methodName := beforeParen
      if (methodName.isEmpty || !methodName[0].isLower) return null
      // Check project index: method declared in the same (or sibling) file
      syms := index.findSymbols(methodName)
      sym := syms.find |s|
      {
        s.kind == SymbolKind.method && s.typeStr != null &&
        s.typeStr != "Void" && s.typeStr != "Obj"
      }
      if (sym != null) return sym.typeStr
      // Fallback: search using-pod types
      return findMethodReturnTypeByName(methodName, source, index)
    }

    methodName := beforeParen[dotIdx + 1..-1].trim
    receiverExpr := beforeParen[0..<dotIdx].trim

    if (methodName.isEmpty || !methodName[0].isLower) return null

    // Try reflected receiver type -> method return type
    receiverReflType := resolveReceiverReflType(receiverExpr, source, lineNum, index)
    if (receiverReflType != null)
    {
      slot := receiverReflType.slot(methodName, false)
      if (slot != null && slot is Method)
      {
        retType := ((Method)slot).returns
        Str? qname := reflTypeToQname(retType)
        if (qname != null) return qname
      }
    }

    // Check project index when reflection couldn't resolve the receiver type.
    // Handles both uppercase receivers (static calls: TypeName.method()) and
    // lowercase receivers whose explicit declared type is a project type
    // (e.g. "Parser p := Parser(); p.parse(s)").
    Str? indexTypeName := null
    if (receiverExpr.size > 0 && receiverExpr[0].isUpper)
      indexTypeName = receiverExpr
    else
      indexTypeName = resolveExplicitDeclaredType(receiverExpr, source)

    if (indexTypeName != null && index.hasType(indexTypeName))
    {
      sym := index.findMemberSymbol(indexTypeName, methodName)
      if (sym != null && sym.typeStr != null &&
          sym.typeStr != "Void" && sym.typeStr != "Obj")
        return sym.typeStr
    }

    // Fallback: search by method name across all pods referenced by 'using' statements
    return findMethodReturnTypeByName(methodName, source, index)
  }

  **
  ** Infer type from a field or zero-arg-method access with no parentheses.
  ** Handles: receiver.field  (no parens on the RHS).
  ** Tries reflection first, then the project index.
  **
  private static Str? inferTypeFromMemberAccess(Str rhs, Str source, Int lineNum, ProjectIndex index)
  {
    // Only handle expressions with no parens (field/property access, not method calls)
    if (rhs.index("(") != null) return null
    dotIdx := rhs.indexr(".")
    if (dotIdx == null) return null

    memberName := rhs[dotIdx + 1..-1].trim
    receiverExpr := rhs[0..<dotIdx].trim
    if (memberName.isEmpty || receiverExpr.isEmpty) return null
    if (!memberName[0].isAlpha) return null

    // Try reflection: resolve receiver type -> look up slot
    receiverReflType := resolveReceiverReflType(receiverExpr, source, lineNum, index)
    if (receiverReflType != null)
    {
      slot := receiverReflType.slot(memberName, false)
      if (slot != null)
      {
        Type? slotType := null
        if (slot is Method) slotType = ((Method)slot).returns
        else if (slot is Field) slotType = ((Field)slot).type
        qname := reflTypeToQname(slotType)
        if (qname != null) return qname
      }
    }

    // Reflection failed — try project index
    // Determine the receiver's type name: uppercase → use directly, lowercase → find explicit decl
    Str? typeName := null
    if (receiverExpr.size > 0 && receiverExpr[0].isUpper)
      typeName = receiverExpr
    else
      typeName = resolveExplicitDeclaredType(receiverExpr, source)

    if (typeName != null && index.hasType(typeName))
    {
      sym := index.findMemberSymbol(typeName, memberName)
      if (sym != null && sym.typeStr != null &&
          sym.typeStr != "Void" && sym.typeStr != "Obj")
        return sym.typeStr
    }

    return null
  }

  **
  ** Resolve the reflected Type corresponding to a receiver expression.
  ** Handles: simple variable name, this.field, TypeName (uppercase).
  ** Avoids recursive type inference to prevent loops.
  **
  private static Type? resolveReceiverReflType(Str expr, Str source, Int lineNum, ProjectIndex index)
  {
    if (expr.isEmpty) return null

    // Strip leading "this." — treat the rest as a field/variable lookup
    workExpr := expr
    if (workExpr.startsWith("this."))
      workExpr = workExpr["this.".size..-1]
    else if (workExpr == "this" || workExpr == "super")
      return null

    // Discard further dots — only resolve the final segment
    lastDot := workExpr.indexr(".")
    varName := lastDot != null ? workExpr[lastDot + 1..-1].trim : workExpr.trim

    if (varName.isEmpty) return null

    // Direct uppercase: treat as a type name
    if (varName[0].isUpper)
    {
      upi := UsingPodIndex.fromSource(source)
      Type? t := upi.getType(varName)
      if (t != null) return t
      if (index.podName != null)
        t = Pod.find(index.podName, false)?.type(varName, false)
      return t
    }

    // Lowercase: find the variable's explicit type declaration only
    // (we deliberately skip inferred assignments to avoid recursion)
    typeName := resolveExplicitDeclaredType(varName, source)
    if (typeName == null) return null

    upi := UsingPodIndex.fromSource(source)
    Type? t := upi.getType(typeName)
    if (t != null) return t
    if (index.podName != null)
      t = Pod.find(index.podName, false)?.type(typeName, false)
    return t
  }

  **
  ** Scan the full source for an explicit type declaration of varName.
  ** Only considers "Type varName" or "Type varName :=" patterns (not inferred).
  ** Safe to call from within type inference — no recursion.
  **
  private static Str? resolveExplicitDeclaredType(Str varName, Str source)
  {
    lines := source.splitLines
    for (i := 0; i < lines.size; i++)
    {
      line := lines[i].trim
      if (line.isEmpty || line.startsWith("//") || line.startsWith("*")) continue
      typeName := extractDeclaredType(line, varName)
      if (typeName != null) return typeName
    }
    return null
  }

  **
  ** Fallback: search all using-pod types (and project pod) for a method with
  ** the given name, and return the first non-trivial return type found.
  **
  private static Str? findMethodReturnTypeByName(Str methodName, Str source, ProjectIndex index)
  {
    upi := UsingPodIndex.fromSource(source)
    allTypes := upi.allTypes()
    for (i := 0; i < allTypes.size; i++)
    {
      slot := allTypes[i].slot(methodName, false)
      if (slot != null && slot is Method)
      {
        qname := reflTypeToQname(((Method)slot).returns)
        if (qname != null) return qname
      }
    }
    // Also check project pod
    if (index.podName != null)
    {
      pod := Pod.find(index.podName, false)
      if (pod != null)
      {
        podTypes := pod.types
        for (i := 0; i < podTypes.size; i++)
        {
          slot := podTypes[i].slot(methodName, false)
          if (slot != null && slot is Method)
          {
            qname := reflTypeToQname(((Method)slot).returns)
            if (qname != null) return qname
          }
        }
      }
    }
    return null
  }

  **
  ** Convert a reflected Type to a qualified type name suitable for display.
  ** Returns null for Void and Obj (too generic to be useful).
  **
  private static Str? reflTypeToQname(Type? t)
  {
    if (t == null) return null
    qname := t.qname
    // Strip trailing nullable marker
    if (qname.endsWith("?")) qname = qname[0..<qname.size - 1]
    // Skip types that are too generic or meaningless for variable type display
    if (qname == "sys::Void" || qname == "sys::Obj") return null
    // Normalize list and map sugar notation
    if (qname == "sys::List" || qname.endsWith("[]")) return "sys::List"
    if (qname == "sys::Map") return "sys::Map"
    return qname.isEmpty ? null : qname
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
