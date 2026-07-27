
using compiler

**
** InlayHintService - Computes inline type and parameter-name hints
** (textDocument/inlayHint). Two kinds of hints:
**  1. Type hints after inferred "x := expr" local variable declarations.
**  2. Parameter-name hints before each positional argument of a method call.
** Both reuse TypeResolver's existing type-inference pipeline rather than
** re-deriving types heuristically.
**
class InlayHintService
{
  ** LSP InlayHintKind.Type
  private static const Int kindType := 1

  ** LSP InlayHintKind.Parameter
  private static const Int kindParameter := 2

  **
  ** Compute inlay hints for the given range of a file.
  ** skipSingleParamCalls: when true, a call with only one parameter gets no
  ** parameter-name hint (its meaning is usually obvious from context).
  **
  [Str:Obj?][] computeHints(Str uri, LspRange range, Str source, ProjectIndex index, Bool skipSingleParamCalls := true)
  {
    hints := [Str:Obj?][,]
    try
    {
      lines := source.splitLines
      startLine := range.start.line.max(0)
      endLine := range.end.line.min(lines.size - 1)

      addTypeHints(hints, uri, lines, startLine, endLine, source, index)
      addParamHints(hints, uri, lines, startLine, endLine, source, index, skipSingleParamCalls)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error computing inlay hints: $e")
    }
    return hints
  }

  // ---- Feature 1: type hints on inferred declarations ----

  private Void addTypeHints([Str:Obj?][] hints, Str uri, Str[] lines, Int startLine, Int endLine,
                             Str source, ProjectIndex index)
  {
    index.symbolsInFile(uri).each |sym|
    {
      if (sym.kind != SymbolKind.localVar) return
      if (sym.line < startLine || sym.line > endLine) return
      if (sym.line >= lines.size) return

      line := lines[sym.line]

      // Only hint inferred declarations — skip when the line already shows
      // an explicit type ("Type x := ...").
      if (TypeResolver.extractDeclaredType(line, sym.name) != null) return

      typeName := sym.typeStr ?: TypeResolver.resolveVarType(sym.name, source, sym.line, index)
      if (typeName == null) return
      displayType := stripPodPrefix(typeName)
      if (displayType.isEmpty) return

      nameEndCol := findNameEndCol(line, sym.name)
      if (nameEndCol == null) return

      hints.add(makeHint(sym.line, nameEndCol, ": $displayType", kindType, true, false))
    }
  }

  ** Find the column right after the declared variable name on its line
  ** (skips a possible explicit type prefix — hints attach after the name,
  ** not after the type).
  private Int? findNameEndCol(Str line, Str varName)
  {
    idx := TypeResolver.findWordInLine(line, varName)
    if (idx == null) return null
    return idx + varName.size
  }

  // ---- Feature 2: parameter-name hints at call sites ----

  private Void addParamHints([Str:Obj?][] hints, Str uri, Str[] lines, Int startLine, Int endLine,
                              Str source, ProjectIndex index, Bool skipSingleParamCalls)
  {
    for (lineNum := startLine; lineNum <= endLine; lineNum++)
    {
      line := lines[lineNum]
      eachCallInLine(line) |call|
      {
        if (isInStringOrComment(line, call.nameStart)) return
        if (isDeclarationSite(index, uri, lineNum, call.name)) return

        paramNames := resolveParamNames(call, uri, line, source, lineNum, index)
        if (paramNames == null) return
        if (skipSingleParamCalls && paramNames.size <= 1) return

        argCount := call.argStarts.size
        n := paramNames.size.min(argCount)
        for (i := 0; i < n; i++)
        {
          // Skip named/labelled-looking args and skip params whose name
          // already matches the argument text (redundant hint).
          argCol := call.argStarts[i]
          if (argTextStartsWithName(line, argCol, paramNames[i])) continue
          hints.add(makeHint(lineNum, argCol, "${paramNames[i]}:", kindParameter, false, true))
        }
      }
    }
  }

  ** True if line is a method's own declaration site rather than a call site
  ** — e.g. "Void insert(Int index, Str item) {}" is a declaration; its
  ** parameter list must never be mistaken for call arguments. (IndexedSymbol
  ** .col for a method points at the start of its modifiers/return type, not
  ** the method name itself, so this matches by name+line only.)
  private Bool isDeclarationSite(ProjectIndex index, Str uri, Int line, Str name)
  {
    return index.symbolsInFile(uri).any |sym|
    {
      sym.kind == SymbolKind.method && sym.name == name && sym.line == line
    }
  }

  ** True if the source text at argCol already begins with paramName (e.g.
  ** "siteId: siteId" would be redundant to hint) — a cheap readability guard.
  private Bool argTextStartsWithName(Str line, Int argCol, Str paramName)
  {
    end := argCol + paramName.size
    if (end > line.size) return false
    if (line[argCol ..< end] != paramName) return false
    return end >= line.size || !LspUtil.isIdentifierChar(line[end])
  }

  ** Scan a single line for "receiver.name(args)" or "Name(args)" call
  ** patterns, invoking cb once per call found. Only calls whose full
  ** argument list is on this same line are recognized (multi-line call
  ** argument lists are out of scope for this heuristic scan).
  private Void eachCallInLine(Str line, |InlayCallSite| cb)
  {
    i := 0
    while (i < line.size)
    {
      ch := line[i]
      if (LspUtil.isIdentifierChar(ch) && (i == 0 || !LspUtil.isIdentifierChar(line[i - 1])))
      {
        start := i
        while (i < line.size && LspUtil.isIdentifierChar(line[i])) i++
        name := line[start..<i]

        // Must be immediately followed by '(' to be a call
        if (i < line.size && line[i] == '(')
        {
          parenOpen := i
          parenClose := matchingParen(line, parenOpen)
          if (parenClose != null)
          {
            argsStr := line[parenOpen + 1 ..< parenClose]
            call := InlayCallSite { it.name = name; it.nameStart = start }

            // Receiver: identifier immediately before a '.' preceding start
            recvEnd := start
            j := recvEnd
            while (j > 0 && line[j - 1] == ' ') j--
            if (j > 0 && line[j - 1] == '.')
            {
              dotPos := j - 1
              recvStart := dotPos
              while (recvStart > 0 && (LspUtil.isIdentifierChar(line[recvStart - 1]) || line[recvStart - 1] == '.'))
                recvStart--
              call.receiver = line[recvStart..<dotPos]
            }

            call.argStarts = argStartColumns(argsStr, parenOpen + 1)
            cb.call(call)
          }
          i = parenClose != null ? parenClose + 1 : i
        }
      }
      else i++
    }
  }

  ** Find the column of each top-level argument's first non-space character
  ** within a call's argument-list text, given the text's absolute start
  ** column in the line.
  private Int[] argStartColumns(Str argsStr, Int absoluteStart)
  {
    cols := Int[,]
    if (argsStr.trim.isEmpty) return cols

    parts := ParamListParser.splitTopLevel(argsStr)
    offset := 0
    parts.each |part|
    {
      leading := 0
      while (leading < part.size && part[leading] == ' ') leading++
      if (leading < part.size)
        cols.add(absoluteStart + offset + leading)
      offset += part.size + 1 // +1 for the comma consumed by splitTopLevel
    }
    return cols
  }

  ** Find the ')' matching the '(' at parenOpen, respecting nested () and [].
  private Int? matchingParen(Str line, Int parenOpen)
  {
    depth := 0
    i := parenOpen
    while (i < line.size)
    {
      ch := line[i]
      if (ch == '(' || ch == '[') depth++
      else if (ch == ')' || ch == ']')
      {
        depth--
        if (depth == 0) return i
      }
      i++
    }
    return null
  }

  ** Resolve the ordered parameter names for a call, checking the project
  ** index first (exact, AST-backed), then completion YML defs (framework/pod
  ** methods), then reflection as a last resort.
  private Str[]? resolveParamNames(InlayCallSite call, Str uri, Str line, Str source, Int lineNum, ProjectIndex index)
  {
    // Constructor call: Name(args) with uppercase receiver-less name.
    if (call.receiver.isEmpty && call.name.size > 0 && call.name[0].isUpper)
      return resolveParamNamesForType(call.name, "make", index)

    Str? receiverType := null
    if (call.receiver.size > 0 && call.receiver[0].isUpper)
      receiverType = call.receiver
    else if (!call.receiver.isEmpty)
      receiverType = TypeResolver.resolveVarType(call.receiver, source, lineNum, index)
    else
      // Bare call with no receiver — either a same-class method call or a
      // top-level function; try the enclosing type first.
      receiverType = index.getEnclosingTypeAtLine(uri, lineNum)

    if (receiverType == null) return null
    simpleType := stripPodPrefix(receiverType)

    return resolveParamNamesForType(simpleType, call.name, index)
  }

  ** Resolve parameter names for typeName.methodName, trying the project
  ** index first, then YML completion defs, then live reflection.
  private Str[]? resolveParamNamesForType(Str typeName, Str methodName, ProjectIndex index)
  {
    projectNames := index.findMethodParamNames(typeName, methodName)
    if (projectNames != null) return projectNames

    ymlItems := CompletionDefs.cur.itemsFor(qualifyForYml(typeName, index))
    if (ymlItems != null)
    {
      ymlItem := ymlItems.find |item| { item.label == methodName }
      if (ymlItem != null)
      {
        names := CompletionDefs.paramNamesFrom(ymlItem.detail)
        if (!names.isEmpty) return names
      }
    }

    return resolveParamNamesViaReflection(typeName, methodName)
  }

  ** Best-effort qualification of a simple type name for YML lookup
  ** (e.g. "List" -> "sys::List" via alias table; already-qualified names
  ** pass through unchanged).
  private Str qualifyForYml(Str typeName, ProjectIndex index)
  {
    if (typeName.contains("::")) return typeName
    return CompletionDefs.cur.resolveAlias(typeName) ?: typeName
  }

  ** Reflect over the pod containing typeName to read a method's real
  ** parameter names — covers pod/framework methods not described in the
  ** completion YML.
  private Str[]? resolveParamNamesViaReflection(Str typeName, Str methodName)
  {
    try
    {
      simpleName := typeName.contains("::") ? typeName[typeName.index("::") + 2..-1] : typeName
      podName := typeName.contains("::") ? typeName[0..<typeName.index("::")] : "sys"

      t := Pod.find(podName, false)?.type(simpleName, false)
      slot := t?.slot(methodName, false)
      if (slot == null || slot isnot Method) return null

      params := ((Method)slot).params
      return params.map |p| { p.name }
    }
    catch (Err e) { return null }
  }

  ** True if col in line falls inside a string literal or a line comment.
  private Bool isInStringOrComment(Str line, Int col)
  {
    inStr := false
    escape := false
    for (i := 0; i < col && i < line.size; i++)
    {
      ch := line[i]
      if (escape) { escape = false; continue }
      if (ch == '\\') { escape = true; continue }
      if (ch == '"') { inStr = !inStr; continue }
      if (!inStr && ch == '/' && i + 1 < line.size && line[i + 1] == '/')
        return true
    }
    return inStr
  }

  // ---- Shared ----

  private Str stripPodPrefix(Str typeName)
  {
    colonIdx := typeName.index("::")
    return colonIdx != null ? typeName[colonIdx + 2..-1] : typeName
  }

  private [Str:Obj?] makeHint(Int line, Int col, Str label, Int kind, Bool paddingLeft, Bool paddingRight)
  {
    return [
      "position": ["line": line, "character": col],
      "label": label,
      "kind": kind,
      "paddingLeft": paddingLeft,
      "paddingRight": paddingRight
    ]
  }
}

**
** One parsed call-expression on a line: the method/ctor name, where its
** identifier starts, and the start column of each top-level argument.
**
class InlayCallSite
{
  Str receiver := ""
  Str name := ""
  Int nameStart := 0
  Int[] argStarts := [,]
}
