
using compiler

**
** TypeDefinitionService - Find the type definition for a symbol (Go to Type Definition)
** Resolves the static type of the expression under the cursor via TypeResolver,
** then locates that type's declaration via ProjectIndex.
**
class TypeDefinitionService
{
  **
  ** Find the type-definition result for the symbol at the given position.
  ** Returns null when the word under the cursor isn't a recognizable
  ** symbol/expression at all. Otherwise returns a map with either:
  **   "location": the LSP Location of the type's declaration, or
  **   "noSourceTypeName" / "noSourcePod": the resolved type name (and pod,
  **     if known) when the type has no project-local source to navigate to
  **     (e.g. a sys type or an external framework pod type).
  **
  [Str:Obj?]? findTypeDefinition(Str uri, LspPosition pos, Str source, ProjectIndex index)
  {
    try
    {
      word := LspUtil.getWordAtPosition(source, pos)
      if (word == null || word.isEmpty) return null

      LspProtocol.logInfo("TypeDefinition: looking for type of '$word' at line=${pos.line}")

      // If the cursor is already on a type name, jump to that type's own declaration.
      if (word[0].isUpper && index.hasType(word))
        return resolveResult(word, index, null, source)

      // Otherwise resolve the variable/expression's type via the shared resolver
      // used by HoverService, then locate that type's declaration.
      typeName := TypeResolver.resolveVarType(word, source, pos.line, index)
      if (typeName != null)
        return resolveResult(stripPodPrefix(typeName), index, podPrefix(typeName), source)

      // Bare method call with no parens (e.g. "return entityReferenceable != null"
      // where entityReferenceable() is a zero-arg method). resolveVarType only
      // handles declarations/assignments, not naked method-call expressions —
      // resolve directly from the method's own declaration line instead.
      bareCallResult := resolveBareMethodCallType(word, source, index)
      if (bareCallResult != null) return bareCallResult

      // Last resort: scope-aware symbol lookup (handles params/fields/locals
      // whose typeStr wasn't captured by the indexer — e.g. multi-line parameter
      // lists, which TypeResolver's single-line paren scan can't parse — by
      // reading the symbol's own declaration line directly).
      return resolveScopedSymbolType(word, uri, pos, source, index)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error finding type definition: $e")
      return null
    }
  }

  **
  ** Resolve the return type of a bare (parenthesis-less) zero-arg method call,
  ** e.g. "entityReferenceable" invoking "entityReferenceable()". Looks up the
  ** method's own declaration line in its owning file and parses the return
  ** type directly, since resolveVarType only covers declarations/assignments.
  **
  private [Str:Obj?]? resolveBareMethodCallType(Str word, Str source, ProjectIndex index)
  {
    methodSym := index.findSymbols(word).find |s| { s.kind == SymbolKind.method }
    if (methodSym == null) return null

    declSource := methodSym.fileUri == index.findFileUriForSource(source)
      ? source
      : index.allFileSources[methodSym.fileUri]
    if (declSource == null) return null

    declLine := LspUtil.getLine(declSource, methodSym.line)
    if (declLine == null) return null

    returnType := TypeResolver.extractMethodReturnType(declLine, word)
    if (returnType == null) return null

    return resolveResult(returnType, index, null, source)
  }

  **
  ** Resolve a param/field/localVar symbol's type using scope-aware lookup,
  ** then parsing its own declaration line directly. Handles cases where the
  ** indexer's typeStr is missing (e.g. AST parse failed for the file) and the
  ** declaration doesn't fit TypeResolver's text-scan patterns (e.g. a
  ** multi-line parameter list, where each parameter is on its own line with
  ** no closing paren for the scanner to match).
  **
  private [Str:Obj?]? resolveScopedSymbolType(Str word, Str uri, LspPosition pos, Str source, ProjectIndex index)
  {
    sym := index.findDefinition(word, uri, pos.line, pos.character)
    if (sym == null) return null
    if (sym.kind != SymbolKind.param && sym.kind != SymbolKind.localVar && sym.kind != SymbolKind.field)
      return null

    if (sym.typeStr != null)
      return resolveResult(stripPodPrefix(sym.typeStr), index, podPrefix(sym.typeStr), source)

    declSource := sym.fileUri == index.findFileUriForSource(source) ? source : index.allFileSources[sym.fileUri]
    if (declSource == null) return null

    declLine := LspUtil.getLine(declSource, sym.line)
    if (declLine == null) return null

    // For params, the type immediately precedes the name; strip anything up to
    // and including the last '(' or ',' so a first parameter sharing its line
    // with "methodName(" (e.g. "public new make(Context cx,") parses the same
    // way as a parameter alone on its own line ("Context cx,").
    parseLine := declLine
    if (sym.kind == SymbolKind.param)
    {
      lastBoundary := [parseLine.indexr("("), parseLine.indexr(",")].findAll { it != null }.max
      if (lastBoundary != null) parseLine = parseLine[lastBoundary + 1..-1]
    }

    typeName := TypeResolver.extractDeclaredType(parseLine, word)
    if (typeName == null) return null

    return resolveResult(typeName, index, null, source)
  }

  **
  ** Build the result for a resolved type name: a Location when the type is
  ** declared in the project, or a "no source" descriptor (with pod name when
  ** known) when the type only exists as a compiled sys or external-pod type
  ** with no project-local source to navigate to.
  ** knownPodName is passed when the caller already had a qualified name
  ** (e.g. "skyarcd::Context"); otherwise pod is guessed via reflection over
  ** the file's "using" pods.
  **
  private [Str:Obj?] resolveResult(Str typeName, ProjectIndex index, Str? knownPodName, Str source)
  {
    typeSym := index.findSymbols(typeName).find |s| { s.kind == SymbolKind.type }
    if (typeSym != null)
      return ["location": createLocation(typeSym.fileUri, typeSym.line, typeSym.col, typeSym.name.size)]

    return ["noSourceTypeName": typeName, "noSourcePod": knownPodName ?: findPodName(typeName, source)]
  }

  **
  ** Find the pod that reflection resolves typeName to, for a friendlier
  ** "defined in pod X" message. Searches sys plus every pod referenced by
  ** the file's "using" statements. Returns null if the type can't be
  ** reflected (still shown to the user as "no source available").
  **
  private Str? findPodName(Str typeName, Str source)
  {
    try
    {
      sysType := Pod.find("sys", false)?.type(typeName, false)
      if (sysType != null) return sysType.pod.name

      upi := UsingPodIndex.fromSource(source)
      t := upi.getType(typeName)
      return t?.pod?.name
    }
    catch (Err e) { return null }
  }

  **
  ** Extract the "pod" portion of a qualified type name, e.g.
  ** "skyarcd::Context" -> "skyarcd". Returns null for unqualified names.
  **
  private Str? podPrefix(Str typeName)
  {
    colonIdx := typeName.index("::")
    return colonIdx != null ? typeName[0..<colonIdx] : null
  }

  **
  ** Strip a "pod::" qualifier from a type name, e.g. "sys::Str" -> "Str".
  **
  private Str stripPodPrefix(Str typeName)
  {
    colonIdx := typeName.index("::")
    return colonIdx != null ? typeName[colonIdx + 2..-1] : typeName
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
}
