**
** ReferencesScanner - Scans source text for usage sites of a resolved target.
**
** Precision tiers (from ReferencesTarget design doc):
**   Tier 1 – exact:   static calls (TypeName.member), bare calls inside owning class
**   Tier 2 – typed:   receiver declared with explicit type or via ctor inference
**   Excluded:         unresolvable receivers (method return values, closures, etc.)
**
class ReferencesScanner
{
  ** Scan one source file for references matching the given target.
  ** Returns a (possibly empty) list of LSP Location maps.
  **
  ** Scan one source file for references matching the given target.
  ** Pass a ProjectIndex so that local-variable scoping can use the AST-derived
  ** method bounds instead of heuristic text detection.
  ** Scan one source file for references matching the given target.
  ** Pass a ProjectIndex so that receiver-type and method-bounds lookups use
  ** AST-derived index data instead of heuristic text detection.
  [Str:Obj?][] scan(Str fileUri, Str source, ReferencesTarget target,
                    ProjectIndex? index := null)
  {
    lines := source.splitLines
    switch (target.kind)
    {
      case "type":   return scanType(fileUri, lines, target.name)
      case "member": return scanMember(fileUri, lines, target, index)
      case "local":  return scanLocal(fileUri, lines, target, index)
      default:       return [Str:Obj?][,]
    }
  }

  // ---------------------------------------------------------------------------
  // Type references
  // ---------------------------------------------------------------------------

  private [Str:Obj?][] scanType(Str fileUri, Str[] lines, Str name)
  {
    results := [Str:Obj?][,]
    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      if (!line.contains(name)) continue
      col := findWordInLine(line, name, 0)
      while (col != null)
      {
        if (!isInStringOrComment(line, col))
          results.add(loc(fileUri, i, col, name.size))
        col = findWordInLine(line, name, col + 1)
      }
    }
    return results
  }

  // ---------------------------------------------------------------------------
  // Member references (method / field)
  // ---------------------------------------------------------------------------

  private [Str:Obj?][] scanMember(Str fileUri, Str[] lines, ReferencesTarget target,
                                  ProjectIndex? index)
  {
    results  := [Str:Obj?][,]
    name     := target.name
    family   := target.typeFamily
    // Receiver-type map: prefer AST-indexed symbols; fall back to text heuristic
    // only when no index is available (e.g. in isolated unit tests).
    varTypes := index != null ? index.getVarTypesForFile(fileUri) : resolveVarTypes(lines)

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      if (!line.contains(name)) continue

      col := 0
      while (true)
      {
        found := findWordInLine(line, name, col)
        if (found == null) break
        col = found + 1

        if (isInStringOrComment(line, found)) continue

        // Enclosing class: prefer index lookup; fall back to text scan
        curClass := index != null
          ? (index.getEnclosingTypeAtLine(fileUri, i) ?: "")
          : enclosingClassFromText(lines, i)

        if (isAcceptedMemberUsage(line, found, name, curClass, family, varTypes))
          results.add(loc(fileUri, i, found, name.size))
      }
    }
    return results
  }

  private Bool isAcceptedMemberUsage(Str line, Int col, Str name,
                                     Str curClass, Str[] family,
                                     Str:Str varTypes)
  {
    // No type family constraint → include all uses
    if (family.isEmpty) return true

    // a) Static / enum call:  TypeName.member  (TypeName in family)
    if (col >= 2 && line[col - 1] == '.')
    {
      typeStart := col - 2
      while (typeStart > 0 && LspUtil.isIdentifierChar(line[typeStart - 1])) typeStart--
      receiver := line[typeStart ..< col - 1]
      if (receiver.size > 0 && receiver[0].isUpper)
        return family.contains(receiver)
    }

    // b) Bare call:  name(  or  name  inside class body — preceding char must not be '.'
    //    (checking only the immediate predecessor avoids false exclusions when a dot
    //     appears earlier on the same line, e.g. "TypeName.method(name, ...)")
    if ((col == 0 || !LspUtil.isIdentifierChar(line[col - 1])) && curClass != "")
    {
      if (col == 0 || line[col - 1] != '.')
        return family.contains(curClass)
    }

    // c) Instance access:  receiver.name  where receiver has a known type
    if (col >= 2 && line[col - 1] == '.')
    {
      varStart := col - 2
      while (varStart > 0 && LspUtil.isIdentifierChar(line[varStart - 1])) varStart--
      varName := line[varStart ..< col - 1]
      declType := varTypes[varName]
      if (declType != null) return family.contains(declType)
    }

    // Unknown receiver — exclude to avoid false positives
    return false
  }

  // ---------------------------------------------------------------------------
  // Local variable references (single-file, method-scoped)
  // ---------------------------------------------------------------------------

  private [Str:Obj?][] scanLocal(Str fileUri, Str[] lines, ReferencesTarget target,
                                 ProjectIndex? index)
  {
    if (target.localFileUri != fileUri) return [Str:Obj?][,]
    results := [Str:Obj?][,]
    name    := target.name

    // Use AST-derived method bounds when available — no heuristic text detection.
    // Falls back to scanning the whole file only if the index is absent.
    startLine := 0
    endLine   := lines.size - 1
    if (index != null)
    {
      bounds := index.getMethodBounds(fileUri, target.enclosingMethod)
      if (bounds != null) { startLine = bounds[0]; endLine = bounds[1] }
    }

    for (i := startLine; i <= endLine && i < lines.size; i++)
    {
      line := lines[i]
      if (!line.contains(name)) continue
      col := findWordInLine(line, name, 0)
      while (col != null)
      {
        if (!isInStringOrComment(line, col))
          results.add(loc(fileUri, i, col, name.size))
        col = findWordInLine(line, name, col + 1)
      }
    }
    return results
  }

  // ---------------------------------------------------------------------------
  // Receiver-type map  (lightweight, single pass)
  // ---------------------------------------------------------------------------

  **
  ** Build varName -> typeName for all type-annotated declarations in the file:
  **   TypeName varName := ...   (explicit type)
  **   varName := TypeName(...)  (constructor inference)
  **
  Str:Str resolveVarTypes(Str[] lines)
  {
    result := Str:Str[:]
    for (i := 0; i < lines.size; i++)
    {
      trimmed := lines[i].trim
      walrus := trimmed.index(":=")
      if (walrus == null) continue

      lhs := trimmed[0..<walrus].trim
      rhs := trimmed[walrus + 2 ..-1].trim

      // Explicit: "TypeName varName :="
      parts := lhs.split(' ').findAll |w| { !w.isEmpty }
      if (parts.size >= 2 && parts[-2][0].isUpper && parts[-1][0].isLower)
      {
        typePart := parts[-2]
        if (typePart.endsWith("?")) typePart = typePart[0..<typePart.size-1]
        result[parts[-1]] = typePart
        continue
      }

      // Ctor inference: "varName := TypeName(" or "varName := TypeName {"
      if (parts.size == 1 && parts[0][0].isLower && rhs.size > 0 && rhs[0].isUpper)
      {
        nameEnd := 0
        while (nameEnd < rhs.size && LspUtil.isIdentifierChar(rhs[nameEnd])) nameEnd++
        if (nameEnd < rhs.size && (rhs[nameEnd] == '(' || rhs[nameEnd] == ' ' || rhs[nameEnd] == '{'))
          result[parts[0]] = rhs[0..<nameEnd]
      }
    }
    return result
  }

  // ---------------------------------------------------------------------------
  // Implementations scan (called by ReferencesService)
  // ---------------------------------------------------------------------------

  **
  ** Scan source for class declarations that directly extend / implement targetType.
  ** Returns a list of LSP Location maps for the found class name tokens.
  **
  [Str:Obj?][] scanImplementations(Str fileUri, Str source, Str targetType)
  {
    results := [Str:Obj?][,]
    lines   := source.splitLines
    for (i := 0; i < lines.size; i++)
    {
      trimmed := lines[i].trim
      // Match:  class Foo : Bar   or   class Foo : Bar, Baz
      if (!trimmed.startsWith("class ") && !trimmed.startsWith("mixin ")) continue
      colonIdx := trimmed.index(" : ")
      if (colonIdx == null) continue
      bases := trimmed[colonIdx + 3 ..-1]
      bases.split(',').each |base|
      {
        b := base.trim.split(' ')[0]
        if (b == targetType)
        {
          // Point to the implementing class name, not the base
          kwEnd := trimmed.index(" ") ?: 0
          rest  := trimmed[kwEnd + 1 ..-1].trim
          nameEnd := 0
          while (nameEnd < rest.size && LspUtil.isIdentifierChar(rest[nameEnd])) nameEnd++
          clsName := rest[0..<nameEnd]
          col := lines[i].index(clsName) ?: 0
          results.add(loc(fileUri, i, col, clsName.size))
        }
      }
    }
    return results
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private [Str:Obj?] loc(Str uri, Int line, Int col, Int len)
  {
    return ["uri": uri, "range": [
      "start": ["line": line, "character": col],
      "end":   ["line": line, "character": col + len]
    ]]
  }

  ** Find the next occurrence of word (whole-identifier) in line starting at offset.
  private Int? findWordInLine(Str line, Str word, Int offset)
  {
    idx := offset
    while (true)
    {
      found := line.index(word, idx)
      if (found == null) return null
      endPos  := found + word.size
      beforeOk := found == 0 || !LspUtil.isIdentifierChar(line[found - 1])
      afterOk  := endPos >= line.size || !LspUtil.isIdentifierChar(line[endPos])
      if (beforeOk && afterOk) return found
      idx = found + 1
    }
    return null
  }

  ** Heuristic: is the character at col inside a string literal or line comment?
  private Bool isInStringOrComment(Str line, Int col)
  {
    inStr    := false
    escape   := false
    for (i := 0; i < col && i < line.size; i++)
    {
      ch := line[i]
      if (escape) { escape = false; continue }
      if (ch == '\\') { escape = true; continue }
      if (ch == '"') { inStr = !inStr; continue }
      if (!inStr && ch == '/' && i + 1 < line.size && line[i + 1] == '/')
        return true  // rest of line is a comment
    }
    return inStr
  }

  ** Fallback used only when no index is available (isolated unit tests).
  ** Scans backward from lineNum to find the nearest class/mixin declaration.
  private Str enclosingClassFromText(Str[] lines, Int lineNum)
  {
    for (i := lineNum; i >= 0; i--)
    {
      trimmed := lines[i].trim
      for (ki := 0; ki < 2; ki++)
      {
        kw  := ki == 0 ? "class " : "mixin "
        idx := trimmed.index(kw)
        if (idx == null) continue
        if (idx > 0 && LspUtil.isIdentifierChar(trimmed[idx - 1])) continue
        rest := trimmed[idx + kw.size ..-1].trim
        end  := 0
        while (end < rest.size && LspUtil.isIdentifierChar(rest[end])) end++
        if (end > 0 && rest[0].isUpper) return rest[0..<end]
      }
    }
    return ""
  }

}
