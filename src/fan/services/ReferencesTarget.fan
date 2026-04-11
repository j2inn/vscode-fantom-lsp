**
** ReferencesTarget - Resolves what symbol the cursor is on and builds the
** type family needed to filter false-positive references.
**
** Three target kinds are supported:
**   type   - a class / mixin name
**   member - a method or field, scoped to a type family
**   local  - a local variable / parameter, single-file + single-method scope
**
class ReferencesTarget
{
  ** "type" | "member" | "local"
  const Str kind

  ** Symbol name (without type qualifier)
  const Str name

  ** For member: the declaring type name (may be null when unknown)
  const Str? ownerType

  ** All types whose instances could own this member (owner + its subtypes).
  ** Empty for kind=="type" and kind=="local".
  const Str[] typeFamily

  ** For local: the method name that scopes the search
  const Str? enclosingMethod

  ** For local: the file URI where the local lives
  const Str? localFileUri

  private new make(Str kind, Str name, Str? ownerType,
                   Str[] typeFamily, Str? enclosingMethod, Str? localFileUri)
  {
    this.kind            = kind
    this.name            = name
    this.ownerType       = ownerType
    this.typeFamily      = typeFamily
    this.enclosingMethod = enclosingMethod
    this.localFileUri    = localFileUri
  }

  ** Build a type target
  static ReferencesTarget forType(Str name) {
    make("type", name, null, Str[,], null, null)
  }

  ** Build a member target with a pre-computed type family
  static ReferencesTarget forMember(Str name, Str? ownerType, Str[] family) {
    make("member", name, ownerType, family, null, null)
  }

  ** Build a local-variable target
  static ReferencesTarget forLocal(Str name, Str enclosingMethod, Str fileUri) {
    make("local", name, null, Str[,], enclosingMethod, fileUri)
  }

  // ---------------------------------------------------------------------------

  **
  ** Resolve the cursor position into a ReferencesTarget.
  ** Returns null when the symbol cannot be identified.
  **
  static ReferencesTarget? resolve(Str uri, LspPosition pos,
                                   Str source, ProjectIndex index)
  {
    word := LspUtil.getWordAtPosition(source, pos)
    if (word == null || word.isEmpty) return null

    line := LspUtil.getLine(source, pos.line)
    if (line == null) return null

    // ── static / enum access:  TypeName.member ──────────────────────────────
    wordStart := pos.character
    while (wordStart > 0 && LspUtil.isIdentifierChar(line[wordStart - 1])) wordStart--
    if (wordStart >= 2 && line[wordStart - 1] == '.')
    {
      typeEnd   := wordStart - 1
      typeStart := typeEnd - 1
      while (typeStart > 0 && LspUtil.isIdentifierChar(line[typeStart - 1])) typeStart--
      beforeDot := line[typeStart ..< typeEnd]
      if (beforeDot.size > 0 && beforeDot[0].isUpper)
        return forMember(word, beforeDot, buildFamily(beforeDot, index))
    }

    // ── uppercase word  →  type reference ───────────────────────────────────
    if (word[0].isUpper)
      return forType(word)

    // ── lowercase word  →  member or local ──────────────────────────────────
    sym := index.findDefinition(word, uri, pos.line, pos.character)
    if (sym != null)
    {
      if (sym.kind == SymbolKind.localVar || sym.kind == SymbolKind.param)
        return forLocal(word, sym.methodName ?: "", sym.fileUri)

      if (sym.kind == SymbolKind.method || sym.kind == SymbolKind.field)
      {
        owner := sym.typeName
        return forMember(word, owner, owner != null ? buildFamily(owner, index) : Str[,])
      }
    }

    // ── fallback: bare name with no index match ──────────────────────────────
    return forMember(word, null, Str[,])
  }

  // ---------------------------------------------------------------------------

  ** Build { ownerType } ∪ all project subtypes of ownerType
  private static Str[] buildFamily(Str ownerType, ProjectIndex index)
  {
    family := Str[ownerType]
    index.allTypeNames.each |t|
    {
      if (t == ownerType) return
      if (index.getBaseTypeChain(t).contains(ownerType)) family.add(t)
    }
    return family
  }
}
