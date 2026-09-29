using compiler

**
** StubbedCompiler - Compiles one source file together with signature-only
** stubs of the other files of its pod (see 'SourceStubber').
**
** The stubs are added as extra compilation units, so project types resolve
** to their real declarations instead of being unknown in single-file mode.
**
** Field initializers of stub types are dropped after parsing: other files
** only need the field types, and the initializers would pull in more types.
**
** Stubs must compile without errors up to expression resolution (see
** 'stubsWithErrs'): the declaration steps bomb before storing their results,
** and later steps assume every expression is resolved, so a stub error there
** would break the analysis of the file itself. Errors and warnings located
** in stub units are dropped after every step and do not stop the pipeline.
** Analysis stops only when the file being analyzed has errors, exactly as
** with a plain single-file compile.
**
class StubbedCompiler : Compiler
{
  ** Front end steps up to expression resolution, in 'Compiler.frontend' order
  private static const Type[] resolveSteps := [
    ResolveDepends#, ScanForUsingsAndTypes#, ResolveImports#, Parse#,
    OrderByInheritance#, CheckInheritance#, Inherit#, DefaultCtor#,
    InitEnum#, InitFacet#, InitClosures#, Normalize#, ResolveExpr#,
  ]

  ** Remaining front end steps, in 'Compiler.frontend' order
  private static const Type[] checkSteps := [
    CheckErrors#, CheckParamDefs#, LocaleProps#, CompileJs#, ClosureVars#,
    ClosureToImmutable#, ConstChecks#,
  ]

  ** Stub sources keyed by file URI (also used as the unit's Loc file)
  private Str:Str stubs

  **
  ** Create a compiler for 'input' (the file being analyzed) plus 'stubs'
  ** keyed by file URI.
  **
  new make(CompilerInput input, Str:Str stubs) : super(input)
  {
    this.stubs = stubs
  }

  **
  ** Run a compiler step, swallowing the CompilerErr thrown by 'bombIfErr'.
  ** Returns true if the step bombed.
  **
  static Bool runTolerant(CompilerStep step)
  {
    try
    {
      step.run
      return false
    }
    catch (CompilerErr e)
    {
      return true
    }
  }

  **
  ** Run the front end, ignoring diagnostics located in stub units.
  **
  override Void frontend()
  {
    try
    {
      tokenizeAll
      (resolveSteps.dup.addAll(checkSteps)).each |Type stepType|
      {
        bombed := runStep(stepType)
        dropStubDiagnostics
        if (bombed && !errs.isEmpty) throw errs.first
      }
    }
    finally
    {
      dropStubDiagnostics
    }
  }

  **
  ** Run the steps up to expression resolution, stopping at the first step
  ** that reports errors. Returns the URIs of the stubs with errors, an
  ** empty list if there are no errors, or null if some errors are not
  ** located in a stub (the stubs cannot be validated).
  **
  Str[]? stubsWithErrs()
  {
    tokenizeAll
    for (i := 0; i < resolveSteps.size; i++)
    {
      runStep(resolveSteps[i])
      if (!errs.isEmpty) break
    }
    files := errs.map |err| { err.loc.file }.unique
    if (files.any |file| { !stubs.containsKey(file) }) return null
    return files
  }

  private Void tokenizeAll()
  {
    InitInput(this).run
    tokenize := Tokenize(this)
    tokenize.run
    stubs.each |src, uri| { tokenize.tokenize(Loc(uri), src) }
  }

  ** Run one step; returns true if it bombed
  private Bool runStep(Type stepType)
  {
    if (stepType == Parse#) return parseUnits
    return runTolerant(stepType.make([this]))
  }

  **
  ** Equivalent of the 'Parse' step, but always stores the parsed types and
  ** closures ('Parse' skips that when it bombs), and a parse-stopping error
  ** in one unit does not prevent parsing the others. Returns true on errors.
  **
  private Bool parseUnits()
  {
    parsed := TypeDef[,]
    closureExprs := ClosureExpr[,]
    pod.units.each |CompilationUnit unit|
    {
      try
        Parser(this, unit, closureExprs).parse
      catch (CompilerErr e) {}
      parsed.addAll(unit.types)
    }
    parsed.each |TypeDef td|
    {
      if (stubs.containsKey(td.loc.file)) td.fieldDefs.each |fd| { fd.init = null }
    }
    types = parsed
    closures = closureExprs
    return !errs.isEmpty
  }

  private Void dropStubDiagnostics()
  {
    errs.removeAll(errs.findAll |err| { stubs.containsKey(err.loc.file) })
    warns.removeAll(warns.findAll |warn| { stubs.containsKey(warn.loc.file) })
  }
}
