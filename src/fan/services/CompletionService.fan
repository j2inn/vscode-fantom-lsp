
using compiler

**
** CompletionService - Provides autocompletion suggestions
**
class CompletionService
{
  ** Completion definitions loaded from YML resource
  private const CompletionDefs defs := CompletionDefs.cur

  ** Type aliases from YML (simple name -> qualified name)
  private Str:Str sysTypes() { defs.typeAliases }

  **
  ** Process-level cache: qualified type name → CompletionItem[].
  ** Runtime type reflection results never change within a JVM process,
  ** so this cache is permanent (no invalidation needed).
  **
  private static const Unsafe runtimeMemberCache :=
    Unsafe(Str:CompletionItem[][:])

  private static CompletionItem[]? cachedRuntimeMembers(Str qname)
  {
    ((Str:CompletionItem[])runtimeMemberCache.val)[qname]
  }

  private static Void cacheRuntimeMembers(Str qname, CompletionItem[] items)
  {
    ((Str:CompletionItem[])runtimeMemberCache.val)[qname] = items
  }

  ** Using-pod index — rebuilt only when the using-fingerprint changes
  private UsingPodIndex? usingIdx := null

  ** Fingerprint of the using statements that produced usingIdx
  private Str? usingFingerprint := null

  ** Scope-aware non-member identifier completions
  private CompletionScopeProvider scopeProvider := CompletionScopeProvider()

  **
  ** Get completions at the given position
  **
  CompletionItem[] complete(Str uri, LspPosition pos, Str source, ProjectIndex index)
  {
    request := CompletionRequestBuilder()
      .withUri(uri)
      .withPos(pos)
      .withSource(source)
      .withIndex(index)
      .build

    return completeRequest(request)
  }

  **
  ** Get completions using a builder-created request object.
  **
  CompletionItem[] completeRequest(CompletionRequest request)
  {
    uri := request.uri
    pos := request.pos
    source := request.source
    index := request.index

    try
    {
      line := LspUtil.getLine(source, pos.line)
      if (line == null) return CompletionItem[,]

      // Rebuild using-pod index only when the set of using pods has changed.
      fp := UsingPodIndex.fingerprintFor(source)
      if (usingIdx == null || fp != usingFingerprint)
      {
        usingIdx = UsingPodIndex.fromSource(source)
        usingFingerprint = fp
      }

      // Using statement completion: "using podName" or "using podName::TypeName"
      trimmedLine := line.trim
      if (trimmedLine.startsWith("using "))
        return completeUsing(trimmedLine)

      // Member access: obj. or obj.partial
      if (isMemberAccess(line, pos.character))
        return completeMemberAccess(uri, pos, source, line, index)

      // Identifier/type completion (non-member context)
      word := LspUtil.getWordAtPosition(source, pos)
      prefix := word ?: ""

      inScope := scopeProvider.complete(pos, source, index, prefix)
      typeItems := prefix.size > 0 ? completeTypeNames(prefix, index) : CompletionItem[,]

      // For lowercase prefixes, favor in-scope identifiers (locals/params/fields).
      // Type names are typically UpperCamelCase in Fantom and can drown local
      // suggestions when both match the same lowercase prefix.
      if (prefix.size > 0 && prefix[0].isLower && !inScope.isEmpty)
        typeItems = CompletionItem[,]

      LspProtocol.logInfo("Completion merge: prefix='${prefix}' inScope=${inScope.size} typeItems=${typeItems.size}")

      if (!inScope.isEmpty || !typeItems.isEmpty)
      {
        merged := mergeCompletions(inScope, typeItems)
        LspProtocol.logInfo("Completion result: merged=${merged.size}")
        return merged
      }

      return CompletionItem[,]
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Completion error: $e")
      return CompletionItem[,]
    }
  }

  // ---- Completion merge ----

  **
  ** Merge completion lists by label while preserving source order.
  **
  private CompletionItem[] mergeCompletions(CompletionItem[] first, CompletionItem[] second)
  {
    result := CompletionItem[,]
    seen := Str:Bool[:]

    first.each |item|
    {
      if (seen.containsKey(item.label)) return
      seen[item.label] = true
      result.add(item)
    }

    second.each |item|
    {
      if (seen.containsKey(item.label)) return
      seen[item.label] = true
      result.add(item)
    }

    return result
  }

  // ---- Member Access ----

  **
  ** Check if this is a member access context (e.g., "obj." or "obj.m")
  **
  private Bool isMemberAccess(Str line, Int col)
  {
    if (col == 0) return false

    // Previous character is '.'
    if (col - 1 < line.size && line[col - 1] == '.') return true

    // Look backward past identifier chars for a dot
    i := col - 1
    while (i >= 0 && i < line.size && (line[i].isAlphaNum || line[i] == '_'))
      i--
    if (i >= 0 && i < line.size && line[i] == '.') return true

    return false
  }

  **
  ** Complete member access (methods and fields of a type)
  **
  private CompletionItem[] completeMemberAccess(Str uri, LspPosition pos, Str source, Str line, ProjectIndex index)
  {
    try
    {
      // Find the dot position
      dotIdx := findDotPosition(line, pos.character)
      if (dotIdx < 0) return CompletionItem[,]

      beforeDot := line[0..<dotIdx].trimEnd

      // "this." — complete current class members
      if (beforeDot.endsWith("this"))
        return completeThis(uri, pos, source, index)

      // String literal
      if (beforeDot.endsWith("\""))
        return completeForType("sys::Str", uri, source, index)

      // List literal [...]
      if (beforeDot.endsWith("]") && !beforeDot.endsWith("[:]"))
        return completeForType("sys::List", uri, source, index)

      // Map literal [:]
      if (beforeDot.endsWith("[:]") || (beforeDot.contains("[") && beforeDot.contains(":")))
        return completeForType("sys::Map", uri, source, index)

      // Get word before dot
      varName := getWordBeforeDot(beforeDot)
      if (varName != null)
      {
        // Check if it's a type name (static access: TypeName.method)
        if (varName.size > 0 && varName[0].isUpper)
        {
          resolved := resolveTypeName(varName, index)
          if (resolved != null)
            return completeForType(resolved, uri, source, index, true)
        }

        // Otherwise resolve as a variable
        typeName := resolveVariableType(varName, source, pos.line, index)
        if (typeName != null)
          return completeForType(typeName, uri, source, index)
      }

      return CompletionItem[,]
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error completing member access: $e")
      return CompletionItem[,]
    }
  }

  **
  ** Find the dot position in line relative to cursor
  **
  private Int findDotPosition(Str line, Int col)
  {
    i := col - 1
    // Skip identifier chars (partial member name)
    while (i >= 0 && i < line.size && (line[i].isAlphaNum || line[i] == '_'))
      i--
    if (i >= 0 && i < line.size && line[i] == '.') return i
    return -1
  }

  // ---- Type Resolution ----

  **
  ** Resolve the type of a variable by examining declarations in source.
  ** Returns qualified type (sys::Str) or simple name (MyClass) for project types.
  **
  private Str? resolveVariableType(Str varName, Str source, Int currentLine, ProjectIndex index)
  {
    lines := source.splitLines

    // 1. Check method parameters of enclosing method
    paramType := findParameterType(varName, lines, currentLine)
    if (paramType != null) return resolveTypeName(paramType, index)

    // 2. Scan backwards for variable/field declarations
    for (i := currentLine; i >= 0 && i >= currentLine - 100; i--)
    {
      if (i >= lines.size) continue
      line := lines[i].trim

      // Skip empty/comment lines
      if (line.isEmpty || line.startsWith("//") || line.startsWith("**")) continue

      // Pattern: Type varName := ... or Type? varName := ...
      // Pattern: Type varName (field declaration)
      typeName := extractTypeForVariable(line, varName)
      if (typeName != null) return resolveTypeName(typeName, index)
    }

    // 3. Infer type from right-hand side expression (text-based, works even
    //    when the compiler can't resolve types due to external pods)
    for (i := currentLine; i >= 0 && i >= currentLine - 100; i--)
    {
      if (i >= lines.size) continue
      line := lines[i].trim
      if (line.isEmpty || line.startsWith("//") || line.startsWith("**")) continue

      rhsType := inferTypeFromRhs(line, varName, index)
      if (rhsType != null) return rhsType
    }

    // 4. Use compiler type inference as last resort (handles complex expressions)
    return resolveViaCompiler(varName, source, currentLine)
  }

  **
  ** Infer a variable's type from the right-hand side of its assignment.
  ** Handles: varName := [...], varName := [:], varName := "...",
  ** varName := 123, varName := true/false, varName := Type(...), varName := Type.method(...)
  **
  private Str? inferTypeFromRhs(Str line, Str varName, ProjectIndex index)
  {
    // Find "varName :=" pattern
    assignIdx := findAssignmentInLine(line, varName)
    if (assignIdx == null) return null

    rhs := line[assignIdx ..-1].trim

    // String literal: "..."
    if (rhs.startsWith("\"")) return "sys::Str"

    // List literal: [item, ...] (but not [:] or [key:val])
    if (rhs.startsWith("["))
    {
      if (rhs.startsWith("[:]")) return "sys::Map"
      // Check if it's a map literal (has : before first ])
      bracketContent := extractBracketContent(rhs)
      if (bracketContent != null && bracketContent.contains(":"))
        return "sys::Map"
      return "sys::List"
    }

    // Boolean literals
    if (rhs == "true" || rhs == "false" ||
        rhs.startsWith("true ") || rhs.startsWith("false "))
      return "sys::Bool"

    // Numeric literal
    numType := inferNumericType(rhs)
    if (numType != null) return numType

    // Type constructor: TypeName(...) or TypeName.make(...)
    ctorType := inferConstructorType(rhs, index)
    if (ctorType != null) return ctorType

    // Static method call: TypeName.method(...)
    staticType := inferStaticCallType(rhs, index)
    if (staticType != null) return staticType

    return null
  }

  **
  ** Find ":=" after varName in a line and return the index of the RHS start.
  **
  private Int? findAssignmentInLine(Str line, Str varName)
  {
    varIdx := findVariableInLine(line, varName)
    if (varIdx == null) return null

    // Look for := after the variable name
    afterVar := varIdx + varName.size
    assignIdx := line.index(":=", afterVar)
    if (assignIdx == null) return null

    return assignIdx + 2
  }

  **
  ** Extract content inside first [...] in a string, handling nesting.
  **
  private Str? extractBracketContent(Str text)
  {
    if (!text.startsWith("[")) return null
    depth := 0
    for (i := 0; i < text.size; i++)
    {
      if (text[i] == '[') depth++
      else if (text[i] == ']') { depth--; if (depth == 0) return text[1 ..< i] }
    }
    return null
  }

  **
  ** Infer numeric type from an RHS expression.
  **
  private Str? inferNumericType(Str rhs)
  {
    if (rhs.isEmpty) return null
    first := rhs[0]

    // Negative number
    start := first == '-' ? 1 : 0
    if (start >= rhs.size) return null
    if (!rhs[start].isDigit) return null

    // Float: contains . or ends with f
    if (rhs.contains(".") || rhs.endsWith("f") || rhs.endsWith("F"))
      return "sys::Float"

    // Decimal: ends with d
    if (rhs.endsWith("d") || rhs.endsWith("D"))
      return "sys::Decimal"

    return "sys::Int"
  }

  **
  ** Infer type from a constructor call: TypeName(...) or TypeName { ... }
  **
  private Str? inferConstructorType(Str rhs, ProjectIndex index)
  {
    // Match: TypeName( or TypeName {
    parenIdx := rhs.index("(")
    braceIdx := rhs.index("{")
    endIdx := parenIdx
    if (endIdx == null || (braceIdx != null && braceIdx < endIdx))
      endIdx = braceIdx
    if (endIdx == null || endIdx == 0) return null

    typeName := rhs[0 ..< endIdx].trim
    if (typeName.isEmpty || !typeName[0].isUpper) return null
    // Must be a simple identifier
    if (!typeName.all |ch| { ch.isAlphaNum || ch == '_' }) return null

    return resolveTypeName(typeName, index)
  }

  **
  ** Infer type from a static method/field access that returns the same type.
  ** E.g., Str.defVal → Str, Uri.fromStr(...) → Uri
  **
  private Str? inferStaticCallType(Str rhs, ProjectIndex index)
  {
    dotIdx := rhs.index(".")
    if (dotIdx == null || dotIdx == 0) return null

    typeName := rhs[0 ..< dotIdx].trim
    if (typeName.isEmpty || !typeName[0].isUpper) return null
    if (!typeName.all |ch| { ch.isAlphaNum || ch == '_' }) return null

    return resolveTypeName(typeName, index)
  }

  **
  ** Use the Fantom compiler's type inference to resolve a variable's type.
  ** After frontend(), MethodDef.vars contains MethodVar objects with resolved ctype.
  ** We strip the cursor line (which has incomplete code like "a.") to avoid parse errors.
  **
  private Str? resolveViaCompiler(Str varName, Str source, Int currentLine)
  {
    try
    {
      // Strip the cursor line to avoid syntax errors from incomplete expressions
      lines := source.splitLines
      if (currentLine >= 0 && currentLine < lines.size)
        lines[currentLine] = ""
      cleanSource := lines.join("\n")

      compiler := LspCompiler.create("file:///completion.fan", cleanSource)
      try { compiler.frontend } catch {}
      if (compiler.types == null) return null

      // Find the method that contains the cursor line (1-based in compiler)
      cursorLine := currentLine + 1
      for (ti := 0; ti < compiler.types.size; ti++)
      {
        ctype := compiler.types[ti]
        if (ctype isnot TypeDef) continue
        td := (TypeDef)ctype

        for (mi := 0; mi < td.methodDefs.size; mi++)
        {
          md := td.methodDefs[mi]

          // Check if cursor is within this method's line range
          if (md.loc.line > cursorLine) continue
          if (md.code == null) continue

          // Search for matching variable in method vars
          for (vi := 0; vi < md.vars.size; vi++)
          {
            v := md.vars[vi]
            if (v.name == varName)
              return v.ctype.signature
          }
        }
      }
    }
    catch (Err e) {}
    return null
  }

  **
  ** Extract the declared type for a variable from a line.
  ** Handles: "Str name :=", "Int? count :=", "Str[] items :=",
  ** "[Str:Int] map :=", "private Str name", "const Str name"
  **
  private Str? extractTypeForVariable(Str line, Str varName)
  {
    // Must contain the variable name
    varIdx := findVariableInLine(line, varName)
    if (varIdx == null) return null

    // Get everything before the variable name
    before := line[0..<varIdx].trim

    // Strip modifiers
    before = stripModifiers(before)
    if (before.isEmpty) return null

    // Handle Str[] → List
    if (before.endsWith("[]"))
      return "List"

    // Handle [Type:Type] → Map
    if (before.startsWith("[") && before.endsWith("]") && before.contains(":"))
      return "Map"

    // Handle Type? → Type
    typeName := before.endsWith("?") ? before[0..<before.size - 1] : before

    // Validate it looks like a type name (starts with uppercase)
    if (typeName.isEmpty || !typeName[0].isUpper) return null

    // Strip generic params: List<Str> → List
    angleIdx := typeName.index("<")
    if (angleIdx != null) typeName = typeName[0..<angleIdx]

    return typeName
  }

  **
  ** Find the exact position of a variable name in a line (word boundary match).
  **
  private Int? findVariableInLine(Str line, Str varName)
  {
    idx := 0
    while (true)
    {
      found := line.index(varName, idx)
      if (found == null) return null

      endPos := found + varName.size

      // Check word boundaries
      beforeOk := found == 0 || !line[found - 1].isAlphaNum
      afterOk := endPos >= line.size || !line[endPos].isAlphaNum

      if (beforeOk && afterOk) return found
      idx = found + 1
    }
    return null // unreachable but satisfies compiler
  }

  **
  ** Strip Fantom modifiers from a type declaration prefix.
  **
  private Str stripModifiers(Str text)
  {
    modifiers := ["public", "private", "protected", "internal",
                  "static", "const", "final", "abstract",
                  "virtual", "override", "native", "once", "readonly"]
    result := text
    modifiers.each |mod|
    {
      while (result.startsWith(mod + " ") || result.startsWith(mod + "\t"))
        result = result[mod.size + 1..-1].trim
    }
    return result
  }

  **
  ** Find the type of a method parameter.
  ** Scans backwards to find the enclosing method declaration.
  **
  private Str? findParameterType(Str paramName, Str[] lines, Int currentLine)
  {
    for (i := currentLine; i >= 0 && i >= currentLine - 50; i--)
    {
      if (i >= lines.size) continue
      line := lines[i].trim

      // Look for method declaration with parentheses
      parenOpen := line.index("(")
      if (parenOpen == null) continue

      parenClose := line.index(")", parenOpen)
      if (parenClose == null) continue

      // Check if this looks like a method declaration (has return type before name)
      beforeParen := line[0..<parenOpen].trim
      if (!beforeParen.contains(" ")) continue

      // Extract parameter list
      paramStr := line[parenOpen + 1 ..< parenClose]
      params := paramStr.split(',')
      param := params.find |p|
      {
        p.trim.endsWith(paramName) || p.trim.contains(paramName + " ") ||
        p.trim.contains(paramName + ":=")
      }

      if (param != null)
      {
        // Extract type from "Type name" or "Type? name"
        words := param.trim.split(' ').findAll |w| { !w.isEmpty }
        if (words.size >= 2)
        {
          typePart := words[0]
          if (typePart.endsWith("?")) typePart = typePart[0..<typePart.size - 1]
          if (typePart.size > 0 && typePart[0].isUpper)
            return typePart
        }
      }
    }
    return null
  }

  **
  ** Resolve a simple type name to a qualified name.
  ** Known sys types → sys::TypeName. Project types → as-is.
  **
  private Str? resolveTypeName(Str typeName, ProjectIndex index)
  {
    // Check sys types first (YML aliases)
    qualified := sysTypes[typeName]
    if (qualified != null) return qualified

    // Check project index
    if (index.hasType(typeName)) return typeName

    // Check using-pod types (types from pods referenced in using statements)
    if (usingIdx != null)
    {
      t := usingIdx.getType(typeName)
      if (t != null) return t.qname
    }

    // Search all preloaded pods as last resort (covers types from pods not
    // explicitly imported via 'using', e.g. typing Number. without using haystack)
    Str? podQname := null
    Pod.list.eachWhile |pod -> Obj?|
    {
      t := pod.type(typeName, false)
      if (t != null && t.isPublic) { podQname = t.qname; return "done" }
      return null
    }
    return podQname
  }

  // ---- this. completion ----

  **
  ** Complete members of the current class (this.)
  **
  private CompletionItem[] completeThis(Str uri, LspPosition pos, Str source, ProjectIndex index)
  {
    // Find enclosing class name
    lines := source.splitLines
    className := null as Str
    for (i := pos.line; i >= 0; i--)
    {
      if (i >= lines.size) continue
      line := lines[i].trim
      classIdx := line.index("class ")
      if (classIdx != null)
      {
        after := line[classIdx + 6 ..-1].trim
        // Extract class name (first uppercase identifier)
        end := 0
        while (end < after.size && (after[end].isAlphaNum || after[end] == '_')) end++
        if (end > 0 && after[0].isUpper)
        {
          className = after[0..<end]
          break
        }
      }
    }

    if (className == null) return CompletionItem[,]

    // Try to compile current file and get TypeDef
    return completeForType(className, uri, source, index)
  }

  // ---- Completions for Type ----

  **
  ** Get the word/identifier immediately before the dot
  **
  private Str? getWordBeforeDot(Str text)
  {
    if (text.isEmpty) return null
    end := text.size
    start := end - 1

    // Skip whitespace
    while (start >= 0 && start < text.size && text[start].isSpace)
      start--
    if (start < 0) return null
    end = start + 1

    // Get the identifier
    while (start >= 0 && start < text.size && (text[start].isAlphaNum || text[start] == '_'))
      start--
    start++

    return (start >= 0 && start < end && end <= text.size) ? text[start..<end] : null
  }

  **
  ** Get completions for a specific type
  **
  private CompletionItem[] completeForType(Str typeName, Str uri, Str source, ProjectIndex index, Bool isStatic := false)
  {
    try
    {
      // Normalize compiler type signatures to base type name
      normalized := normalizeTypeName(typeName)

      // Check YML definitions first (preferred source for sys types)
      ymlItems := defs.itemsFor(normalized)
      if (ymlItems != null) return ymlItems

      // Try runtime type as fallback (sys types not in YML)
      Type? type := null
      try { type = Type.find(normalized, false) } catch {}

      if (type != null)
        return completeForRuntimeType(type, isStatic)

      // Try user type (compile from source or index)
      return completeForUserType(normalized, uri, source, index)
    }
    catch (Err e)
    {
      return CompletionItem[,]
    }
  }

  **
  ** Normalize a compiler type signature to a findable type name.
  ** "sys::Int[]" → "sys::List", "[sys::Str:sys::Int]" → "sys::Map",
  ** "sys::Str?" → "sys::Str"
  **
  private Str normalizeTypeName(Str typeName)
  {
    // List type: anything ending with []
    if (typeName.endsWith("[]"))
      return "sys::List"

    // Nullable: strip trailing ?
    if (typeName.endsWith("?"))
      return normalizeTypeName(typeName[0 ..< typeName.size - 1])

    // Map type: [K:V]
    if (typeName.startsWith("[") && typeName.endsWith("]") && typeName.contains(":"))
      return "sys::Map"

    return typeName
  }

  **
  ** Get completions for a runtime type (using reflection).
  ** Results are cached permanently by qualified name + access mode
  ** because runtime type members never change within a JVM process.
  **
  private CompletionItem[] completeForRuntimeType(Type type, Bool isStatic := false)
  {
    cacheKey := isStatic ? "${type.qname}#static" : type.qname
    cached := cachedRuntimeMembers(cacheKey)
    if (cached != null) return cached

    items := CompletionItem[,]
    seen := Str:Bool[:]

    type.methods.each |method|
    {
      // Skip private/internal and synthetic
      if (method.isPrivate || method.isInternal) return
      // Skip constructors for instance access (they only make sense as TypeName.make)
      if (method.isCtor && !isStatic) return
      // Skip duplicates (inherited + overridden)
      if (seen.containsKey(method.name)) return
      seen[method.name] = true

      snippet := generateMethodSnippet(method)
      items.add(CompletionItem(
        method.name,
        CompletionItemKind.method,
        method.signature,
        method.doc,
        snippet,
        snippet != null ? 2 : null
      ))
    }

    type.fields.each |field|
    {
      if (field.isPrivate || field.isInternal) return
      if (seen.containsKey(field.name)) return
      seen[field.name] = true
      items.add(CompletionItem(
        field.name,
        CompletionItemKind.field,
        field.signature,
        field.doc
      ))
    }

    cacheRuntimeMembers(cacheKey, items)
    return items
  }

  **
  ** Get completions for a user-defined type (using compiler + index)
  **
  private CompletionItem[] completeForUserType(Str typeName, Str uri, Str source, ProjectIndex index)
  {
    try
    {
      // First try to get members from project index (fast)
      members := index.getTypeMembers(typeName)
      if (!members.isEmpty)
      {
        items := CompletionItem[,]
        seen := Str:Bool[:]
        members.each |sym|
        {
          if (seen.containsKey(sym.name)) return
          seen[sym.name] = true
          kind := sym.kind == SymbolKind.method
            ? CompletionItemKind.method : CompletionItemKind.field

          // Build detail string (return type + params for methods)
          detail := null as Str
          if (sym.kind == SymbolKind.method)
          {
            retStr := sym.typeStr ?: "Void"
            paramDisp := sym.paramStr != null ? "(${sym.paramStr})" : "()"
            detail = "${retStr} ${sym.name}${paramDisp}"
          }
          else if (sym.typeStr != null)
          {
            detail = "${sym.typeStr} ${sym.name}"
          }

          // Build snippet with parameter placeholders for methods
          snippet := null as Str
          snippetFmt := null as Int
          if (sym.kind == SymbolKind.method && sym.paramStr != null)
          {
            snippet = generateUserMethodSnippet(sym.name, sym.paramStr)
            snippetFmt = 2 // Snippet format
          }

          items.add(CompletionItem(sym.name, kind, detail, sym.doc, snippet, snippetFmt))
        }
        return items
      }

      // Fall back to compiling the source file
      typeDef := findTypeDefInSource(typeName, uri, source, index)
      if (typeDef == null) return CompletionItem[,]

      items := CompletionItem[,]
      seen := Str:Bool[:]

      for (i := 0; i < typeDef.methodDefs.size; i++)
      {
        m := typeDef.methodDefs[i]
        if (m.isPrivate) continue
        if (seen.containsKey(m.name)) continue
        seen[m.name] = true
        items.add(CompletionItem(m.name, CompletionItemKind.method, m.signature))
      }

      for (i := 0; i < typeDef.fieldDefs.size; i++)
      {
        f := typeDef.fieldDefs[i]
        if (f.isPrivate) continue
        if (seen.containsKey(f.name)) continue
        seen[f.name] = true
        items.add(CompletionItem(f.name, CompletionItemKind.field, f.signature))
      }

      return items
    }
    catch (Err e)
    {
      return CompletionItem[,]
    }
  }

  **
  ** Find a TypeDef by compiling the current file or a project file.
  **
  private TypeDef? findTypeDefInSource(Str typeName, Str uri, Str source, ProjectIndex index)
  {
    // Try current file
    td := compileAndFindType(uri, source, typeName)
    if (td != null) return td

    // Try project file via index
    syms := index.findSymbols(typeName)
    typeSym := syms.find |s| { s.kind == SymbolKind.type }
    if (typeSym == null) return null

    file := LspUtil.uriToFile(typeSym.fileUri)
    if (!file.exists) return null

    return compileAndFindType(typeSym.fileUri, file.readAllStr, typeName)
  }

  **
  ** Compile source and find a TypeDef by name.
  **
  private TypeDef? compileAndFindType(Str uri, Str source, Str typeName)
  {
    try
    {
      compiler := LspCompiler.create(uri, source)
      try { compiler.frontend } catch (CompilerErr e) {}
      if (compiler.types == null) return null

      for (i := 0; i < compiler.types.size; i++)
      {
        ctype := compiler.types[i]
        if (ctype isnot TypeDef) continue
        td := (TypeDef)ctype
        if (td.name == typeName) return td
      }
    }
    catch (Err e) {}
    return null
  }

  // ---- Snippets ----

  **
  ** Generate snippet for a method with function parameters
  **
  private Str? generateMethodSnippet(Method method)
  {
    try
    {
      if (method.params.isEmpty) return null
      funcParams := method.params.findAll |p| { p.type.fits(Func#) }

      snippet := StrBuf()
      snippet.add(method.name)

      tabIndex := 1
      paramIndex := 0

      // Regular parameters
      method.params.each |param|
      {
        if (!param.type.fits(Func#))
        {
          snippet.add(paramIndex == 0 ? "(" : ", ")
          snippet.add("\${${tabIndex}:${param.name}}")
          tabIndex++
          paramIndex++
        }
      }
      if (paramIndex > 0) snippet.add(")")

      // Function parameter closure
      funcParams.each |funcParam|
      {
        snippet.add(" |")
        sig := funcParam.type.signature
        paramNames := extractFuncParamNames(sig)
        hasReturn := hasNonVoidReturn(sig)

        for (pi := 0; pi < paramNames.size; pi++)
        {
          if (pi > 0) snippet.add(", ")
          snippet.add("\${${tabIndex}:${paramNames[pi]}}")
          tabIndex++
        }

        snippet.add("| {\n")
        if (hasReturn)
          snippet.add("\treturn \$0\n")
        else
          snippet.add("\t\$0\n")
        snippet.add("}")
      }

      return snippet.toStr
    }
    catch (Err e) { return null }
  }

  **
  ** Extract parameter names from a Func type signature.
  ** E.g. "|sys::Obj?,sys::Int->sys::Void|" -> ["val", "index"]
  ** "|sys::Obj?,sys::Obj?->sys::Int|" -> ["a", "b"]
  **
  private Str[] extractFuncParamNames(Str signature)
  {
    if (!signature.contains("|")) return ["it"]
    pipeIdx := signature.index("|")
    if (pipeIdx == null) return ["it"]
    arrowIdx := signature.index("->")
    paramPart := arrowIdx != null
      ? signature[pipeIdx + 1 ..< arrowIdx]
      : signature[pipeIdx + 1 .. -1]
    paramPart = paramPart.trim
    if (paramPart.isEmpty) return Str[,]

    params := paramPart.split(',')
    count := params.size

    // Generate meaningful names based on parameter count and types
    if (count == 1) return ["it"]
    if (count == 2)
    {
      // Check if second param is Int (index pattern)
      second := params[1].trim
      if (second.contains("Int"))
        return ["val", "index"]
      // Two same-ish types -> comparison pattern
      return ["a", "b"]
    }
    if (count == 3) return ["acc", "val", "index"]

    // Fallback: generic names
    names := Str[,]
    count.times |i| { names.add("p${i}") }
    return names
  }

  **
  ** Check if a Func signature has a non-Void return type.
  ** "|sys::Obj?->sys::Void|" -> false
  ** "|sys::Obj?->sys::Bool|" -> true
  **
  private Bool hasNonVoidReturn(Str signature)
  {
    arrowIdx := signature.index("->")
    if (arrowIdx == null) return false
    pipeEndIdx := signature.indexr("|")
    if (pipeEndIdx == null || pipeEndIdx <= arrowIdx) return false
    retType := signature[arrowIdx + 2 ..< pipeEndIdx].trim
    return !retType.isEmpty && retType != "sys::Void" && retType != "Void"
  }

  **
  ** Generate snippet with parameter placeholders for a user-defined method.
  ** paramStr is e.g. "Str name, Int count" → "methodName(${1:name}, ${2:count})"
  **
  private Str? generateUserMethodSnippet(Str methodName, Str paramStr)
  {
    try
    {
      parts := paramStr.split(',')
      if (parts.isEmpty) return null

      snippet := StrBuf()
      snippet.add(methodName).add("(")
      tabIdx := 1
      parts.each |part, i|
      {
        if (i > 0) snippet.add(", ")
        p := part.trim
        // Extract param name: last word in "Type name" or "Type? name" or just "name"
        words := p.split(' ').findAll |w| { w.size > 0 }
        paramName := words.size >= 2 ? words[-1] : p
        // Strip default value
        eqIdx := paramName.index(":=")
        if (eqIdx != null) paramName = paramName[0..<eqIdx]
        snippet.add("\${${tabIdx}:${paramName}}")
        tabIdx++
      }
      snippet.add(")")
      return snippet.toStr
    }
    catch (Err e) { return null }
  }

  // ---- Type Name Completion ----

  **
  ** Complete type names from sys types and project index
  **
  private CompletionItem[] completeTypeNames(Str prefix, ProjectIndex index)
  {
    items := CompletionItem[,]
    seen := Str:Bool[:]
    prefixLower := prefix.lower

    // Sys types (from YML)
    sysTypes.each |qualified, name|
    {
      if (name.lower.startsWith(prefixLower))
      {
        items.add(CompletionItem(name, CompletionItemKind.classKind, qualified, null, null, null, "900_${name}"))
        seen[name] = true
      }
    }

    // Project types from index
    index.allTypeNames.each |name|
    {
      if (name.lower.startsWith(prefixLower) && !seen.containsKey(name))
      {
        items.add(CompletionItem(name, CompletionItemKind.classKind, "project type", null, null, null, "900_${name}"))
        seen[name] = true
      }
    }

    // Types from pods referenced in using statements
    if (usingIdx != null)
    {
      usingIdx.allTypes.each |t|
      {
        if (t.name.lower.startsWith(prefixLower) && !seen.containsKey(t.name))
        {
          items.add(CompletionItem(t.name, CompletionItemKind.classKind, t.qname, null, null, null, "900_${t.name}"))
          seen[t.name] = true
        }
      }
    }

    return items
  }

  **
  ** Complete a 'using' statement.
  ** - "using podName::" → complete public type names from that pod
  ** - "using partial"   → complete pod names from lib/fan/*.pod
  **
  private CompletionItem[] completeUsing(Str trimmedLine)
  {
    rest := trimmedLine["using ".size..-1]

    // "using podName::" or "using podName::TypePrefix" → complete type names
    colonIdx := rest.index("::")
    if (colonIdx != null)
    {
      podName := rest[0..<colonIdx].trim
      typePrefix := rest[colonIdx + 2..-1].trim
      pod := Pod.find(podName, false)
      if (pod == null) return CompletionItem[,]
      items := CompletionItem[,]
      prefixLower := typePrefix.lower
      pod.types.each |t|
      {
        if (t.isPublic && t.name.lower.startsWith(prefixLower))
          items.add(CompletionItem(t.name, CompletionItemKind.classKind, t.qname))
      }
      return items
    }

    // "using partialPodName" → complete pod names from lib/fan/*.pod
    items := CompletionItem[,]
    prefixLower := rest.lower
    try
    {
      libDir := Env.cur.homeDir + `lib/fan/`
      if (libDir.exists)
      {
        libDir.list.each |f|
        {
          if (f.ext == "pod")
          {
            podName := f.basename
            if (podName.lower.startsWith(prefixLower))
              items.add(CompletionItem(podName, CompletionItemKind.module, "pod"))
          }
        }
      }
    }
    catch (Err e) {}
    return items
  }
}

**************************************************************************
** FuncSnippet
**************************************************************************

**
** Helper class to return function snippet with next tab index
**
internal class FuncSnippet
{
  Str snippet
  Int nextTabIndex

  new make(Str snippet, Int nextTabIndex)
  {
    this.snippet = snippet
    this.nextTabIndex = nextTabIndex
  }
}
