using compiler

**
** SourceStubber - Builds a signature-only "stub" of a Fantom source file.
**
** The file is parsed with the Fantom compiler and every method and field
** accessor body found in the AST is replaced with 'stubBody'. Using
** statements, type headers, facets, fields and slot signatures are kept
** verbatim, so compiling a stub next to another file exposes the real types,
** constructors and slot signatures without type-checking the original
** method bodies. Field initializers stay in the text but are not compiled
** (see 'StubbedCompiler').
**
class SourceStubber
{
  ** Body inserted in place of every stripped method body
  static const Str stubBody := "{ throw sys::Err() }"

  ** URI (Loc file) of the unit declaring placeholder types (see 'placeholders')
  static const Str placeholderUri := "lsp-stub-placeholders"

  **
  ** Return the stub of a file, or null when the file cannot be parsed
  ** (syntax error) and therefore cannot be stubbed safely.
  **
  ** 'otherTypeNames' are the project types declared in other files. The
  ** parser stops at some uses of unknown types (e.g. 'Foo x := ...',
  ** 'Foo#'), so each of them is declared as an empty placeholder class
  ** while parsing: only the AST of the file itself is used.
  **
  static SourceStub? stub(Str fileUri, Str source, Str[] otherTypeNames := Str[,])
  {
    try
    {
      c := LspCompiler.create(fileUri, source)
      unit := parseUnit(c, otherTypeNames)
      if (unit == null) return null
      return SourceStub(replaceBodies(source, unit), referencedTypes(unit))
    }
    catch (Err e)
    {
      LspProtocol.logInfo("SourceStubber: cannot stub $fileUri: $e")
      return null
    }
  }

  **
  ** Source of a unit declaring an empty class for each of 'typeNames'.
  ** The parser stops at some uses of unknown types ('Foo x := ...', 'Foo#',
  ** 'Foo[,]'), so types that must only be *parsed* (not compiled) are
  ** declared as placeholders.
  **
  static Str placeholders(Str[] typeNames)
  {
    // Synthetic names (e.g. closure types 'Foo$0') cannot be declared
    names := typeNames.findAll |name| { isIdentifier(name) }
    return names.map |name| { "class $name {}" }.join("\n")
  }

  private static Bool isIdentifier(Str name)
  {
    return !name.isEmpty && (name[0].isAlpha || name[0] == '_') &&
           name.all |ch| { ch.isAlphaNum || ch == '_' }
  }

  **
  ** Return the distinct identifier tokens of a source, as produced by the
  ** Fantom tokenizer (comments and string literals excluded). Returns an
  ** empty list when the source cannot be tokenized.
  **
  static Str[] identifiers(Str fileUri, Str source)
  {
    try
    {
      c := LspCompiler.create(fileUri, source)
      tokens := Tokenizer(c, Loc(fileUri), source, false).tokenize
      names := Str:Bool[:]
      tokens.each |tok|
      {
        if (tok.kind === compiler::Token.identifier) names[tok.val] = true
      }
      return names.keys
    }
    catch (Err e)
    {
      return Str[,]
    }
  }

  **
  ** Add the name of a type, or of the types it is built from (list, map
  ** and function types), to 'names'.
  **
  internal static Void addTypeNames(CType? type, Str:Bool names)
  {
    if (type == null) return
    t := type.deref.toNonNullable
    if (t is ListType)
    {
      addTypeNames(((ListType)t).v, names)
    }
    else if (t is MapType)
    {
      addTypeNames(((MapType)t).k, names)
      addTypeNames(((MapType)t).v, names)
    }
    else if (t is FuncType)
    {
      ((FuncType)t).params.each |p| { addTypeNames(p, names) }
      addTypeNames(((FuncType)t).ret, names)
    }
    else
    {
      names[t.name] = true
    }
  }

  **
  ** Run the compiler front end up to parsing and return the parsed unit.
  ** Unresolved types are expected (other project files are not visible),
  ** so only a parse-stopping syntax error makes the file unstubbable.
  **
  private static CompilationUnit? parseUnit(Compiler c, Str[] otherTypeNames)
  {
    InitInput(c).run
    tokenize := Tokenize(c)
    tokenize.run
    if (!otherTypeNames.isEmpty)
      tokenize.tokenize(Loc(placeholderUri), placeholders(otherTypeNames))
    StubbedCompiler.runTolerant(ResolveDepends(c))
    StubbedCompiler.runTolerant(ScanForUsingsAndTypes(c))
    StubbedCompiler.runTolerant(ResolveImports(c))

    unit := c.pod?.units?.first
    if (unit == null || unit.tokens == null) return null
    try
      Parser(c, unit, ClosureExpr[,]).parse
    catch (CompilerErr e)
      return null
    return unit
  }

  **
  ** Names of the types the compiled part of the stub refers to: base
  ** types, slot signatures, facets, parameter defaults, enum arguments and
  ** constructor chains. Method bodies and field initializers are excluded
  ** because they are not compiled.
  **
  private static Str[] referencedTypes(CompilationUnit unit)
  {
    names := Str:Bool[:]
    collector := StubTypeNameCollector(names)
    unit.types.each |TypeDef td|
    {
      addTypeNames(td.base, names)
      td.mixins.each |m| { addTypeNames(m, names) }
      collector.walkFacets(td.facets)
      td.enumDefs.each |ed| { collector.walkExprs(ed.ctorArgs) }
      td.fieldDefs.each |fd|
      {
        addTypeNames(fd.fieldType, names)
        collector.walkFacets(fd.facets)
      }
      td.methodDefs.each |md|
      {
        addTypeNames(md.returnType, names)
        collector.walkFacets(md.facets)
        md.paramDefs.each |pd|
        {
          addTypeNames(pd.paramType, names)
          if (pd.def != null) collector.walkExprs([pd.def])
        }
        if (md.ctorChain != null) collector.walkExprs([md.ctorChain])
      }
    }
    return names.keys
  }

  **
  ** Replace the body of every method and field accessor in the unit with
  ** 'stubBody'. Body ranges come from the AST: a MethodDef's code block
  ** starts at its '{' token, and the matching '}' is found by brace depth
  ** over the unit's tokens.
  **
  private static Str replaceBodies(Str source, CompilationUnit unit)
  {
    tokens := unit.tokens
    tokenIdxByPos := Str:Int[:]
    tokens.each |tok, i| { tokenIdxByPos[posKey(tok.line, tok.col)] = i }

    lineStarts := lineStartOffsets(source)
    ranges := Range[,]
    unit.types.each |TypeDef td|
    {
      methods := td.methodDefs.dup
      td.fieldDefs.each |fd|
      {
        if (fd.get != null) methods.add(fd.get)
        if (fd.set != null) methods.add(fd.set)
      }
      methods.each |MethodDef md|
      {
        block := md.code
        if (block == null) return
        startIdx := tokenIdxByPos[posKey(block.loc.line, block.loc.col)]
        if (startIdx == null || tokens[startIdx].kind !== compiler::Token.lbrace) return
        endIdx := matchingBrace(tokens, startIdx)
        if (endIdx == null) return
        start := offsetOf(lineStarts, tokens[startIdx])
        end := offsetOf(lineStarts, tokens[endIdx])
        ranges.add(start..end)
      }
    }

    ranges.sort |a, b| { a.start <=> b.start }
    buf := StrBuf(source.size)
    pos := 0
    ranges.each |r|
    {
      if (r.start < pos) return  // nested in a range already replaced
      buf.add(source[pos ..< r.start]).add(stubBody)
      pos = r.end + 1
    }
    buf.add(source[pos..-1])
    return buf.toStr
  }

  ** Index of the '}' token closing the '{' token at 'startIdx'
  private static Int? matchingBrace(TokenVal[] tokens, Int startIdx)
  {
    depth := 0
    i := startIdx
    while (i < tokens.size)
    {
      kind := tokens[i].kind
      if (kind === compiler::Token.lbrace) depth++
      else if (kind === compiler::Token.rbrace)
      {
        depth--
        if (depth == 0) return i
      }
      i++
    }
    return null
  }

  ** Offsets of the first character of each line (index 0 = line 1)
  private static Int[] lineStartOffsets(Str source)
  {
    starts := [0]
    source.each |ch, i| { if (ch == '\n') starts.add(i + 1) }
    return starts
  }

  ** Source offset of a token (Loc line and col are 1-based)
  private static Int offsetOf(Int[] lineStarts, Loc loc)
  {
    return lineStarts[loc.line - 1] + loc.col - 1
  }

  private static Str posKey(Int? line, Int? col) { "${line}:${col}" }
}

**************************************************************************
** SourceStub
**************************************************************************

**
** A signature-only stub of a source file (see 'SourceStubber').
**
class SourceStub
{
  ** Stub source text
  Str source

  ** Names of the types the compiled part of the stub refers to
  Str[] referencedTypes

  new make(Str source, Str[] referencedTypes)
  {
    this.source = source
    this.referencedTypes = referencedTypes
  }
}

**************************************************************************
** StubTypeNameCollector
**************************************************************************

**
** Collects the type names referenced by parsed (not yet resolved)
** expressions: static targets, type checks, type literals, and the names
** of unresolved variables and calls, which may be types (e.g. 'Foo()').
**
internal class StubTypeNameCollector : Visitor
{
  private Str:Bool names

  new make(Str:Bool names) { this.names = names }

  Void walkFacets(FacetDef[]? facets)
  {
    facets?.each |facet|
    {
      SourceStubber.addTypeNames(facet.type, names)
      walkExprs(facet.vals)
    }
  }

  Void walkExprs(Expr[] exprs)
  {
    exprs.each |expr| { expr.walk(this) }
  }

  override Expr visitExpr(Expr expr)
  {
    if (expr is StaticTargetExpr) SourceStubber.addTypeNames(expr.ctype, names)
    else if (expr is TypeCheckExpr) SourceStubber.addTypeNames(((TypeCheckExpr)expr).check, names)
    else if (expr is LiteralExpr) SourceStubber.addTypeNames(((LiteralExpr)expr).val as CType, names)
    else if (expr is UnknownVarExpr) names[((UnknownVarExpr)expr).name] = true
    else if (expr is CallExpr) names[((CallExpr)expr).name] = true
    return expr
  }
}
