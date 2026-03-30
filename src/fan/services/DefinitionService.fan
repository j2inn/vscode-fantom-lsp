
using compiler

**
** DefinitionService - Find symbol definitions (Go to Definition)
** Uses ProjectIndex for scope-aware lookup, with compiler fallback
** for external pod types.
**
class DefinitionService
{
  **
  ** Find the definition location for a symbol at the given position.
  ** Uses the project index for scope-aware lookup across all project files.
  ** Falls back to compiler-based resolution for external pod types.
  **
  [Str:Obj?]? findDefinition(Str uri, LspPosition pos, Str source, ProjectIndex index)
  {
    try
    {
      word := LspUtil.getWordAtPosition(source, pos)
      if (word == null || word.isEmpty) return null

      line := LspUtil.getLine(source, pos.line)
      if (line == null) return null

      LspProtocol.logInfo("Definition: looking for '$word' at line=${pos.line}")

      // 0. Check if this is a facet: @TypeName
      if (word[0].isUpper)
      {
        wordStart := pos.character
        while (wordStart > 0 && LspUtil.isIdentifierChar(line[wordStart - 1]))
          wordStart--
        if (wordStart > 0 && line[wordStart - 1] == '@')
        {
          LspProtocol.logInfo("Definition: '$word' is a facet, resolving as type")
          facetSym := index.findSymbols(word).find |s| { s.kind == SymbolKind.type }
          if (facetSym != null)
            return createLocation(facetSym.fileUri, facetSym.line, facetSym.col, facetSym.name.size)
          return resolveExternalSymbol(word, uri, source)
        }
      }

      // 0b. Check for enum value: TypeName.value
      wordStart := pos.character
      while (wordStart > 0 && LspUtil.isIdentifierChar(line[wordStart - 1]))
        wordStart--
      if (wordStart >= 2 && line[wordStart - 1] == '.')
      {
        dotPos := wordStart - 1
        typeEnd := dotPos
        typeStart := typeEnd - 1
        while (typeStart > 0 && LspUtil.isIdentifierChar(line[typeStart - 1]))
          typeStart--
        if (typeStart < typeEnd)
        {
          beforeDot := line[typeStart ..< typeEnd]
          if (beforeDot.size > 0 && beforeDot[0].isUpper)
          {
            LspProtocol.logInfo("Definition: checking member '${beforeDot}.${word}'")

            // Prefer enum values (explicit type match)
            enumSym := index.findSymbols(word).find |s|
            {
              s.kind == SymbolKind.enumVal && s.typeName == beforeDot
            }
            if (enumSym != null)
            {
              LspProtocol.logInfo("Definition: found enum value '${enumSym.name}' at ${enumSym.fileUri}:${enumSym.line}")
              return createLocation(enumSym.fileUri, enumSym.line, enumSym.col, enumSym.name.size)
            }

            // Also resolve fields and methods on the named type.
            // This handles static const fields like IoModuleConstants.MY_CONST
            // where the same name exists in the current file (would fool findDefinition).
            memberSym := index.findMemberSymbol(beforeDot, word)
            if (memberSym != null)
            {
              LspProtocol.logInfo("Definition: found member '${memberSym.name}' on '${beforeDot}' at ${memberSym.fileUri}:${memberSym.line}")
              return createLocation(memberSym.fileUri, memberSym.line, memberSym.col, memberSym.name.size)
            }
          }
          else
          {
            // Instance method/field access: e.g. _logger.debug, obj.method.
            // The word cannot be a local variable or parameter — skip scope-aware
            // lookup and prefer methods/fields from the project index.
            LspProtocol.logInfo("Definition: '${beforeDot}.${word}' is instance member access")
            memberCandidates := index.findSymbols(word).findAll |s|
            {
              s.kind == SymbolKind.method || s.kind == SymbolKind.field || s.kind == SymbolKind.enumVal
            }
            if (!memberCandidates.isEmpty)
            {
              memberSym := memberCandidates.first
              LspProtocol.logInfo("Definition: found instance member '${memberSym.name}' at ${memberSym.fileUri}:${memberSym.line}")
              return createLocation(memberSym.fileUri, memberSym.line, memberSym.col, memberSym.name.size)
            }
            // Not in project index — try external resolution (e.g. framework pods)
            return resolveExternalSymbol(word, uri, source)
          }
        }
      }

      // 1. Check if this is a constructor call: TypeName(args)
      //    If so, navigate to the 'make' method instead of the class.
      if (word.size > 0 && word[0].isUpper && isConstructorCall(source, pos, word))
      {
        LspProtocol.logInfo("Definition: '$word' is a constructor call, looking for 'make'")
        makeSym := index.findMemberSymbol(word, "make")
        if (makeSym != null)
        {
          LspProtocol.logInfo("Definition: found constructor '${makeSym.name}' at ${makeSym.fileUri}:${makeSym.line}")
          return createLocation(makeSym.fileUri, makeSym.line, makeSym.col, makeSym.name.size)
        }
      }

      // 2. Try scope-aware lookup from the project index
      sym := index.findDefinition(word, uri, pos.line, pos.character)
      if (sym != null)
      {
        LspProtocol.logInfo("Definition: found ${sym.kind} '${sym.name}' at ${sym.fileUri}:${sym.line}")
        return createLocation(sym.fileUri, sym.line, sym.col, sym.name.size)
      }

      // 3. Fallback: try compiler-based resolution for external pod types
      LspProtocol.logInfo("Definition: not in index, trying compiler for external types")
      return resolveExternalSymbol(word, uri, source)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error finding definition: $e")
      return null
    }
  }

  **
  ** Resolve a symbol from external pods via compilation and reflection.
  ** Used for types/methods from dependency pods (not the current project).
  **
  private [Str:Obj?]? resolveExternalSymbol(Str word, Str uri, Str source)
  {
    try
    {
      // Try compiling the current file to get AST types
      compiler := LspCompiler.create(uri, source)
      try { compiler.frontend }
      catch (CompilerErr e) {}

      if (compiler.types != null)
      {
        for (i := 0; i < compiler.types.size; i++)
        {
          ctype := compiler.types[i]
          if (ctype isnot TypeDef) continue
          td := (TypeDef)ctype

          if (td.name == word)
            return createLocationFromLoc(td.loc, uri, word.size)

          for (j := 0; j < td.methodDefs.size; j++)
          {
            m := td.methodDefs[j]
            if (m.name == word)
              return createLocationFromLoc(m.loc, uri, word.size)
          }

          for (k := 0; k < td.fieldDefs.size; k++)
          {
            f := td.fieldDefs[k]
            if (f.name == word)
              return createLocationFromLoc(f.loc, uri, word.size)
          }
        }
      }
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error resolving external symbol: $e")
    }
    return null
  }

  **
  ** Create LSP Location from 0-based line/col and symbol length
  **
  private [Str:Obj?] createLocation(Str uri, Int line, Int col, Int symbolLen)
  {
    return [
      "uri": uri,
      "range": [
        "start": ["line": line, "character": col],
        "end": ["line": line, "character": col + symbolLen]
      ]
    ]
  }

  **
  ** Create LSP Location from a Fantom compiler Loc
  **
  private [Str:Obj?]? createLocationFromLoc(Loc loc, Str currentUri, Int symbolLen)
  {
    try
    {
      line := (loc.line ?: 1) - 1
      col := (loc.col ?: 1) - 1
      return createLocation(currentUri, line, col, symbolLen)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error creating location from Loc: $e")
      return null
    }
  }

  **
  ** Check if the word at the given position is used as a constructor call.
  ** A constructor call is TypeName( — an uppercase identifier directly followed by '('.
  **
  private Bool isConstructorCall(Str source, LspPosition pos, Str word)
  {
    line := LspUtil.getLine(source, pos.line)
    if (line == null) return false

    // Find the end of the word on this line
    wordEnd := pos.character
    while (wordEnd < line.size && LspUtil.isIdentifierChar(line[wordEnd]))
      wordEnd++

    // Check if the character right after the word is '('
    return wordEnd < line.size && line[wordEnd] == '('
  }
}
