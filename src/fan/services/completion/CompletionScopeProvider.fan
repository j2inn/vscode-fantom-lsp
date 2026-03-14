
**
** CompletionScopeProvider - Non-member identifier completion for symbols
** visible at cursor position (params, locals, closure params, fields).
**
class CompletionScopeProvider
{
  **
  ** Complete identifiers visible at the cursor.
  ** Lightweight text scan up to cursor position to avoid mutating ProjectIndex.
  **
  CompletionItem[] complete(LspPosition pos, Str source, ProjectIndex index, Str prefix)
  {
    lines := source.splitLines
    if (lines.isEmpty) return CompletionItem[,]

    lastLine := pos.line < lines.size ? pos.line : lines.size - 1
    prefixLower := prefix.lower

    fieldItems := Str:CompletionItem[:]
    methodItems := Str:CompletionItem[:]

    currentType := null as Str
    currentMethod := null as Str
    braceDepth := 0
    typeBraceDepth := -1
    methodBraceDepth := -1
    currentMethodStartLine := -1
    currentTypeStartLine := -1
    methodBodyStarted := false
    methodHeader := ""
    inBlockComment := false

    for (i := 0; i <= lastLine; i++)
    {
      rawLine := lines[i]
      line := rawLine
      if (i == lastLine && pos.character < rawLine.size)
        line = rawLine[0..<pos.character]

      trimmed := line.trim
      braceInfo := scanBraces(line, inBlockComment)
      lineOpenBraces := braceInfo[0]
      lineCloseBraces := braceInfo[1]
      inBlockComment = braceInfo[2] == 1

      // Enter type scope
      typeMatch := matchTypeDeclForScope(trimmed)
      if (typeMatch != null && currentType == null)
      {
        currentType = typeMatch
        currentTypeStartLine = i
        typeBraceDepth = braceDepth
        currentMethod = null
        methodBraceDepth = -1
        currentMethodStartLine = -1
        methodBodyStarted = false
        methodHeader = ""
        methodItems.clear
      }

      // Type-level members (methods + fields)
      if (currentType != null && braceDepth == typeBraceDepth + 1)
      {
        methodMatch := currentMethod == null ? matchMethodDeclForScope(trimmed) : null
        if (methodMatch != null)
        {
          currentMethod = methodMatch
          currentMethodStartLine = i
          methodBraceDepth = braceDepth
          methodBodyStarted = false
          methodHeader = line.trim
          methodItems.clear
        }

        // Collect/parse parameters while scanning method header lines.
        if (currentMethod != null && !methodBodyStarted)
        {
          if (i > currentMethodStartLine && !trimmed.isEmpty)
            methodHeader = methodHeader.isEmpty ? trimmed : methodHeader + " " + trimmed

          if (!methodHeader.isEmpty && methodHeader.contains("(") && methodHeader.contains(")"))
          {
            params := parseMethodParamsForScope(methodHeader)
            params.each |paramType, paramName|
            {
              detail := paramType != null ? "${paramType} ${paramName}" : paramName
              addScopeItem(methodItems, prefixLower, paramName, CompletionItemKind.variable, detail)
            }
          }

          // Abstract/interface methods (no body) end with ';'.
          if (trimmed.endsWith(";") && lineOpenBraces == 0)
          {
            currentMethod = null
            methodBraceDepth = -1
            currentMethodStartLine = -1
            methodBodyStarted = false
            methodHeader = ""
            methodItems.clear
          }
        }

        if (currentMethod == null)
        {
          fieldName := matchFieldDeclForScope(trimmed)
          if (fieldName != null)
          {
            fieldType := TypeResolver.extractDeclaredType(trimmed, fieldName)
            detail := fieldType != null ? "${fieldType} ${fieldName}" : fieldName
            addScopeItem(fieldItems, prefixLower, fieldName, CompletionItemKind.field, detail)
          }
        }
      }

      // Method-level members (locals + closure params)
      if (currentMethod != null && methodBodyStarted && braceDepth > methodBraceDepth)
      {
        localName := matchLocalVarDeclForScope(trimmed)
        if (localName != null)
        {
          localType := TypeResolver.extractDeclaredType(trimmed, localName)
          if (localType == null) localType = TypeResolver.inferTypeFromAssignment(trimmed, localName, source, i, index)
          detail := localType != null ? "${localType} ${localName}" : localName
          addScopeItem(methodItems, prefixLower, localName, CompletionItemKind.variable, detail)
        }

        closureParams := matchClosureParamsForScope(line)
        closureParams.each |paramName|
        {
          addScopeItem(methodItems, prefixLower, paramName, CompletionItemKind.variable, paramName)
        }
      }

      // Update brace depth after processing declarations on this line
      braceDepth = braceDepth + lineOpenBraces - lineCloseBraces

      // Method body starts when we see the opening '{' for current method.
      if (currentMethod != null && !methodBodyStarted && lineOpenBraces > 0)
        methodBodyStarted = true

      // Exit method scope
      sameLineBalancedMethod := (i == currentMethodStartLine && lineOpenBraces > 0 && lineOpenBraces == lineCloseBraces)
      if (currentMethod != null && methodBodyStarted && braceDepth <= methodBraceDepth &&
          (i > currentMethodStartLine || sameLineBalancedMethod))
      {
        currentMethod = null
        methodBraceDepth = -1
        currentMethodStartLine = -1
        methodBodyStarted = false
        methodHeader = ""
        methodItems.clear
      }

      // Exit type scope
      sameLineBalancedType := (i == currentTypeStartLine && lineOpenBraces > 0 && lineOpenBraces == lineCloseBraces)
      if (currentType != null && braceDepth <= typeBraceDepth &&
          (i > currentTypeStartLine || sameLineBalancedType))
      {
        currentType = null
        typeBraceDepth = -1
        currentTypeStartLine = -1
        currentMethod = null
        methodBraceDepth = -1
        currentMethodStartLine = -1
        methodBodyStarted = false
        methodHeader = ""
        methodItems.clear
      }
    }

    methodOnly := CompletionItem[,]
    if (currentMethod != null)
      methodItems.each |item, name| { methodOnly.add(item) }

    fieldOnly := CompletionItem[,]
    fieldItems.each |item, name| { fieldOnly.add(item) }

    // Local/method scope should outrank type fields when names overlap.
    items := mergeByLabel(methodOnly, fieldOnly)

    // Augment strict text-scope results with AST-derived scope symbols.
    // This covers parser edge-cases while typing unsaved code.
    astItems := completeFromAst(pos, source, prefixLower)
    if (!astItems.isEmpty)
      items = mergeByLabel(items, astItems)

    // Defensive fallback: if strict+AST yields nothing, run a looser pass
    // scoped to the active method only (never pull tokens from other methods).
    if (items.isEmpty && !prefixLower.isEmpty)
      return completeLooseFallback(pos, source, index, prefixLower, currentMethodStartLine)

    return items
  }

  **
  ** Loose fallback completion when strict scope parsing fails.
  ** Scans nearby lines for method params, locals, closure params, and fields.
  **
  private CompletionItem[] completeLooseFallback(LspPosition pos, Str source, ProjectIndex index, Str prefixLower,
                                                 Int methodStartLine)
  {
    // Never fall back to global scan; completion must stay in active scope.
    if (methodStartLine < 0) return CompletionItem[,]

    lines := source.splitLines
    if (lines.isEmpty) return CompletionItem[,]

    lastLine := pos.line < lines.size ? pos.line : lines.size - 1
    startLine := methodStartLine

    fallbackMap := Str:CompletionItem[:]
    pendingMethodHeader := ""
    methodBodyStarted := false
    inBlockComment := false

    for (i := startLine; i <= lastLine; i++)
    {
      rawLine := lines[i]
      line := rawLine
      if (i == lastLine && pos.character < rawLine.size)
        line = rawLine[0..<pos.character]

      trimmed := line.trim
      if (trimmed.isEmpty || trimmed.startsWith("//") || trimmed.startsWith("**")) continue

      // Method header accumulation to parse parameters robustly.
      if (pendingMethodHeader.isEmpty)
      {
        if (i == startLine && matchMethodDeclForScope(trimmed) != null)
          pendingMethodHeader = line.trim
      }
      else if (!methodBodyStarted)
      {
        pendingMethodHeader = pendingMethodHeader + " " + trimmed
      }

      if (!pendingMethodHeader.isEmpty &&
          pendingMethodHeader.contains("(") && pendingMethodHeader.contains(")"))
      {
        params := parseMethodParamsForScope(pendingMethodHeader)
        params.each |paramType, paramName|
        {
          detail := paramType != null ? "${paramType} ${paramName}" : paramName
          addScopeItem(fallbackMap, prefixLower, paramName, CompletionItemKind.variable, detail)
        }
        pendingMethodHeader = ""
      }

      braceInfo := scanBraces(line, inBlockComment)
      inBlockComment = braceInfo[2] == 1
      if (!methodBodyStarted && braceInfo[0] > 0)
        methodBodyStarted = true

      if (!methodBodyStarted) continue

      localName := matchLocalVarDeclForScope(trimmed)
      if (localName != null)
      {
        localType := TypeResolver.extractDeclaredType(trimmed, localName)
        if (localType == null) localType = TypeResolver.inferTypeFromAssignment(trimmed, localName, source, i, index)
        detail := localType != null ? "${localType} ${localName}" : localName
        addScopeItem(fallbackMap, prefixLower, localName, CompletionItemKind.variable, detail)
      }

      closureParams := matchClosureParamsForScope(line)
      closureParams.each |paramName|
      {
        addScopeItem(fallbackMap, prefixLower, paramName, CompletionItemKind.variable, paramName)
      }

      fieldName := matchFieldDeclForScope(trimmed)
      if (fieldName != null)
      {
        fieldType := TypeResolver.extractDeclaredType(trimmed, fieldName)
        detail := fieldType != null ? "${fieldType} ${fieldName}" : fieldName
        addScopeItem(fallbackMap, prefixLower, fieldName, CompletionItemKind.field, detail)
      }
    }

    result := CompletionItem[,]
    fallbackMap.each |item, name| { result.add(item) }
    return result
  }

  **
  ** AST-based in-scope completion from the current source snapshot.
  ** Uses nearest enclosing type/method and includes params + locals.
  **
  private CompletionItem[] completeFromAst(LspPosition pos, Str source, Str prefixLower)
  {
    lines := source.splitLines
    ast := AstIndex.parse("file:///completion-scope.fan", source)
    if (ast == null || ast.types.isEmpty) return CompletionItem[,]

    astType := null as AstType
    ast.types.each |t|
    {
      if (t.line <= pos.line && (astType == null || t.line > astType.line))
        astType = t
    }
    if (astType == null) return CompletionItem[,]

    resultMap := Str:CompletionItem[:]

    // Fields in current type
    astType.fields.each |f|
    {
      detail := f.typeName != null ? "${f.typeName} ${f.name}" : f.name
      addScopeItem(resultMap, prefixLower, f.name, CompletionItemKind.field, detail)
    }

    // Nearest enclosing method by declaration line
    astMethod := null as AstSlot
    astType.methods.each |m|
    {
      if (m.line <= pos.line && (astMethod == null || m.line > astMethod.line))
        astMethod = m
    }

    if (astMethod != null && isCursorInsideMethod(lines, astMethod.line, pos.line))
    {
      astMethod.params.each |p|
      {
        detail := p.typeName != null ? "${p.typeName} ${p.name}" : p.name
        addScopeItem(resultMap, prefixLower, p.name, CompletionItemKind.variable, detail)
      }

      astMethod.localVars.each |lv|
      {
        // Prefer vars declared before cursor line.
        if (lv.line > pos.line) return
        detail := lv.typeName != null ? "${lv.typeName} ${lv.name}" : lv.name
        addScopeItem(resultMap, prefixLower, lv.name, CompletionItemKind.variable, detail)
      }
    }

    out := CompletionItem[,]
    resultMap.each |item, name| { out.add(item) }
    return out
  }

  ** True if cursor line is inside the method body declared at methodDeclLine.
  private Bool isCursorInsideMethod(Str[] lines, Int methodDeclLine, Int cursorLine)
  {
    if (methodDeclLine < 0 || methodDeclLine >= lines.size) return false
    if (cursorLine < methodDeclLine) return false

    braceDepth := 0
    methodBodyStarted := false
    inBlockComment := false

    for (i := methodDeclLine; i < lines.size; i++)
    {
      line := lines[i]
      braceInfo := scanBraces(line, inBlockComment)
      openBraces := braceInfo[0]
      closeBraces := braceInfo[1]
      inBlockComment = braceInfo[2] == 1

      if (!methodBodyStarted && openBraces > 0)
        methodBodyStarted = true

      braceDepth = braceDepth + openBraces - closeBraces

      if (methodBodyStarted && braceDepth <= 0)
        return cursorLine <= i
    }

    return methodBodyStarted
  }

  ** Count braces while ignoring strings, chars, and comments.
  private Int[] scanBraces(Str line, Bool inBlockComment)
  {
    open := 0
    close := 0
    inStr := false
    inChar := false
    inBacktick := false
    escaped := false

    trimmed := line.trim
    if (!inBlockComment && (trimmed.startsWith("//") || trimmed.startsWith("**") || trimmed.startsWith("*")))
      return [0, 0, inBlockComment ? 1 : 0]

    for (i := 0; i < line.size; i++)
    {
      ch := line[i]
      next := i + 1 < line.size ? line[i + 1] : 0

      if (inBlockComment)
      {
        if (ch == '*' && next == '/')
        {
          inBlockComment = false
          i++
        }
        continue
      }

      if (inStr)
      {
        if (escaped) { escaped = false; continue }
        if (ch == '\\') { escaped = true; continue }
        if (ch == '"') { inStr = false; continue }
        continue
      }

      if (inChar)
      {
        if (escaped) { escaped = false; continue }
        if (ch == '\\') { escaped = true; continue }
        if (ch == '\'') { inChar = false; continue }
        continue
      }

      if (inBacktick)
      {
        if (ch == '`') { inBacktick = false }
        continue
      }

      if (ch == '/' && next == '/')
        break
      if (ch == '/' && next == '*')
      {
        inBlockComment = true
        i++
        continue
      }

      if (ch == '"') { inStr = true; continue }
      if (ch == '\'') { inChar = true; continue }
      if (ch == '`') { inBacktick = true; continue }

      if (ch == '{') open++
      else if (ch == '}') close++
    }

    return [open, close, inBlockComment ? 1 : 0]
  }

  ** Merge completion lists by label, preserving first-list priority. */
  private CompletionItem[] mergeByLabel(CompletionItem[] first, CompletionItem[] second)
  {
    merged := CompletionItem[,]
    seen := Str:Bool[:]

    first.each |item|
    {
      if (seen.containsKey(item.label)) return
      seen[item.label] = true
      merged.add(item)
    }

    second.each |item|
    {
      if (seen.containsKey(item.label)) return
      seen[item.label] = true
      merged.add(item)
    }

    return merged
  }

  **
  ** Add an identifier completion if it matches prefix; latest declaration wins.
  **
  private Void addScopeItem(Str:CompletionItem scopeItems, Str prefixLower,
                            Str name, Int kind, Str? detail := null)
  {
    if (name.isEmpty) return
    if (!prefixLower.isEmpty && !name.lower.startsWith(prefixLower)) return
    scopeItems[name] = CompletionItem(name, kind, detail, null, null, null, "000_${name}")
  }

  ** Match a type declaration: class Foo, mixin Foo, enum class Foo
  private Str? matchTypeDeclForScope(Str trimmed)
  {
    if (trimmed.startsWith("//") || trimmed.startsWith("**") || trimmed.startsWith("*"))
      return null

    keywords := ["class ", "mixin "]
    for (i := 0; i < keywords.size; i++)
    {
      idx := trimmed.index(keywords[i])
      if (idx == null) continue

      afterKeyword := trimmed[idx + keywords[i].size..-1].trim
      name := extractIdentifierForScope(afterKeyword)
      if (name != null && name.size > 0 && name[0].isUpper)
        return name
    }
    return null
  }

  ** Match a method declaration line
  private Str? matchMethodDeclForScope(Str trimmed)
  {
    if (trimmed.startsWith("//") || trimmed.startsWith("@") || trimmed.startsWith("*") ||
        trimmed.startsWith("{") || trimmed.startsWith("}"))
      return null

    parenIdx := trimmed.index("(")
    if (parenIdx == null || parenIdx == 0) return null

    beforeParen := trimmed[0..<parenIdx].trim
    lastSpace := beforeParen.indexr(" ")
    if (lastSpace == null) return null

    methodName := beforeParen[lastSpace + 1..-1]
    if (!isIdentifierForScope(methodName)) return null

    beforeName := beforeParen[0..<lastSpace].trim
    if (beforeName.isEmpty) return null
    lastChar := beforeName[-1]
    if (!lastChar.isAlpha && lastChar != '?' && lastChar != ']') return null

    return methodName
  }

  ** Match a field declaration line inside a type scope
  private Str? matchFieldDeclForScope(Str trimmed)
  {
    if (trimmed.startsWith("//") || trimmed.startsWith("@") || trimmed.startsWith("*") ||
        trimmed.startsWith("{") || trimmed.startsWith("}") || trimmed.startsWith("return ") ||
        trimmed.startsWith("if ") || trimmed.startsWith("for ") ||
        trimmed.startsWith("while ") || trimmed.startsWith("throw "))
      return null

    declPart := trimmed
    walrusIdx := trimmed.index(":=")
    if (walrusIdx != null)
      declPart = trimmed[0..<walrusIdx]
    if (declPart.contains("(")) return null

    parts := splitWordsForScope(declPart)
    if (parts.size < 2) return null

    for (i := parts.size - 1; i >= 1; i--)
    {
      name := parts[i]
      typePart := parts[i - 1]
      if (name.endsWith(":=")) name = name[0..<name.size - 2]

      cleanType := typePart.endsWith("?") ? typePart[0..<typePart.size - 1] : typePart
      if (cleanType.size > 0 && (cleanType[0].isUpper || cleanType[0] == '[') &&
          name.size > 0 && isIdentifierForScope(name))
        return name
    }

    return null
  }

  ** Match a local variable declaration: name := ...
  private Str? matchLocalVarDeclForScope(Str trimmed)
  {
    if (trimmed.startsWith("//") || trimmed.startsWith("*")) return null

    walrusIdx := trimmed.index(":=")
    if (walrusIdx == null || walrusIdx == 0) return null

    beforeWalrus := trimmed[0..<walrusIdx].trim
    parts := splitWordsForScope(beforeWalrus)
    if (parts.isEmpty) return null

    name := parts[-1]
    if (!isIdentifierForScope(name) || name.isEmpty) return null
    if (beforeWalrus.contains(".")) return null

    return name
  }

  ** Parse method parameters from a declaration line.
  ** Returns paramName -> paramType (nullable when unknown).
  private Str:Str? parseMethodParamsForScope(Str line)
  {
    result := Str:Str?[:]

    parenOpen := line.index("(")
    if (parenOpen == null) return result
    parenClose := line.index(")", parenOpen)
    if (parenClose == null) return result

    paramStr := line[parenOpen + 1 ..< parenClose].trim
    if (paramStr.isEmpty) return result

    paramStr.split(',').each |part|
    {
      p := part.trim
      if (p.isEmpty) return

      eqIdx := p.index(":=")
      decl := eqIdx != null ? p[0..<eqIdx].trim : p

      words := splitWordsForScope(decl)
      if (words.isEmpty) return

      paramName := words[-1]
      if (!isIdentifierForScope(paramName)) return

      paramType := words.size >= 2 ? words[-2] : null
      if (paramType != null && paramType.endsWith("?"))
        paramType = paramType[0..<paramType.size - 1]

      result[paramName] = paramType
    }

    return result
  }

  ** Match closure params from |param| or |Type param, Type2 param2| syntax.
  private Str[] matchClosureParamsForScope(Str line)
  {
    result := Str[,]
    pos := 0

    while (pos < line.size)
    {
      pipeStart := line.index("|", pos)
      if (pipeStart == null) break

      // Skip ||
      if (pipeStart + 1 < line.size && line[pipeStart + 1] == '|')
      {
        pos = pipeStart + 2
        continue
      }

      pipeEnd := line.index("|", pipeStart + 1)
      if (pipeEnd == null) break
      if (pipeEnd == pipeStart + 1)
      {
        pos = pipeEnd + 1
        continue
      }

      inner := line[pipeStart + 1 ..< pipeEnd].trim
      if (!inner.isEmpty)
      {
        inner.split(',').each |part|
        {
          p := part.trim
          if (p.isEmpty) return

          arrowIdx := p.index("->")
          if (arrowIdx != null) p = p[0..<arrowIdx].trim

          words := splitWordsForScope(p)
          if (words.isEmpty) return

          name := words.size == 1 ? words[0] : words[-1]
          if (name != "it" && isIdentifierForScope(name))
            result.add(name)
        }
      }

      pos = pipeEnd + 1
    }

    return result
  }

  private Str[] splitWordsForScope(Str text)
  {
    return text.replace("\t", " ").split(' ').findAll |w| { !w.isEmpty }
  }

  private Str? extractIdentifierForScope(Str text)
  {
    if (text.isEmpty) return null
    end := 0
    while (end < text.size && (text[end].isAlphaNum || text[end] == '_')) end++
    return end > 0 ? text[0..<end] : null
  }

  private Bool isIdentifierForScope(Str name)
  {
    if (name.isEmpty) return false
    first := name[0]
    if (!first.isAlpha && first != '_') return false
    for (i := 1; i < name.size; i++)
    {
      ch := name[i]
      if (!ch.isAlphaNum && ch != '_') return false
    }
    return true
  }

}
