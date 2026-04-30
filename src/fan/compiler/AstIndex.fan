
using compiler

**
** AstIndex wraps the Fantom compiler AST to provide a clean,
** LSP-friendly interface. Parses source code, runs the compiler
** frontend, and exposes structured data without leaking compiler internals.
**
class AstIndex
{
  ** All types parsed from the file
  AstType[] types := AstType[,]

  ** All using statements from the file
  AstUsing[] usings := AstUsing[,]

  **
  ** Parse source into an AST index.
  ** Returns null if parsing fails completely.
  **
  static AstIndex? parse(Str fileUri, Str source)
  {
    try
    {
      c := LspCompiler.create(fileUri, source)
      try { c.frontend }
      catch (CompilerErr e) {}
      catch (Err e) { return null }

      if (c.types == null || c.types.isEmpty) return null

      result := AstIndex()

      // Extract using statements from compilation units
      extractUsings(c, result)

      // Walk all types
      for (i := 0; i < c.types.size; i++)
      {
        td := c.types[i]
        if (td.isClosure) continue

        astType := mapTypeDef(td)
        result.types.add(astType)
      }

      // Extract closure params from Compiler.closures (populated during Parse)
      if (c.closures != null)
      {
        c.closures.each |ClosureExpr ce|
        {
          extractClosureParams(ce, result)
        }
      }

      // Fallback: extract closure params from source text for any methods
      // that didn't get them from the AST
      extractClosureParamsFromSource(source, result)

      return result
    }
    catch (Err e) { return null }
  }

  **
  ** Walk a method's code block to find local vars and closure params.
  ** Returns list of AstLocalVar with accurate line info.
  **
  static AstLocalVar[] walkMethodLocals(Block? block, MethodDef method)
  {
    if (block == null) return AstLocalVar[,]
    vars := AstLocalVar[,]
    doWalkBlock(block, method, vars)
    return vars
  }

  // ---- Private: Type mapping ----

  private static AstType mapTypeDef(TypeDef td)
  {
    t := AstType()
    t.name = td.name
    t.line = (td.loc.line ?: 1) - 1
    t.col = (td.loc.col ?: 1) - 1
    t.isEnum = td.isEnum
    t.isMixin = td.isMixin

    // Base type
    if (td.base != null && td.baseSpecified)
      t.baseType = td.base.name

    // Facets
    if (td.facets != null)
    {
      td.facets.each |FacetDef fd|
      {
        t.facets.add(mapFacetDef(fd))
      }
    }

    // Enum values
    td.enumDefs.each |EnumDef ed|
    {
      ev := AstEnumVal()
      ev.name = ed.name
      ev.ordinal = ed.ordinal
      ev.line = (ed.loc.line ?: 1) - 1
      ev.col = (ed.loc.col ?: 1) - 1
      t.enumVals.add(ev)
    }

    // Fields
    td.fieldDefs.each |FieldDef fd|
    {
      if (fd.isSynthetic) return
      slot := AstSlot()
      slot.name = fd.name
      slot.isField = true
      slot.line = (fd.loc.line ?: 1) - 1
      slot.col = (fd.loc.col ?: 1) - 1
      try { slot.typeName = fd.fieldType.name } catch {}
      if (fd.facets != null)
        fd.facets.each |FacetDef fcd| { slot.facets.add(mapFacetDef(fcd)) }
      t.fields.add(slot)
    }

    // Methods
    td.methodDefs.each |MethodDef md|
    {
      if (md.isSynthetic) return
      slot := AstSlot()
      slot.name = md.name
      slot.isField = false
      slot.isCtor = md.isCtor
      slot.isStatic = md.isStatic
      slot.line = (md.loc.line ?: 1) - 1
      slot.col = (md.loc.col ?: 1) - 1
      try { slot.typeName = md.returnType.name } catch {}
      if (md.facets != null)
        md.facets.each |FacetDef fcd| { slot.facets.add(mapFacetDef(fcd)) }

      // Parameters
      md.paramDefs.each |ParamDef pd|
      {
        p := AstParam()
        p.name = pd.name
        p.line = (pd.loc.line ?: 1) - 1
        p.col = (pd.loc.col ?: 1) - 1
        try { p.typeName = pd.paramType.name } catch {}
        slot.params.add(p)
      }

      // Local vars and closure params from method body
      slot.localVars = walkMethodLocals(md.code, md)

      t.methods.add(slot)
    }

    return t
  }

  private static AstFacet mapFacetDef(FacetDef fd)
  {
    f := AstFacet()
    try { f.typeName = fd.type.name } catch { f.typeName = "?" }
    f.line = (fd.loc.line ?: 1) - 1
    f.col = (fd.loc.col ?: 1) - 1
    return f
  }

  // ---- Private: Closure param extraction ----

  private static Void extractClosureParams(ClosureExpr ce, AstIndex result)
  {
    try
    {
      sig := ce.signature
      enclosingTypeName := ce.enclosingType.name

      // Find the enclosing method name
      enclosingMethodName := ce.enclosingSlot.name

      // Find the matching AstType
      astType := result.types.find |t| { t.name == enclosingTypeName }
      if (astType == null) return

      // Find the matching AstSlot method
      astMethod := astType.methods.find |m| { m.name == enclosingMethodName }
      if (astMethod == null) return

      for (pi := 0; pi < sig.names.size; pi++)
      {
        paramName := sig.names[pi]
        if (paramName == "it") continue

        cp := AstLocalVar()
        cp.name = paramName
        cp.isClosureParam = true
        cp.line = (ce.loc.line ?: 1) - 1
        cp.col = (ce.loc.col ?: 1) - 1
        try { cp.typeName = sig.params[pi].name } catch {}

        // Avoid duplicates
        existing := astMethod.localVars.find |v| { v.name == paramName && v.isClosureParam }
        if (existing == null)
          astMethod.localVars.add(cp)
      }
    }
    catch (Err e) {}
  }

  **
  ** Extract closure params from source text using pattern matching.
  ** Detects |param| and |Type param| patterns in method bodies.
  **
  private static Void extractClosureParamsFromSource(Str source, AstIndex result)
  {
    lines := source.splitLines
    for (lineIdx := 0; lineIdx < lines.size; lineIdx++)
    {
      line := lines[lineIdx]
      pipeStart := line.index("|")
      if (pipeStart == null) continue
      // Skip || (logical or)
      if (pipeStart + 1 < line.size && line[pipeStart + 1] == '|') continue

      pipeEnd := line.index("|", pipeStart + 1)
      if (pipeEnd == null) continue
      // Skip || (logical or)
      if (pipeEnd == pipeStart + 1) continue

      // Check this looks like a closure param: something before | like .each, .map etc
      // or a standalone closure
      content := line[pipeStart + 1 ..< pipeEnd].trim
      if (content.isEmpty) continue

      // Parse params from between pipes: |Type name, Type2 name2| or |name| or |name, name2|
      paramParts := content.split(',')
      paramParts.each |part|
      {
        p := part.trim
        if (p.isEmpty) return
        words := p.split(' ').findAll |w| { w.size > 0 }
        if (words.isEmpty) return

        Str? paramName := null
        Str? typeName := null

        if (words.size == 1)
        {
          // |name| pattern
          paramName = words[0]
        }
        else if (words.size >= 2)
        {
          // |Type name| pattern
          typeName = words[0]
          paramName = words[1]
        }

        if (paramName == null || paramName.isEmpty) return
        // Validate identifier
        if (!paramName[0].isAlpha && paramName[0] != '_') return

        // Find enclosing method for this line
        enclosingMethod := null as AstSlot
        enclosingType := null as AstType
        result.types.each |t|
        {
          t.methods.each |m|
          {
            if (m.line <= lineIdx && (enclosingMethod == null || m.line > enclosingMethod.line))
            {
              enclosingMethod = m
              enclosingType = t
            }
          }
        }

        if (enclosingMethod != null)
        {
          // Check if already extracted via AST
          existing := enclosingMethod.localVars.find |v| { v.name == paramName }
          if (existing == null)
          {
            cp := AstLocalVar()
            cp.name = paramName
            cp.isClosureParam = true
            cp.line = lineIdx
            cp.col = pipeStart + 1
            cp.typeName = typeName
            enclosingMethod.localVars.add(cp)
          }
        }
      }
    }
  }

  // ---- Private: Block walking for local vars and closures ----

  private static Void doWalkBlock(Block block, MethodDef method, AstLocalVar[] vars)
  {
    block.stmts.each |Stmt stmt|
    {
      doWalkStmt(stmt, method, vars)
    }
  }

  private static Void doWalkStmt(Stmt stmt, MethodDef method, AstLocalVar[] vars)
  {
    switch (stmt.id)
    {
      case StmtId.localDef:
        lds := (LocalDefStmt)stmt
        lv := AstLocalVar()
        lv.name = lds.name
        lv.line = (lds.loc.line ?: 1) - 1
        lv.col = (lds.loc.col ?: 1) - 1
        // Get type from matching MethodVar
        mv := method.vars.find |v| { v.name == lds.name }
        if (mv != null)
          try { lv.typeName = mv.ctype.name } catch {}
        vars.add(lv)
        // Walk the init expression for closures
        if (lds.init != null)
          walkExprForClosures(lds.init, vars)

      case StmtId.expr:
        es := (ExprStmt)stmt
        walkExprForClosures(es.expr, vars)

      case StmtId.ifStmt:
        is_ := (IfStmt)stmt
        doWalkBlock(is_.trueBlock, method, vars)
        if (is_.falseBlock != null)
          doWalkBlock(is_.falseBlock, method, vars)

      case StmtId.forStmt:
        fs := (ForStmt)stmt
        if (fs.init != null) doWalkStmt(fs.init, method, vars)
        if (fs.block != null) doWalkBlock(fs.block, method, vars)

      case StmtId.whileStmt:
        ws := (WhileStmt)stmt
        doWalkBlock(ws.block, method, vars)

      case StmtId.tryStmt:
        ts := (TryStmt)stmt
        if (ts.block != null) doWalkBlock(ts.block, method, vars)
        ts.catches.each |Catch ca|
        {
          if (ca.errVariable != null)
          {
            cv := AstLocalVar()
            cv.name = ca.errVariable
            cv.line = (ca.loc.line ?: 1) - 1
            cv.col = (ca.loc.col ?: 1) - 1
            if (ca.errType != null)
              try { cv.typeName = ca.errType.name } catch {}
            vars.add(cv)
          }
          if (ca.block != null) doWalkBlock(ca.block, method, vars)
        }
        if (ts.finallyBlock != null) doWalkBlock(ts.finallyBlock, method, vars)

      case StmtId.switchStmt:
        ss := (SwitchStmt)stmt
        ss.cases.each |Case c|
        {
          if (c.block != null) doWalkBlock(c.block, method, vars)
        }
        if (ss.defaultBlock != null) doWalkBlock(ss.defaultBlock, method, vars)
    }
  }

  private static Void walkExprForClosures(Expr expr, AstLocalVar[] vars)
  {
    if (expr.id == ExprId.closure)
    {
      ce := (ClosureExpr)expr
      sig := ce.signature
      for (i := 0; i < sig.names.size; i++)
      {
        cp := AstLocalVar()
        cp.name = sig.names[i]
        cp.isClosureParam = true
        cp.line = (ce.loc.line ?: 1) - 1
        cp.col = (ce.loc.col ?: 1) - 1
        try { cp.typeName = sig.params[i].name } catch {}
        vars.add(cp)
      }
    }
    // Walk child expressions for nested closures
    else if (expr.id == ExprId.call)
    {
      ce := (CallExpr)expr
      if (ce.target != null) walkExprForClosures(ce.target, vars)
      ce.args.each |arg| { walkExprForClosures(arg, vars) }
    }
    else if (expr.id == ExprId.assign)
    {
      be := (BinaryExpr)expr
      walkExprForClosures(be.lhs, vars)
      walkExprForClosures(be.rhs, vars)
    }
    else if (expr.id == ExprId.shortcut)
    {
      se := (ShortcutExpr)expr
      if (se.target != null) walkExprForClosures(se.target, vars)
      se.args.each |arg| { walkExprForClosures(arg, vars) }
    }
  }

  // ---- Private: Using extraction ----

  private static Void extractUsings(Compiler c, AstIndex result)
  {
    try
    {
      // CompilationUnit contains usings
      if (c.pod == null) return
      pod := c.pod as PodDef
      if (pod == null) return
      pod.units.each |CompilationUnit unit|
      {
        unit.usings.each |Using u|
        {
          au := AstUsing()
          au.podName = u.podName
          au.typeName = u.typeName
          au.asName = u.asName
          au.line = (u.loc.line ?: 1) - 1
          au.col = (u.loc.col ?: 1) - 1
          result.usings.add(au)
        }
      }
    }
    catch (Err e) {}
  }
}

**************************************************************************
** AstType
**************************************************************************

class AstType
{
  Str name := ""
  Str? baseType
  Bool isEnum := false
  Bool isMixin := false
  AstSlot[] fields := AstSlot[,]
  AstSlot[] methods := AstSlot[,]
  AstEnumVal[] enumVals := AstEnumVal[,]
  AstFacet[] facets := AstFacet[,]
  Int line := 0
  Int col := 0
}

**************************************************************************
** AstSlot
**************************************************************************

class AstSlot
{
  Str name := ""
  Str? typeName
  Bool isField := false
  Bool isCtor := false
  Bool isStatic := false
  AstParam[] params := AstParam[,]
  AstFacet[] facets := AstFacet[,]
  AstLocalVar[] localVars := AstLocalVar[,]
  Int line := 0
  Int col := 0
}

**************************************************************************
** AstParam
**************************************************************************

class AstParam
{
  Str name := ""
  Str? typeName
  Int line := 0
  Int col := 0
}

**************************************************************************
** AstEnumVal
**************************************************************************

class AstEnumVal
{
  Str name := ""
  Int ordinal := 0
  Int line := 0
  Int col := 0
}

**************************************************************************
** AstFacet
**************************************************************************

class AstFacet
{
  Str typeName := ""
  Int line := 0
  Int col := 0
}

**************************************************************************
** AstUsing
**************************************************************************

class AstUsing
{
  Str podName := ""
  Str? typeName
  Str? asName
  Int line := 0
  Int col := 0
}

**************************************************************************
** AstLocalVar
**************************************************************************

class AstLocalVar
{
  Str name := ""
  Str? typeName
  Bool isClosureParam := false
  Int line := 0
  Int col := 0
}
