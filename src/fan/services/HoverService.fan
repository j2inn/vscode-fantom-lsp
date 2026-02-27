//
// Copyright (c) 2025, Brian Frank and Andy Frank
// Licensed under the Academic Free License version 3.0
//
// History:
//   9 Feb 26  Creation
//

using compiler

**
** HoverService - Provides hover information (type signatures, docs) for symbols
**
class HoverService
{
  **
  ** Get hover information for a symbol at the given position.
  ** Returns an LSP Hover object (map with "contents" and optional "range"),
  ** or null if no hover info is available.
  **
  [Str:Obj?]? hover(Str uri, LspPosition pos, Str source, ProjectIndex index)
  {
    try
    {
      // Get the word at cursor position
      word := LspUtil.getWordAtPosition(source, pos)
      if (word == null || word.isEmpty) return null

      LspProtocol.logInfo("Hover for: '$word'")

      // Get the line to understand context (e.g., "obj.method" vs "Type")
      line := LspUtil.getLine(source, pos.line)
      if (line == null) return null

      // Try to resolve the symbol via compilation
      info := resolveViaCompiler(uri, source, word, pos)
      if (info != null) return createHover(info, pos, word, line)

      // For lowercase words (variables/params), check TypeResolver BEFORE reflection.
      // The pod-slot search in resolveViaReflection is too broad: any lowercase word
      // that matches a slot name on a using-pod type (e.g. "type" matches
      // FilterType.type, "val" matches Dict.val, etc.) gets hijacked, hiding the
      // actual local-variable type.  Resolving the declaration first gives the
      // correct result and falls through to reflection only when nothing is found.
      if (word.size > 0 && word[0].isLower)
      {
        varType := TypeResolver.resolveVarType(word, source, pos.line, index)
        if (varType != null)
        {
          displayType := varType.startsWith("sys::") ? varType["sys::".size..-1] : varType
          info = "```fantom\n(variable) ${word}: ${displayType}\n```"
          return createHover(info, pos, word, line)
        }
      }

      // Try context-aware resolution: receiver.word patterns
      info = resolveViaContext(word, line, pos.character, source, pos.line, index)
      if (info != null) return createHover(info, pos, word, line)

      // Try to resolve from reflected pods (for types from dependencies)
      info = resolveViaReflection(word, source)
      if (info != null) return createHover(info, pos, word, line)

      // Try to resolve from project files via index
      info = resolveFromProjectFiles(uri, word, index)
      if (info != null) return createHover(info, pos, word, line)

      // Try project index as fallback (when pod isn't built yet)
      info = resolveViaProjectIndex(word, index)
      if (info != null) return createHover(info, pos, word, line)

      // Last-resort: TypeResolver for uppercase words not found via reflection
      if (word.size > 0 && word[0].isUpper)
      {
        varType := TypeResolver.resolveVarType(word, source, pos.line, index)
        if (varType != null)
        {
          displayType := varType.startsWith("sys::") ? varType["sys::".size..-1] : varType
          info = "```fantom\n(variable) ${word}: ${displayType}\n```"
          return createHover(info, pos, word, line)
        }
      }

      return null
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error during hover: $e")
      return null
    }
  }

  **
  ** Resolve symbol info by compiling the current file
  **
  private Str? resolveViaCompiler(Str uri, Str source, Str word, LspPosition pos)
  {
    try
    {
      compiler := LspCompiler.create(uri, source)
      try { compiler.frontend }
      catch (CompilerErr e) {}

      if (compiler.types == null) return null

      for (i := 0; i < compiler.types.size; i++)
      {
        ctype := compiler.types[i]
        if (ctype isnot TypeDef) continue
        td := (TypeDef)ctype

        // Check if hovering over the type name itself
        if (td.name == word)
        {
          return formatTypeDef(td)
        }

        // Check methods
        for (j := 0; j < td.methodDefs.size; j++)
        {
          m := td.methodDefs[j]
          if (m.name == word)
          {
            return formatMethodDef(m, td)
          }
        }

        // Check fields
        for (k := 0; k < td.fieldDefs.size; k++)
        {
          f := td.fieldDefs[k]
          if (f.name == word)
          {
            return formatFieldDef(f, td)
          }
        }
      }
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error resolving via compiler: $e")
    }
    return null
  }

  **
  ** Resolve symbol info via Fantom reflection (for dependency types)
  **
  private Str? resolveViaReflection(Str word, Str source)
  {
    try
    {
      // Extract using statements to know which pods to search
      pods := extractUsingPods(source)

      // If the word starts with uppercase, try to find it as a type
      if (word.size > 0 && word[0].isUpper)
      {
        // Search using pods
        for (i := 0; i < pods.size; i++)
        {
          pod := Pod.find(pods[i], false)
          if (pod == null) continue

          type := pod.type(word, false)
          if (type != null)
          {
            return formatReflectedType(type)
          }
        }

        // Also try sys pod
        sysType := Pod.find("sys", false)?.type(word, false)
        if (sysType != null) return formatReflectedType(sysType)
      }
      else
      {
        // Lowercase word - could be a method/field on a type
        // Search all using pods and sys for a method with this name
        allSearchPods := Str[,]
        allSearchPods.addAll(pods)
        if (!allSearchPods.contains("sys")) allSearchPods.add("sys")
        for (i := 0; i < allSearchPods.size; i++)
        {
          pod := Pod.find(allSearchPods[i], false)
          if (pod == null) continue

          podTypes := pod.types
          for (j := 0; j < podTypes.size; j++)
          {
            slot := podTypes[j].slot(word, false)
            if (slot != null)
            {
              return formatReflectedSlot(slot)
            }
          }
        }
      }
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error resolving via reflection: $e")
    }
    return null
  }

  **
  ** Try to resolve symbol from project pod via reflection
  **
  private Str? resolveFromProjectFiles(Str uri, Str word, ProjectIndex index)
  {
    try
    {
      if (index.podName == null) return null

      pod := Pod.find(index.podName, false)
      if (pod == null) return null

      if (word[0].isUpper)
      {
        type := pod.type(word, false)
        if (type != null) return formatReflectedType(type)
      }
      else
      {
        podTypes := pod.types
        for (i := 0; i < podTypes.size; i++)
        {
          slot := podTypes[i].slot(word, false)
          if (slot != null) return formatReflectedSlot(slot)
        }
      }
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error resolving from project files: $e")
    }
    return null
  }

  **
  ** Resolve slot info via receiver context analysis.
  ** Detects "receiver.word" patterns and resolves the slot on the receiver's type.
  ** Falls back to the project index when the pod is not yet built.
  **
  private Str? resolveViaContext(Str word, Str line, Int charPos, Str source, Int lineNum, ProjectIndex index)
  {
    try
    {
      wordStart := findWordStart(line, charPos)
      if (wordStart == 0) return null
      if (line[wordStart - 1] != '.') return null

      // Extract receiver identifier (simple name immediately before the dot)
      receiverEnd := wordStart - 1  // index of the '.'
      receiverStart := receiverEnd
      while (receiverStart > 0 && LspUtil.isIdentifierChar(line[receiverStart - 1]))
        receiverStart--
      if (receiverStart == receiverEnd) return null

      receiver := line[receiverStart..<receiverEnd]

      // Try reflection: find receiver as a type or resolve its declared type
      receiverType := findTypeByName(receiver, source, index)
      if (receiverType == null && !receiver.isEmpty && !receiver[0].isUpper)
      {
        typeName := TypeResolver.resolveVarType(receiver, source, lineNum, index)
        if (typeName != null)
          receiverType = findTypeByQname(typeName, source, index)
      }

      if (receiverType != null)
      {
        slot := receiverType.slot(word, false)
        if (slot != null) return formatReflectedSlot(slot)
      }

      // Fall back to project index when reflection is unavailable
      Str? receiverTypeName := null
      if (!receiver.isEmpty && receiver[0].isUpper)
        receiverTypeName = receiver
      else
      {
        typeName := TypeResolver.resolveVarType(receiver, source, lineNum, index)
        if (typeName != null)
        {
          colonIdx := typeName.index("::")
          receiverTypeName = colonIdx != null ? typeName[colonIdx + 2..-1] : typeName
        }
      }

      if (receiverTypeName != null)
      {
        sym := index.findMemberSymbol(receiverTypeName, word)
        if (sym != null) return formatIndexedSymbol(sym)
      }
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error resolving via context: $e")
    }
    return null
  }

  **
  ** Resolve a type name or method/field via the project symbol index.
  ** Used as a fallback when the project pod is not yet built.
  **
  private Str? resolveViaProjectIndex(Str word, ProjectIndex index)
  {
    try
    {
      syms := index.findSymbols(word)
      if (syms.isEmpty) return null

      // Prefer type symbols
      typeSym := syms.find |s| { s.kind == SymbolKind.type }
      if (typeSym != null) return formatIndexedSymbol(typeSym)

      // Then method/field (class-level only, skip local vars and params)
      memberSym := syms.find |s|
      {
        s.kind == SymbolKind.method || s.kind == SymbolKind.field || s.kind == SymbolKind.enumVal
      }
      if (memberSym != null) return formatIndexedSymbol(memberSym)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error resolving via project index: $e")
    }
    return null
  }

  **
  ** Find a reflected Type by simple name.
  ** Searches using pods, sys pod, and the project pod.
  **
  private Type? findTypeByName(Str name, Str source, ProjectIndex index)
  {
    if (name.isEmpty || !name[0].isUpper) return null

    pods := extractUsingPods(source)
    for (i := 0; i < pods.size; i++)
    {
      pod := Pod.find(pods[i], false)
      if (pod == null) continue
      t := pod.type(name, false)
      if (t != null) return t
    }

    t := Pod.find("sys", false)?.type(name, false)
    if (t != null) return t

    if (index.podName != null)
    {
      pod := Pod.find(index.podName, false)
      t = pod?.type(name, false)
      if (t != null) return t
    }

    return null
  }

  **
  ** Find a reflected Type by qualified or simple name.
  ** Handles "pod::Type", simple names, and sys type aliases.
  **
  private Type? findTypeByQname(Str qname, Str source, ProjectIndex index)
  {
    if (qname.isEmpty) return null
    name := qname.endsWith("?") ? qname[0..<qname.size - 1] : qname

    colonIdx := name.index("::")
    if (colonIdx != null)
    {
      podName := name[0..<colonIdx]
      typeName := name[colonIdx + 2..-1]
      pod := Pod.find(podName, false)
      return pod?.type(typeName, false)
    }

    return findTypeByName(name, source, index)
  }

  **
  ** Format an IndexedSymbol (from project index) for hover display
  **
  private Str formatIndexedSymbol(IndexedSymbol sym)
  {
    buf := StrBuf()
    buf.add("```fantom\n")

    if (sym.kind == SymbolKind.type)
    {
      buf.add("class ${sym.name}")
    }
    else if (sym.kind == SymbolKind.method)
    {
      retType := sym.typeStr ?: "Void"
      params  := sym.paramStr ?: ""
      typePfx := sym.typeName != null ? "${sym.typeName}." : ""
      buf.add("${retType} ${typePfx}${sym.name}(${params})")
    }
    else if (sym.kind == SymbolKind.field || sym.kind == SymbolKind.enumVal)
    {
      fldType := sym.typeStr ?: "Obj?"
      typePfx := sym.typeName != null ? "${sym.typeName}." : ""
      buf.add("${fldType} ${typePfx}${sym.name}")
    }
    else
    {
      buf.add(sym.name)
    }

    buf.add("\n```")

    if (sym.doc != null && sym.doc.size > 0)
    {
      firstLine := sym.doc.splitLines.first
      if (firstLine != null && firstLine.size > 0)
        buf.add("\n\n$firstLine")
    }

    return buf.toStr
  }

  **
  ** Extract pod names from "using" statements in source
  **
  private Str[] extractUsingPods(Str source)
  {
    pods := Str[,]
    source.splitLines.each |line|
    {
      trimmed := line.trim
      if (trimmed.startsWith("using "))
      {
        // "using podName" or "using podName::TypeName"
        rest := trimmed[6..-1].trim
        colonIdx := rest.index("::")
        podName := colonIdx != null ? rest[0..<colonIdx] : rest
        if (podName.size > 0 && !pods.contains(podName))
          pods.add(podName)
      }
    }
    return pods
  }

  **
  ** Format a compiler TypeDef for hover display
  **
  private Str formatTypeDef(TypeDef td)
  {
    buf := StrBuf()
    buf.add("```fantom\n")

    // Modifiers
    if (td.isAbstract) buf.add("abstract ")
    if (td.isConst) buf.add("const ")
    if (td.isMixin) buf.add("mixin ")
    else if (td.isEnum) buf.add("enum ")
    else buf.add("class ")

    buf.add(td.name)

    // Base type
    if (td.base != null && td.base.name != "Obj")
      buf.add(" : ${td.base.name}")

    buf.add("\n```")

    // Add field/method counts
    buf.add("\n\n")
    buf.add("${td.methodDefs.size} methods, ${td.fieldDefs.size} fields")

    return buf.toStr
  }

  **
  ** Format a compiler MethodDef for hover display
  **
  private Str formatMethodDef(MethodDef m, TypeDef td)
  {
    buf := StrBuf()
    buf.add("```fantom\n")

    // Modifiers
    if (m.isStatic) buf.add("static ")
    if (m.isAbstract) buf.add("abstract ")
    if (m.isVirtual) buf.add("virtual ")
    if (m.isOverride) buf.add("override ")

    // Return type and name
    buf.add("${m.ret.name} ")
    buf.add("${td.name}.${m.name}(")

    // Parameters
    for (i := 0; i < m.params.size; i++)
    {
      if (i > 0) buf.add(", ")
      p := m.params[i]
      buf.add("${p.paramType.name} ${p.name}")
    }
    buf.add(")")

    buf.add("\n```")
    return buf.toStr
  }

  **
  ** Format a compiler FieldDef for hover display
  **
  private Str formatFieldDef(FieldDef f, TypeDef td)
  {
    buf := StrBuf()
    buf.add("```fantom\n")

    if (f.isStatic) buf.add("static ")
    if (f.isConst) buf.add("const ")

    buf.add("${f.fieldType.name} ")
    buf.add("${td.name}.${f.name}")

    buf.add("\n```")
    return buf.toStr
  }

  **
  ** Format a reflected Type for hover display
  **
  private Str formatReflectedType(Type type)
  {
    buf := StrBuf()
    buf.add("```fantom\n")

    if (type.isAbstract) buf.add("abstract ")
    if (type.isConst) buf.add("const ")
    if (type.isMixin) buf.add("mixin ")
    else if (type.isEnum) buf.add("enum ")
    else buf.add("class ")

    buf.add("${type.pod.name}::${type.name}")

    if (type.base != null && type.base.name != "Obj")
      buf.add(" : ${type.base.name}")

    buf.add("\n```")

    // Doc
    doc := type.doc
    if (doc != null && doc.size > 0)
    {
      // Show first line of documentation
      firstLine := doc.splitLines.first
      if (firstLine != null && firstLine.size > 0)
        buf.add("\n\n$firstLine")
    }

    return buf.toStr
  }

  **
  ** Format a reflected Slot (Method or Field) for hover display
  **
  private Str formatReflectedSlot(Slot slot)
  {
    buf := StrBuf()
    buf.add("```fantom\n")

    if (slot is Method)
    {
      m := (Method)slot
      if (m.isStatic) buf.add("static ")
      if (m.isAbstract) buf.add("abstract ")
      if (m.isVirtual) buf.add("virtual ")

      buf.add("${m.returns.name} ${m.parent.name}.${m.name}(")

      params := m.params
      for (i := 0; i < params.size; i++)
      {
        if (i > 0) buf.add(", ")
        p := params[i]
        buf.add("${p.type.name} ${p.name}")
      }
      buf.add(")")
    }
    else if (slot is Field)
    {
      f := (Field)slot
      if (f.isStatic) buf.add("static ")
      if (f.isConst) buf.add("const ")
      buf.add("${f.type.name} ${f.parent.name}.${f.name}")
    }

    buf.add("\n```")

    // Doc
    doc := slot.doc
    if (doc != null && doc.size > 0)
    {
      firstLine := doc.splitLines.first
      if (firstLine != null && firstLine.size > 0)
        buf.add("\n\n$firstLine")
    }

    return buf.toStr
  }

  **
  ** Create an LSP Hover response with markdown content
  **
  private [Str:Obj?] createHover(Str content, LspPosition pos, Str word, Str line)
  {
    // Calculate the range covering the full symbol
    col := findWordStart(line, pos.character)
    endCol := col + word.size

    return [
      "contents": [
        "kind": "markdown",
        "value": content
      ],
      "range": [
        "start": ["line": pos.line, "character": col],
        "end": ["line": pos.line, "character": endCol]
      ]
    ]
  }

  **
  ** Find the start column of a word at the given position
  **
  private Int findWordStart(Str line, Int pos)
  {
    start := pos
    while (start > 0 && LspUtil.isIdentifierChar(line[start - 1]))
      start--
    return start
  }
}
