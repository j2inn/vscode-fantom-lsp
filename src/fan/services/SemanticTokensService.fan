
**
** SemanticTokensService - produces LSP semantic token data for a file.
**
** The service queries indexed symbols from ProjectIndex and encodes them as
** a delta-encoded integer array as required by the
** textDocument/semanticTokens/full protocol:
**   [deltaLine, deltaStartChar, length, tokenTypeIndex, tokenModifiersBitmask]
**
** Token types (indices must match SemanticTokensLegend.tokenTypes()):
**   0 = type, 1 = enumMember, 2 = method, 3 = field/property,
**   4 = variable, 5 = parameter, 6 = facet/decorator
**
** Token modifiers (bit flags, must match SemanticTokensLegend.tokenModifiers()):
**   bit 0 (1) = static, bit 1 (2) = readonly
**
class SemanticTokensService
{
  **
  ** Build the full semantic tokens response map for the given file.
  ** Returns {"data": Int[]}.  Data is empty if the file is not indexed.
  **
  Str:Obj? fullTokens(Str fileUri, ProjectIndex index)
  {
    syms := index.getFileSymbols(fileUri)
    if (syms.isEmpty) return ["data": Int[,]]

    encoded := encode(syms)
    return ["data": encoded]
  }

  // ---- Private ----

  private Int[] encode(IndexedSymbol[] syms)
  {
    // Filter to only symbols we care about, then sort by position
    tokens := syms.findAll |s| { tokenType(s) != null }
    tokens.sort |a, b| {
      if (a.line != b.line) return a.line <=> b.line
      return a.col <=> b.col
    }

    data := Int[,]
    prevLine := 0
    prevCol  := 0

    tokens.each |sym|
    {
      tt := tokenType(sym)
      if (tt == null) return

      len := sym.name.size
      if (len == 0) return

      deltaLine := sym.line - prevLine
      deltaCol  := deltaLine == 0 ? sym.col - prevCol : sym.col

      data.add(deltaLine)
      data.add(deltaCol)
      data.add(len)
      data.add(tt)
      data.add(tokenModifiers(sym))

      prevLine = sym.line
      prevCol  = sym.col
    }
    return data
  }

  **
  ** Map a symbol kind to its token-type index, or null to skip the symbol.
  **
  private static Int? tokenType(IndexedSymbol sym)
  {
    switch (sym.kind)
    {
      case SymbolKind.type:     return SemanticTokenTypes.typeToken
      case SymbolKind.enumVal:  return SemanticTokenTypes.enumMember
      case SymbolKind.method:   return sym.typeName == null ? null : SemanticTokenTypes.method
      case SymbolKind.field:    return sym.typeName == null ? null : SemanticTokenTypes.field
      case SymbolKind.localVar: return SemanticTokenTypes.variable
      case SymbolKind.param:    return SemanticTokenTypes.parameter
      default:                  return null
    }
  }

  **
  ** Build the modifier bitmask for a symbol.
  **
  private static Int tokenModifiers(IndexedSymbol sym)
  {
    mods := 0
    if (sym.isStatic)
      mods = mods.or(SemanticTokenModifiers.staticMod)
    // const fields are readonly
    if (sym.kind == SymbolKind.field && sym.name.size > 0 && sym.name[0].isUpper)
      mods = mods.or(SemanticTokenModifiers.readonlyMod)
    return mods
  }
}
