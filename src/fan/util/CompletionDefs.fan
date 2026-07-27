
using concurrent

**
** CompletionDefs - Loads autocompletion definitions from the YML resource file.
** Provides type alias mappings and per-type completion items.
**
const class CompletionDefs
{
  ** Singleton instance, loaded once from pod resource
  static const CompletionDefs cur := load

  ** Type aliases: simple name -> qualified name (e.g. "Str" -> "sys::Str")
  const Str:Str typeAliases

  ** Per-type completion items wrapped in Unsafe (CompletionItem is not const)
  private const Unsafe typeCompletionsRef

  private new make(Str:Str aliases, Str:Obj completions)
  {
    this.typeAliases = aliases
    this.typeCompletionsRef = Unsafe(completions)
  }

  **
  ** Get completion items for a qualified type name.
  ** Returns null if the type is not defined in the YML.
  **
  CompletionItem[]? itemsFor(Str qualifiedName)
  {
    completions := (Str:Obj)typeCompletionsRef.val
    raw := completions[qualifiedName]
    if (raw == null) return null
    return raw as CompletionItem[]
  }

  **
  ** Resolve a simple type name to its qualified form.
  ** Returns null if not a known alias.
  **
  Str? resolveAlias(Str simpleName) { typeAliases[simpleName] }

  **
  ** Check if a simple type name is a known alias.
  **
  Bool hasAlias(Str simpleName) { typeAliases.containsKey(simpleName) }

  **
  ** Return all qualified type names that have completion entries in the YML
  ** (e.g. ["sys::List", "sys::Map", "sys::Str", ...]).
  **
  Str[] allQualifiedTypeNames()
  {
    completions := (Str:Obj)typeCompletionsRef.val
    return completions.keys
  }

  **
  ** Parse the return type from a YML detail string.
  ** Detail strings have the form: "RetType methodName(...)" where RetType
  ** precedes the method name.  Generic placeholders (V, K, Obj, Obj?, This)
  ** are normalised to concrete collection types when they appear in a known
  ** collection context (e.g. "V[]" → "sys::List", "Obj:V[]" → "sys::Map").
  ** Returns null when the detail string carries no useful type information.
  **
  static Str? returnTypeFrom(Str? detail)
  {
    if (detail == null || detail.isEmpty) return null

    // Find the return-type prefix: everything before the first '('
    parenIdx := detail.index("(")
    if (parenIdx == null || parenIdx == 0) return null

    // The method name is the last identifier before '(' — strip it
    beforeParen := detail[0 ..< parenIdx].trim
    lastSpace := beforeParen.indexr(" ")
    retStr := lastSpace != null ? beforeParen[0 ..< lastSpace].trim : null
    if (retStr == null || retStr.isEmpty) return null

    // Strip nullable marker for classification
    bare := retStr.endsWith("?") ? retStr[0 ..< retStr.size - 1] : retStr

    // Map/List sugar: "Obj:V[]", "K:V", "[K:V]" → Map
    if (bare.contains(":") && !bare.startsWith("//"))
      return "sys::Map"

    // List sugar: "V[]", "K[]", "Obj[]", "Str[]", etc.
    // "V[]", "Str[]", etc. — any array type is a List
    if (bare.endsWith("[]")) return "sys::List"

    // Generic placeholders that convey no concrete type
    if (bare == "V" || bare == "K" || bare == "Obj" ||
        bare == "This" || bare == "Void" || bare.isEmpty)
      return null

    // Try alias resolution (e.g. "Str" → "sys::Str", "List" → "sys::List")
    resolved := CompletionDefs.cur.resolveAlias(bare)
    if (resolved != null) return resolved

    // Return the bare name as-is if it looks like a type (starts with upper)
    if (bare.size > 0 && bare[0].isUpper) return bare

    return null
  }

  **
  ** Parse parameter names from a YML detail string, in declaration order.
  ** Detail strings have the form: "RetType methodName(param1, param2, ...)".
  ** Returns an empty list when the detail string has no parameters or can't
  ** be parsed.
  **
  static Str[] paramNamesFrom(Str? detail)
  {
    if (detail == null || detail.isEmpty) return Str[,]

    parenIdx := detail.index("(")
    if (parenIdx == null) return Str[,]
    parenClose := detail.indexr(")")
    if (parenClose == null || parenClose <= parenIdx) return Str[,]

    paramListStr := detail[parenIdx + 1 ..< parenClose]
    return ParamListParser.paramNames(paramListStr)
  }

  // ---- Loading ----

  private static CompletionDefs load()
  {
    try
    {
      text := CompletionDefs#.pod.file(`/src/res/completions.yml`).readAllStr
      return parse(text)
    }
    catch (Err e)
    {
      // Fallback: empty definitions
      return CompletionDefs(Str:Str[:], Str:Obj[:])
    }
  }

  **
  ** Parse the YML text into CompletionDefs.
  ** Handles our specific YML format with type_aliases and per-type sections.
  **
  private static CompletionDefs parse(Str text)
  {
    aliases := Str:Str[:]
    completions := Str:Obj[:]

    lines := text.splitLines
    i := 0
    while (i < lines.size)
    {
      line := lines[i]
      trimmed := line.trim

      // Skip empty lines and comments
      if (trimmed.isEmpty || trimmed.startsWith("#"))
      {
        i++
        continue
      }

      // Top-level key (no indentation)
      if (!line[0].isSpace)
      {
        key := trimmed.endsWith(":") ? trimmed[0..<trimmed.size-1] : trimmed
        i++

        if (key == "type_aliases")
        {
          // Parse key:value pairs at indent level 2
          while (i < lines.size)
          {
            aline := lines[i]
            if (aline.trim.isEmpty || aline.trim.startsWith("#")) { i++; continue }
            if (!aline[0].isSpace) break
            indent := countIndent(aline)
            if (indent == 2)
            {
              parts := aline.trim
              colonIdx := parts.index(":")
              if (colonIdx != null)
              {
                aKey := parts[0..<colonIdx].trim
                aVal := parts[colonIdx+1..-1].trim
                aliases[aKey] = aVal
              }
            }
            i++
          }
        }
        else if (key.contains("::"))
        {
          // Type definition section (e.g. "sys::List:")
          typeName := key.endsWith(":") ? key[0..<key.size-1] : key
          items := parseTypeSection(lines, i)
          completions[typeName] = items
          // Skip past this section
          while (i < lines.size)
          {
            nline := lines[i]
            if (nline.trim.isEmpty || nline.trim.startsWith("#")) { i++; continue }
            if (!nline[0].isSpace) break
            i++
          }
        }
        else
        {
          // Unknown top-level key, skip its block
          while (i < lines.size)
          {
            nline := lines[i]
            if (nline.trim.isEmpty || nline.trim.startsWith("#")) { i++; continue }
            if (!nline[0].isSpace) break
            i++
          }
        }
      }
      else
      {
        i++
      }
    }

    return CompletionDefs(aliases.toImmutable, completions)
  }

  **
  ** Parse a type section (methods: and fields: blocks) into CompletionItems.
  **
  private static CompletionItem[] parseTypeSection(Str[] lines, Int startIdx)
  {
    items := CompletionItem[,]
    i := startIdx
    currentBlock := "" // "methods" or "fields"

    while (i < lines.size)
    {
      line := lines[i]
      trimmed := line.trim
      if (trimmed.isEmpty || trimmed.startsWith("#")) { i++; continue }

      // Non-indented line means end of type section
      if (!line[0].isSpace) break

      indent := countIndent(line)

      // Indent 2: methods: or fields:
      if (indent == 2)
      {
        key := trimmed.endsWith(":") ? trimmed[0..<trimmed.size-1] : trimmed
        if (key == "methods" || key == "fields")
          currentBlock = key
      }
      // Indent 4: member name
      else if (indent == 4 && !currentBlock.isEmpty)
      {
        memberName := trimmed.endsWith(":") ? trimmed[0..<trimmed.size-1] : trimmed
        detail := null as Str
        snippet := null as Str
        kind := currentBlock == "methods"
          ? CompletionItemKind.method : CompletionItemKind.field

        // Read properties at indent 6
        j := i + 1
        while (j < lines.size)
        {
          pline := lines[j]
          ptrimmed := pline.trim
          if (ptrimmed.isEmpty || ptrimmed.startsWith("#")) { j++; continue }
          pindent := countIndent(pline)
          if (pindent < 6) break
          if (pindent == 6)
          {
            colonIdx := ptrimmed.index(":")
            if (colonIdx != null)
            {
              pkey := ptrimmed[0..<colonIdx].trim
              pval := ptrimmed[colonIdx+1..-1].trim
              if (pkey == "detail") detail = pval
              else if (pkey == "snippet") snippet = pval.replace("\\n", "\n").replace("\\t", "\t")
            }
          }
          j++
        }
        i = j

        if (snippet != null)
        {
          items.add(CompletionItem(
            memberName, kind, detail, null, snippet, 2
          ))
        }
        else
        {
          items.add(CompletionItem(memberName, kind, detail))
        }
        continue
      }

      i++
    }

    return items
  }

  **
  ** Count leading spaces in a line.
  **
  private static Int countIndent(Str line)
  {
    count := 0
    while (count < line.size && line[count] == ' ') count++
    return count
  }
}
