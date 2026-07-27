
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
    // Option B: query the AST-indexed symbols first — authoritative, no heuristics.
    // Locals and params carry typeStr set by the compiler; prefer this over text scanning.
    idxType := resolveVarTypeFromIndex(varName, source, currentLine, index)
    if (idxType != null) return idxType

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
  ** Option B: resolve a variable's type directly from the project index.
  ** Looks up localVar/param symbols whose name matches varName and whose
  ** declaration line is at or before currentLine.  The typeStr stored on
  ** each symbol comes from the compiler AST — it is authoritative for all
  ** types the compiler could resolve, including inferred locals whose RHS
  ** is a method call (e.g. x := someList.groupBy(...) → typeStr = "Map").
  ** Returns null when the symbol is not in the index or has no useful type.
  **
  static Str? resolveVarTypeFromIndex(Str varName, Str source, Int currentLine, ProjectIndex index)
  {
    // Find the file URI that owns this source by matching indexed source text.
    // We scan all file indexes rather than requiring the caller to pass a URI,
    // keeping the public API of resolveVarType unchanged.
    fileUri := index.findFileUriForSource(source)
    if (fileUri == null) return null

    syms := index.findSymbols(varName)
    best := null as IndexedSymbol
    syms.each |sym|
    {
      if (sym.fileUri != fileUri) return
      if (sym.kind != SymbolKind.localVar && sym.kind != SymbolKind.param) return
      if (sym.typeStr == null) return
      // Skip compiler placeholder types that convey no real information
      t := sym.typeStr
      if (t == "Obj" || t == "Obj?" || t == "Error" || t == "Void") return
      // Symbol must be declared at or before the use site
      if (sym.line > currentLine) return
      // Prefer the declaration closest to (but not past) currentLine
      if (best == null || sym.line > best.line) best = sym
    }
    if (best == null || best.typeStr == null) return null

    // Normalise the type name through the alias table so callers always
    // receive a qualified name (e.g. "Map" → "sys::Map", "List" → "sys::List")
    raw := best.typeStr
    resolved := defs.resolveAlias(raw)
    if (resolved != null) return resolved
    if (index.hasType(raw)) return raw
    // Also accept fully-qualified names (contain "::")
    if (raw.contains("::")) return raw
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
  ** Extract a method's declared return type from its own declaration line,
  ** e.g. "protected EntityReferenceable? entityReferenceable() {" -> "EntityReferenceable".
  ** Used when a symbol's typeStr wasn't captured by the indexer (AST parse
  ** failed for the file, so the text-scan fallback only recorded the name).
  ** Returns null for Void/lowercase/generic-placeholder return types.
  **
  static Str? extractMethodReturnType(Str line, Str methodName)
  {
    idx := findWordInLine(line, methodName)
    if (idx == null) return null

    endIdx := idx + methodName.size
    if (endIdx >= line.size || line[endIdx] != '(') return null

    before := line[0..<idx].trim
    modifiers := ["public", "private", "protected", "internal",
                  "static", "const", "final", "abstract",
                  "virtual", "override", "native", "once", "readonly", "new"]
    modifiers.each |mod|
    {
      while (before.startsWith(mod + " ") || before.startsWith(mod + "\t"))
        before = before[mod.size + 1 ..-1].trim
    }

    if (before.isEmpty) return null

    typeName := before.endsWith("?") ? before[0..<before.size - 1] : before
    if (typeName.isEmpty || !typeName[0].isUpper) return null
    if (typeName == "Void" || typeName == "Obj") return null
    if (typeName.contains(" ") || typeName.contains("(") || typeName.contains(")")) return null

    angleIdx := typeName.index("<")
    if (angleIdx != null) typeName = typeName[0..<angleIdx]
    if (typeName.endsWith("[]")) return null // List-returning; not a simple type jump target

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

    // Trailing-closure call with no parens: receiver.method |params| { ... }
    // Extract the method name before the first '|' and delegate to YML lookup.
    pipeIdx := rhs.index("|")
    if (pipeIdx != null && pipeIdx > 0)
    {
      beforePipe := rhs[0..<pipeIdx].trim
      dotIdx := beforePipe.indexr(".")
      if (dotIdx != null)
      {
        tcMethod := beforePipe[dotIdx + 1..-1].trim
        tcReceiver := beforePipe[0..<dotIdx].trim
        if (tcMethod.size > 0 && tcMethod[0].isLower)
        {
          tcType := findMethodReturnTypeFromYml(tcMethod, tcReceiver, source, index)
          if (tcType != null) return tcType
        }
      }
    }

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

    // For chained calls like a().b(c) or a().b |closure|, use the LAST
    // .method( segment so we resolve b's return type, not a's.
    // Scan for the rightmost '(' that is preceded by '.identifier'.
    // Stop before any trailing '|' (closure) to avoid overrunning into closure params.
    pipeIdx := rhs.index("|")
    scanEnd := pipeIdx != null ? pipeIdx : rhs.size
    lastDotParen := null as Int
    i := scanEnd - 1
    while (i >= 1)
    {
      if (rhs[i] == '(')
      {
        j := i - 1
        while (j >= 0 && rhs[j].isSpace) j--
        if (j >= 0 && (rhs[j].isAlphaNum || rhs[j] == '_'))
        {
          // Walk back over the identifier
          while (j >= 0 && (rhs[j].isAlphaNum || rhs[j] == '_')) j--
          if (j >= 0 && rhs[j] == '.') { lastDotParen = i; break }
          // Bare method call at start (no dot)
          if (j < 0 && i == parenIdx) { lastDotParen = i; break }
        }
      }
      i--
    }
    if (lastDotParen != null) parenIdx = lastDotParen

    // Everything before the chosen '(' is: receiver.methodName (or just methodName)
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

    // Walk back from the dot over identifier/'.' characters only, so the
    // receiver expression doesn't swallow preceding operators (e.g. a ternary
    // condition like "cond ? a : Type.method()" must yield receiver "Type",
    // not "cond ? a : Type").
    receiverStart := dotIdx
    while (receiverStart > 0 &&
           (beforeParen[receiverStart - 1].isAlphaNum ||
            beforeParen[receiverStart - 1] == '_' ||
            beforeParen[receiverStart - 1] == '.'))
      receiverStart--
    receiverExpr := beforeParen[receiverStart ..< dotIdx].trim

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
    else if (isSimpleIdentifier(receiverExpr))
      indexTypeName = resolveExplicitDeclaredType(receiverExpr, source)

    if (indexTypeName != null && index.hasType(indexTypeName))
    {
      // Compiler-synthesized enum methods (fromStr, vals) are never indexed as
      // members since they don't appear in source. Handle them explicitly so
      // resolution doesn't fall through to a global cross-pod method-name search,
      // which can match an unrelated type's fromStr/vals in another pod.
      if (index.isEnumType(indexTypeName))
      {
        if (methodName == "fromStr") return indexTypeName
        if (methodName == "vals") return "sys::List"
      }

      sym := index.findMemberSymbol(indexTypeName, methodName)
      if (sym != null && sym.typeStr != null &&
          sym.typeStr != "Void" && sym.typeStr != "Obj")
        return sym.typeStr
    }

    // Option A: look up the method in YML completion defs and parse return type
    // from the detail string.  Covers framework/pod types (e.g. List.groupBy → Map)
    // that reflection can't reach because no explicit receiver type was declared.
    ymlReturnType := findMethodReturnTypeFromYml(methodName, receiverExpr, source, index)
    if (ymlReturnType != null) return ymlReturnType

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
    else if (isSimpleIdentifier(receiverExpr))
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
    if (!isSimpleIdentifier(varName)) return null
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
  ** Option A: look up methodName in the YML completion definitions.
  ** When the receiver's type can be resolved (explicit decl or index), search
  ** only that type's items.  Otherwise search all defined types for the first
  ** match.  Parses the return type from the detail string via
  ** CompletionDefs.returnTypeFrom().
  **
  private static Str? findMethodReturnTypeFromYml(Str methodName, Str receiverExpr,
                                                   Str source, ProjectIndex index)
  {
    // Try to narrow to a specific receiver type first
    Str? receiverType := null
    if (receiverExpr.size > 0 && receiverExpr[0].isUpper)
      receiverType = defs.resolveAlias(receiverExpr) ?: receiverExpr
    else if (isSimpleIdentifier(receiverExpr))
    {
      explicit := resolveExplicitDeclaredType(receiverExpr, source)
      if (explicit != null)
        receiverType = defs.resolveAlias(explicit) ?: explicit
    }

    if (receiverType != null)
    {
      items := defs.itemsFor(receiverType)
      if (items != null)
      {
        item := items.find |ci| { ci.label == methodName }
        if (item != null)
        {
          ret := CompletionDefs.returnTypeFrom(item.detail)
          if (ret != null) return ret
        }
      }
    }

    // No specific receiver type — scan all YML types for the method name.
    // Return the first unambiguous result; skip if multiple types define it
    // with conflicting return types (too ambiguous to be useful).
    found := Str[,]
    defs.allQualifiedTypeNames.each |typeName|
    {
      items := defs.itemsFor(typeName)
      if (items == null) return
      item := items.find |ci| { ci.label == methodName }
      if (item == null) return
      ret := CompletionDefs.returnTypeFrom(item.detail)
      if (ret != null && !found.contains(ret)) found.add(ret)
    }
    return found.size == 1 ? found[0] : null
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
  ** True if expr is a bare identifier (letters/digits/underscore only, not
  ** starting with a digit). Guards resolveExplicitDeclaredType's full-file
  ** scan from being invoked on non-identifier text.
  **
  private static Bool isSimpleIdentifier(Str expr)
  {
    if (expr.isEmpty || expr[0].isDigit) return false
    return expr.all |ch| { ch.isAlphaNum || ch == '_' }
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
