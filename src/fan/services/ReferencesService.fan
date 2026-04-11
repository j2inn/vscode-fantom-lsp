**
** ReferencesService - Orchestrates "Find All References" and
** "Find All Implementations" for the LSP server.
**
class ReferencesService
{
  private ReferencesScanner scanner := ReferencesScanner()

  **
  ** Find all references to the symbol at the given cursor position.
  ** includeDecl: when true the declaration site is included (LSP flag).
  **
  [Str:Obj?][] findReferences(Str uri, LspPosition pos, Str source,
                               ProjectIndex index, Bool includeDecl)
  {
    target := ReferencesTarget.resolve(uri, pos, source, index)
    if (target == null) return [Str:Obj?][,]

    results := [Str:Obj?][,]
    index.allFileSources.each |src, fileUri|
    {
      hits := scanner.scan(fileUri, src, target)
      results.addAll(hits)
    }

    if (!includeDecl)
      results = results.findAll |r| { !isDeclSite(r, target, index) }

    return results
  }

  **
  ** Find all project types that directly implement / extend the type at cursor.
  ** Also finds method overrides when the cursor is on a method inside a type.
  **
  [Str:Obj?][] findImplementations(Str uri, LspPosition pos, Str source,
                                    ProjectIndex index)
  {
    word := LspUtil.getWordAtPosition(source, pos)
    if (word == null || word.isEmpty) return [Str:Obj?][,]

    line := LspUtil.getLine(source, pos.line)

    // Member override: cursor on a method/field name inside a type
    if (word.size > 0 && !word[0].isUpper && line != null)
    {
      sym := index.findDefinition(word, uri, pos.line, pos.character)
      if (sym != null && sym.typeName != null &&
          (sym.kind == SymbolKind.method || sym.kind == SymbolKind.field))
        return findMethodOverrides(word, sym.typeName, index)
    }

    // Type: find implementing/extending classes
    targetType := ""
    if (word[0].isUpper)
      targetType = word
    else
    {
      resolved := index.findDefinition(word, uri, pos.line, pos.character)
      if (resolved?.typeName != null) targetType = resolved.typeName
    }
    if (targetType.isEmpty) return [Str:Obj?][,]

    results := [Str:Obj?][,]
    index.allFileSources.each |src, fileUri|
    {
      results.addAll(scanner.scanImplementations(fileUri, src, targetType))
    }
    return results
  }

  // ---------------------------------------------------------------------------

  private [Str:Obj?][] findMethodOverrides(Str methodName, Str baseType,
                                            ProjectIndex index)
  {
    results := [Str:Obj?][,]
    // Collect all subtypes of baseType
    subtypes := index.allTypeNames.findAll |t|
    {
      index.getBaseTypeChain(t).contains(baseType)
    }
    subtypes.each |t|
    {
      sym := index.findMemberSymbol(t, methodName)
      if (sym != null)
        results.add(["uri": sym.fileUri, "range": [
          "start": ["line": sym.line, "character": sym.col],
          "end":   ["line": sym.line, "character": sym.col + sym.name.size]
        ]])
    }
    return results
  }

  ** True when an LSP location map points to the declaration of the target symbol
  private Bool isDeclSite([Str:Obj?] location, ReferencesTarget target,
                           ProjectIndex index)
  {
    uri := location["uri"] as Str
    if (uri == null) return false
    declLine := locLine(location)
    if (declLine == null) return false
    return index.findSymbols(target.name).any |s|
    {
      s.fileUri == uri && s.line == declLine
    }
  }

  ** Extract the start line from an LSP Location map, or null
  private Int? locLine([Str:Obj?] location)
  {
    try
    {
      range := location["range"] as Str:Obj?
      if (range == null) return null
      start := range["start"] as Str:Obj?
      if (start == null) return null
      return start["line"] as Int
    }
    catch (Err e) { return null }
  }
}
