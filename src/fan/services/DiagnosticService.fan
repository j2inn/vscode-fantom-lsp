
using compiler

**
** DiagnosticService - Syntax error detection using the Fantom compiler.
** Single-file analysis for real-time feedback during editing.
** Filters only false positives that are provably caused by single-file
** compilation (the referenced type exists in the ProjectIndex).
** Workspace-wide diagnostics are handled by ProjectIndex.buildAndCollectDiagnostics().
**
class DiagnosticService
{
  ** Types resolved from external pods during base type replacement.
  ** These may not be in the current file's 'using' statements, so the
  ** compiler can't resolve them — but they're not real errors.
  private Str[] resolvedExternalBaseTypes := Str[,]

  ** Types whose direct base was an unresolvable external type (not a project
  ** type and not in any loadable using pod). When a class extends such a type
  ** (e.g., HaystackTest, AbstractModel), ALL inherited method calls are
  ** potential false positives — not just this./super. ones.
  private Str[] typesWithExternalBase := Str[,]

  ** Index of types loaded from using pods for the current analysis pass.
  ** Rebuilt only when the set of using pods changes (fingerprint cache).
  private UsingPodIndex usingPodIdx := UsingPodIndex()

  ** Fingerprint of the using statements that produced usingPodIdx
  private Str? usingPodFingerprint := null

  ** Validation collaborators (moved to dedicated files under services/diagnostic)
  private DiagnosticCrossFileValidator crossFileValidator := DiagnosticCrossFileValidator()
  private DiagnosticMethodParamValidator methodParamValidator := DiagnosticMethodParamValidator()
  private DiagnosticUnusedUsingValidator unusedUsingValidator := DiagnosticUnusedUsingValidator()
  private DiagnosticPedanticValidator pedanticValidator := DiagnosticPedanticValidator()
  private DiagnosticNullableUsageValidator nullableUsageValidator := DiagnosticNullableUsageValidator()
  private DiagnosticUnusedVarValidator unusedVarValidator := DiagnosticUnusedVarValidator()
  private DiagnosticDuplicateConstValidator duplicateConstValidator := DiagnosticDuplicateConstValidator()
  private DiagnosticConstInitValidator constInitValidator := DiagnosticConstInitValidator()
  **
  ** Analyze source code and return diagnostics for a single file.
  ** Filters errors about types/variables that exist in the project index,
  ** since those are false positives from single-file compilation.
  **
  LspDiagnostic[] analyze(Str uri, Str source, ProjectIndex index, Bool pedanticMode := false, Bool enableUnusedImport := true)
  {
    request := DiagnosticAnalyzeRequestBuilder()
      .withUri(uri)
      .withSource(source)
      .withIndex(index)
      .withPedanticMode(pedanticMode)
      .withEnableUnusedImport(enableUnusedImport)
      .build

    return analyzeRequest(request)
  }

  **
  ** Analyze source code using a builder-created request object.
  **
  LspDiagnostic[] analyzeRequest(DiagnosticAnalyzeRequest request)
  {
    uri := request.uri
    source := request.source
    index := request.index
    pedanticMode := request.pedanticMode
    enableUnusedImport := request.enableUnusedImport

    diagnostics := LspDiagnostic[,]

    // Reset per-analysis state
    resolvedExternalBaseTypes = Str[,]
    typesWithExternalBase = Str[,]
    // Rebuild using-pod index only when the set of using pods has changed.
    fp := UsingPodIndex.fingerprintFor(source)
    if (fp != usingPodFingerprint)
    {
      usingPodIdx = UsingPodIndex.fromSource(source)
      usingPodFingerprint = fp
    }

    // Preprocess: replace project-type literals and base types.
    // If preprocessing fails, fall back to original source.
    preprocessed := source
    try
    {
      preprocessed = replaceProjectTypeLiterals(source, index)
      preprocessed = replaceProjectBaseTypes(preprocessed, index)
      preprocessed = stripUnresolvableFacets(preprocessed, index)
      preprocessed = replaceProjectTypeNames(preprocessed, index)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Preprocessing error (using original source): $e")
      preprocessed = source
    }

    // Extract base types from original source BEFORE preprocessing,
    // so we know which project types the classes extend. This lets us
    // filter "Unknown variable" errors for inherited members.
    baseTypes := extractBaseTypes(source, index)

    // Compile and collect errors. Isolated so a compiler crash
    // doesn't prevent cross-file and param validation from running.
    try
    {
      compiler := LspCompiler.create(uri, preprocessed)
      LspCompiler.analyze(compiler)

      lines := preprocessed.splitLines

      compiler.errs.each |err|
      {
        if (!isProjectTypeFalsePositive(err, index, lines, baseTypes))
        {
          // "Ambiguous type" — downgrade to warning since single-file
          // compilation can't resolve which 'using' pod to pick, but
          // full pod compilation resolves it correctly.
          severity := err.msg.startsWith("Ambiguous type")
            ? DiagnosticSeverity.warning : DiagnosticSeverity.error
          range := LspUtil.locToRange(err.loc)
          diagnostics.add(LspDiagnostic(range, severity, err.msg, "fantom"))
        }
      }

      compiler.warns.each |warn|
      {
        if (!isProjectTypeFalsePositive(warn, index, lines, baseTypes))
        {
          range := LspUtil.locToRange(warn.loc)
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.warning, warn.msg, "fantom"))
        }
      }
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Compiler error: $e")
    }

    // Cross-file reference validation: check that ProjectType.member
    // references point to members that actually exist in the index.
    try
    {
      crossFileErrs := crossFileValidator.validateCrossFileReferences(source, index)
      diagnostics.addAll(crossFileErrs)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Cross-file validation error: $e")
    }

    // Method parameter validation: check that method calls on known types
    // have the correct number of arguments.
    try
    {
      paramErrs := methodParamValidator.validateMethodParams(source, index)
      diagnostics.addAll(paramErrs)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Method param validation error: $e")
    }

    // Unused 'using' imports: warn on specific type imports that are never referenced
    // Gated by enableUnusedImport (default true, disabled via fan.config.json)
    if (enableUnusedImport)
    {
      try
      {
        unusedDiags := unusedUsingValidator.checkUnusedUsings(source)
        diagnostics.addAll(unusedDiags)
      }
      catch (Err e)
      {
        LspProtocol.logInfo("Unused using check error: $e")
      }
    }

    // Pedantic mode: warn on untyped := declarations
    if (pedanticMode)
    {
      try
      {
        pedanticDiags := pedanticValidator.checkUntypedDeclarations(source)
        diagnostics.addAll(pedanticDiags)
      }
      catch (Err e)
      {
        LspProtocol.logInfo("Pedantic mode error: $e")
      }
    }

    // Unused variable / private field check
    try
    {
      unusedDiags := unusedVarValidator.checkUnusedVars(source)
      diagnostics.addAll(unusedDiags)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Unused var check error: $e")
    }

    // Nullable usage check: warn when a nullable variable is used without a null guard
    try
    {
      nullableDiags := nullableUsageValidator.checkNullableUsage(source)
      diagnostics.addAll(nullableDiags)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Nullable usage check error: $e")
    }

    // Cross-class const static initializer check: warn when a const static field
    // is initialized from another class's field, which may not be loaded yet
    try
    {
      constInitDiags := constInitValidator.checkCrossClassConstInit(source)
      diagnostics.addAll(constInitDiags)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Const init check error: $e")
    }

    return diagnostics
  }

  **
  ** Check if a compiler error is a false positive caused by single-file
  ** compilation not seeing a type that exists in another project file.
  ** Only filters when we can positively verify the name in the ProjectIndex.
  **
  private Bool isProjectTypeFalsePositive(CompilerErr err, ProjectIndex index, Str[] lines, Str[] baseTypes := Str[,])
  {
    msg := err.msg

    // "Unknown variable 'TypeName'" — happens when a project type is used
    // for static method calls (e.g., MyClass.doSomething()) and the compiler
    // can't resolve it in single-file mode.
    if (msg.startsWith("Unknown variable"))
    {
      name := extractQuotedName(msg)
      if (name != null && index.hasType(name)) return true
      // Filter static calls on external pod types (e.g., Context.cur, Pod.find)
      if (name != null && usingPodIdx.hasType(name)) return true

      // Also filter inherited members: when the class extends a project type
      // that was replaced with Obj, inherited fields/constants become unknown.
      // E.g., class Foo : IBacnetServer { ... DEVICE_TAG ... }
      // DEVICE_TAG is inherited from IBacnetServer but invisible after replacement.
      if (name != null && isInheritedMember(name, baseTypes, index)) return true

      // It-block field assignment: when a project type constructor is replaced
      // with Obj, fields set in it-blocks become "Unknown variable".
      // E.g., ChartSeriesProps(...) { dis = "hello" } → Obj(...) { dis = "hello" }
      // Filter when the variable name is a field of any project type and the
      // source line looks like an it-block assignment (name = expr, no :=).
      if (name != null)
      {
        lineIdx := (err.loc.line ?: 1) - 1
        if (lineIdx >= 0 && lineIdx < lines.size)
        {
          errLine := lines[lineIdx].trim
          // It-block pattern: "name = expr" (no := , starts with the field name)
          if (errLine.startsWith("${name} =") || errLine.startsWith("${name}="))
          {
            // Check it's not a := declaration
            if (!errLine.contains(":="))
            {
              // Check if any project type has this as a field
              syms := index.findSymbols(name)
              if (syms.any |s| { s.kind == SymbolKind.field })
                return true
            }
          }
        }
      }
    }

    // "Unknown type 'TypeName'" — the type exists in another project file
    // but single-file compilation can't see it. This includes type literal
    // errors like "Unknown type 'Foo' for type literal" (e.g., Foo#.pod).
    // Although type literal errors are parse-stopping, they are still false
    // positives when the type exists in the project.
    // Also filter types that were substituted in as resolved base types
    // from external pods (e.g., ExtendableModel) — these may not be in
    // the current file's 'using' statements.
    if (msg.startsWith("Unknown type"))
    {
      name := extractQuotedName(msg)
      if (name != null && index.hasType(name)) return true
      if (name != null && resolvedExternalBaseTypes.contains(name)) return true
      // Also filter types that are in a loadable using pod.  These are valid
      // types that the single-file compiler may fail to resolve due to pod
      // loading differences between reflection and compilation context.
      if (name != null && usingPodIdx.hasType(name)) return true
    }

    // "Unknown method/slot/field 'pod::Type.slotName'" — multiple causes:
    // 1. Constructor call: BacnetServer(cx, siteId) where BacnetServer is a project type
    // 2. Inherited slot: this.commit() or this.entityId where the base type was
    //    replaced with Obj during preprocessing, hiding inherited slots.
    //    The error format is "Unknown method/slot/field 'pod::CurrentClass.slotName'"
    //    when the slot is accessed on 'this' or 'super' but inherited from a replaced base.
    if (msg.startsWith("Unknown method") || msg.startsWith("Unknown slot") ||
        msg.startsWith("Unknown field"))
    {
      name := extractQuotedName(msg)
      if (name != null)
      {
        // Extract the method name after the last dot: "pod::Type.Method" → "Method"
        dotIdx := name.indexr(".")
        methodName := dotIdx != null ? name[dotIdx + 1 ..-1] : name

        // Case 1: Constructor call — method name is an uppercase project type
        if (methodName.size > 0 && methodName[0].isUpper && index.hasType(methodName))
          return true

        // Case 2: Inherited method from project base type replaced with Obj.
        // When the class extends a project type that was replaced, inherited
        // methods like commit() become invisible. Filter when the method
        // exists as a member of any project base type in the chain.
        if (methodName.size > 0 && isInheritedMember(methodName, baseTypes, index))
          return true

        // Case 3: Inherited method called via this.method() or super.method().
        // When a project base type extends an external type (e.g., ExtendableModel)
        // that isn't resolvable in single-file mode, the base is replaced with Obj.
        // Methods inherited from the external type (e.g., commit()) become invisible.
        //
        // Sub-case 3a: source line has this.method() or super.method() — always filter.
        // Sub-case 3b: bare method() call and the class directly extends an unresolvable
        //   external type (not a project type). External base types can have arbitrary
        //   inherited methods (e.g., HaystackTest.verifyDictEq), so bare calls are
        //   also false positives in that case.
        if (methodName.size > 0 && dotIdx != null && methodName[0].isLower)
        {
          qualType := name[0 ..< dotIdx]
          colonIdx := qualType.indexr("::")
          typeName := colonIdx != null ? qualType[colonIdx + 2 ..-1] : qualType
          if (typeName.size > 0 && isTypeWithReplacedBase(typeName, lines))
          {
            // Sub-case 3b: class directly extends an unresolvable external type
            if (typesWithExternalBase.contains(typeName))
              return true

            // Sub-case 3a: this.method() or super.method() call
            lineIdx := (err.loc.line ?: 1) - 1
            if (lineIdx >= 0 && lineIdx < lines.size)
            {
              errLine := lines[lineIdx]
              if (errLine.contains("this.${methodName}") ||
                  errLine.contains("super.${methodName}"))
                return true
            }
          }
        }
      }
    }

    // "No constructor found: Foo(sys::Error, ...)" — when argument types
    // can't be resolved in single-file mode, the compiler collapses them
    // to sys::Error, causing constructor lookup to fail. The presence of
    // sys::Error in the signature indicates unresolved types.
    if (msg.startsWith("No constructor found") && msg.contains("sys::Error"))
      return true

    // "No constructor found: Obj(...)" — when project types are replaced
    // with Obj during preprocessing, constructor calls like BacnetServer(cx, siteId)
    // become Obj(cx, siteId). The compiler can't find a matching Obj constructor.
    if (msg.startsWith("No constructor found") && msg.contains("Obj("))
      return true

    // "Internal method/field pod::Type.slot not accessible" — in single-file
    // (script) mode the code is not compiled as part of its real pod, so
    // internal members from 'using' pods that are accessible in full pod
    // compilation appear inaccessible.
    if (msg.contains("not accessible") &&
        (msg.startsWith("Internal method") || msg.startsWith("Internal field")))
      return true

    // "Java package '...' not found" — Java FFI packages can't be resolved
    // in single-file compilation mode. These are always false positives.
    if (msg.startsWith("Java package") && msg.endsWith("not found"))
      return true

    // "Expected ',', not ':'" — cascade error from Map type constructors
    // like Map(Ref:IntesisDeviceData#) when types aren't resolved in
    // single-file mode. Only filter when ALL types in the Map() are known
    // (sys types or in the project index).
    if (msg == "Expected ',', not ':'")
      return isMapConstructorWithKnownTypes(err, index, lines)

    // "Expected ',', not '::'" — happens when code uses pod-qualified type
    // syntax like podName::TypeName (e.g., myPod::Main.CONST). The compiler
    // in single-file mode can't resolve the pod name and treats '::' as
    // an unexpected token. Filter when the source line contains '::'.
    if (msg == "Expected ',', not '::'")
    {
      lineIdx := (err.loc.line ?: 1) - 1
      if (lineIdx >= 0 && lineIdx < lines.size && lines[lineIdx].contains("::"))
        return true
    }

    // Errors referencing sys::Obj slots — caused by replacing project type
    // names with Obj during preprocessing. E.g., ProjectType.staticMethod()
    // becomes Obj.staticMethod() which generates "Unknown method 'sys::Obj.staticMethod'".
    if (msg.contains("sys::Obj.") &&
        (msg.startsWith("Unknown method") || msg.startsWith("Unknown slot") ||
         msg.startsWith("Unknown field")))
      return true

    // "Not a facet type 'sys::Obj'" — when facets from external pods
    // (e.g., @RequiredField, @Min, @Max) can't be resolved in single-file
    // mode, the compiler maps them to sys::Obj. Obj is not a facet type,
    // so this error is always a false positive from unresolvable external facets.
    if (msg == "Not a facet type 'sys::Obj'")
      return true

    // "Unknown facet field 'sys::Obj.fieldName'" — companion to the above.
    // When an unresolvable facet has an inline body { field = val }, the
    // field access fails because sys::Obj has no such field.
    if (msg.startsWith("Unknown facet field") && msg.contains("sys::Obj"))
      return true

    // "Duplicate facet sys::Obj" — when multiple facets from external pods
    // (e.g., @RequiredField, @Min, @Max) can't be resolved in single-file
    // mode, they all collapse to sys::Obj, causing duplicate facet errors.
    if (msg == "Duplicate facet 'sys::Obj'")
      return true

    // "No operator method found: sys::Obj..." — when closure params or
    // variables are typed as Obj/Obj? due to unresolvable return types
    // from project type methods, operators like [] become invalid.
    if (msg.startsWith("No operator method found") && msg.contains("sys::Obj"))
      return true

    // "Override of unknown virtual slot 'slotName'" — when a class extends
    // a project type that is replaced with Obj during preprocessing, the
    // compiler can't find the virtual slot being overridden. Filter when
    // any project type in the index has that member.
    if (msg.startsWith("Override of unknown virtual slot"))
    {
      name := extractQuotedName(msg)
      if (name != null)
      {
        // Check if any project type has this member (method or field)
        syms := index.findSymbols(name)
        if (syms.any |s| { s.kind == SymbolKind.method || s.kind == SymbolKind.field })
          return true
      }
    }

    return false
  }

  **
  ** Check if an "Expected ',', not ':'" error is on a Map constructor line
  ** where all referenced types are known (sys types or in the project index).
  ** E.g., Map(Ref:IntesisDeviceData#) — filter only if both types are known.
  **
  private Bool isMapConstructorWithKnownTypes(CompilerErr err, ProjectIndex index, Str[] lines)
  {
    // Get the source line (CompilerErr lines are 1-based)
    lineIdx := err.loc.line - 1
    if (lineIdx < 0 || lineIdx >= lines.size) return false
    line := lines[lineIdx].trim

    // Find Map( pattern and extract the type parameters
    mapIdx := line.index("Map(")
    if (mapIdx == null) return false

    // Extract content inside Map(...)
    start := mapIdx + 4
    end := line.index(")", start)
    if (end == null) return false
    inner := line[start ..< end]

    // Split on ':' to get key and value types
    colonIdx := inner.index(":")
    if (colonIdx == null) return false

    keyType := inner[0 ..< colonIdx].trim
    valType := inner[colonIdx + 1 .. -1].trim
    // Strip trailing # from type literals
    if (valType.endsWith("#")) valType = valType[0 ..< valType.size - 1]
    if (keyType.endsWith("#")) keyType = keyType[0 ..< keyType.size - 1]

    return isKnownType(keyType, index) && isKnownType(valType, index)
  }

  ** Well-known sys types that the single-file compiler can always resolve
  private static const Str[] knownSysTypes := [
    "Obj", "Bool", "Int", "Float", "Decimal", "Str", "Uri", "Type",
    "List", "Map", "Range", "Duration", "DateTime", "Date", "Time",
    "Buf", "InStream", "OutStream", "File", "Err", "Void", "Num",
    "Ref", "Dict", "Grid", "Slot", "Field", "Method", "Pod", "Enum"
  ]

  **
  ** Check if a type is resolvable by the single-file compiler.
  ** Looks in the sys pod and any pods referenced by 'using' statements.
  **
  private Bool isTypeResolvableInSource(Str typeName, Str source)
  {
    // Check sys pod first (always available)
    sysPod := Pod.find("sys", false)
    if (sysPod?.type(typeName, false) != null) return true

    // Extract using pod names and check each
    lines := source.splitLines
    for (i := 0; i < lines.size; i++)
    {
      line := lines[i].trim
      if (!line.startsWith("using ")) continue
      // Skip Java FFI usings
      if (line.contains("[java]")) continue

      // "using podName" or "using podName::TypeName"
      rest := line["using ".size ..-1].trim
      podName := rest
      colonIdx := rest.index("::")
      if (colonIdx != null) podName = rest[0 ..< colonIdx]

      pod := Pod.find(podName, false)
      if (pod?.type(typeName, false) != null) return true
    }
    return false
  }

  ** Check if a type name is known (sys type or in the project index)
  private Bool isKnownType(Str name, ProjectIndex index)
  {
    if (knownSysTypes.contains(name)) return true
    return index.hasType(name)
  }

  **
  ** Return true if the character at 'pos' in 'line' is inside a string literal.
  ** Counts unescaped '"' characters before 'pos'; an odd count means we are
  ** currently inside a string (e.g. the class/mixin keyword found was part of
  ** a string value, not a real declaration).
  **
  private Bool isInsideStringLiteral(Str line, Int pos)
  {
    count := 0
    i := 0
    while (i < pos && i < line.size)
    {
      ch := line[i]
      if (ch == '\\')
      {
        i += 2  // skip escape sequence (e.g. \" \n \\)
        continue
      }
      if (ch == '"') count++
      i++
    }
    return count % 2 != 0
  }

  **
  ** Extract a name from single quotes in an error message.
  ** E.g., "Unknown type 'Logger'" -> "Logger"
  **
  private Str? extractQuotedName(Str msg)
  {
    startIdx := msg.index("'")
    if (startIdx == null) return null
    endIdx := msg.index("'", startIdx + 1)
    if (endIdx == null) return null
    return msg[startIdx + 1 ..< endIdx]
  }

  **
  ** Replace project-type literals (TypeName#) with Obj# in source code.
  ** Type literals like `MyClass#.pod` cause parse-stopping errors in
  ** single-file compilation when MyClass is from another file. Replacing
  ** known project types with Obj# lets the compiler parse past them.
  **
  private Str replaceProjectTypeLiterals(Str source, ProjectIndex index)
  {
    lines := source.splitLines
    changed := false
    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      newLine := replaceTypeLiteralsInLine(line, index)
      if (newLine != line)
      {
        lines[i] = newLine
        changed = true
      }
    }
    return changed ? lines.join("\n") : source
  }

  **
  ** Replace TypeName# patterns in a single line where TypeName is a project type.
  **
  private Str replaceTypeLiteralsInLine(Str line, ProjectIndex index)
  {
    // Scan for # characters and check if preceded by a type name
    hashIdx := line.index("#")
    if (hashIdx == null || hashIdx == 0) return line

    result := StrBuf(line.size)
    pos := 0
    while (hashIdx != null && hashIdx > 0)
    {
      // Walk backwards from # to find the type name
      nameStart := hashIdx - 1
      while (nameStart >= 0 && (line[nameStart].isAlphaNum || line[nameStart] == '_'))
        nameStart--
      nameStart++

      typeName := nameStart < hashIdx ? line[nameStart ..< hashIdx] : ""

      if (typeName.size > 0 && typeName[0].isUpper && index.hasType(typeName))
      {
        // Append everything before the type name, then "Obj#"
        result.add(line[pos ..< nameStart])
        result.add("Obj#")
      }
      else
      {
        // No replacement — append up to and including #
        result.add(line[pos .. hashIdx])
      }
      pos = hashIdx + 1

      // Find next #
      hashIdx = pos < line.size ? line.index("#", pos) : null
    }

    // Append remainder
    if (pos < line.size)
      result.add(line[pos ..-1])

    return result.toStr
  }

  **
  ** Strip facet annotations whose type can't be resolved in single-file mode.
  ** External facets like @RequiredField, @Min, @Max from dependency pods
  ** are unresolvable and the compiler collapses them to sys::Obj, causing
  ** "Not a facet type 'sys::Obj'" and "Duplicate facet 'sys::Obj'" errors.
  ** We remove the entire annotation (including any { ... } body) so the
  ** compiler never sees them.
  **
  private Str stripUnresolvableFacets(Str source, ProjectIndex index)
  {
    lines := source.splitLines
    changed := false
    i := 0
    while (i < lines.size)
    {
      line := lines[i]
      trimmed := line.trim

      // Detect facet annotation: line starts with @TypeName
      if (trimmed.size > 1 && trimmed[0] == '@' && trimmed[1].isUpper)
      {
        // Extract the facet type name
        nameStart := 1
        nameEnd := nameStart
        while (nameEnd < trimmed.size && (trimmed[nameEnd].isAlphaNum || trimmed[nameEnd] == '_'))
          nameEnd++
        facetName := trimmed[nameStart ..< nameEnd]

        // Check if this facet type is resolvable from any loaded using pod
        if (facetName.size > 0 && !usingPodIdx.hasType(facetName) && !index.hasType(facetName))
        {
          LspProtocol.logInfo("Stripping unresolvable facet: @${facetName}")

          // Check if the facet has a body: @Facet { ... }
          // The body may span multiple lines
          rest := trimmed[nameEnd ..-1].trim
          if (rest.startsWith("{"))
          {
            // Find the closing brace — may be on this line or subsequent lines
            braceCount := 0
            found := false
            j := i
            while (j < lines.size)
            {
              scanLine := j == i ? rest : lines[j]
              for (c := 0; c < scanLine.size; c++)
              {
                if (scanLine[c] == '{') braceCount++
                else if (scanLine[c] == '}')
                {
                  braceCount--
                  if (braceCount == 0) { found = true; break }
                }
              }
              if (found) { j++; break }
              j++
            }
            // Remove lines i through j-1
            for (k := i; k < j && k < lines.size; k++)
            {
              lines[k] = ""
              changed = true
            }
            i = j
          }
          else
          {
            // Simple facet with no body: @FacetName
            lines[i] = ""
            changed = true
            i++
          }
          continue
        }
      }
      i++
    }
    return changed ? lines.join("\n") : source
  }

  **
  ** Record types in the source whose base class is an unresolvable external type.
  ** Called once per line before base-type replacement so we have the original names.
  **
  private Void trackExternalBaseTypes(Str line, ProjectIndex index)
  {
    trimmed := line.trim
    classIdx := trimmed.index("class ")
    mixinIdx := trimmed.index("mixin ")
    if (classIdx == null && mixinIdx == null) return

    keywordPos := classIdx ?: mixinIdx
    // Skip lines where the keyword is inside a string literal
    // (e.g. "class Build : BuildPod\n..." written as a string value)
    if (isInsideStringLiteral(trimmed, keywordPos)) return
    colonIdx := trimmed.index(":", keywordPos + 6)
    if (colonIdx == null) return
    if (colonIdx + 1 < trimmed.size && trimmed[colonIdx + 1] == '=') return

    // Extract the declared type name
    afterKeyword := trimmed[keywordPos + 6 ..-1].trim
    nameEnd := 0
    while (nameEnd < afterKeyword.size &&
           (afterKeyword[nameEnd].isAlphaNum || afterKeyword[nameEnd] == '_'))
      nameEnd++
    className := afterKeyword[0 ..< nameEnd]
    if (className.isEmpty) return

    // Parse base types (part after the colon)
    afterColon := trimmed[colonIdx + 1 ..-1].trim
    if (afterColon.endsWith("{"))
      afterColon = afterColon[0 ..< afterColon.size - 1].trim

    // If any base is an unresolvable external type, record the class name
    parts := afterColon.split(',')
    parts.each |part|
    {
      name := part.trim
      isUnresolvableExternal := name.size > 0 && name[0].isUpper &&
                                !knownSysTypes.contains(name) && !index.hasType(name) &&
                                !usingPodIdx.hasType(name)
      if (isUnresolvableExternal && !typesWithExternalBase.contains(className))
        typesWithExternalBase.add(className)
    }
  }

  **
  ** Replace project types in class/mixin inheritance clauses with Obj.
  ** When a class extends a project type that the single-file compiler
  ** can't resolve, the compiler stops and never checks method bodies.
  ** Replacing with Obj lets the compiler proceed and detect real errors
  ** like undeclared variables and methods.
  **
  private Str replaceProjectBaseTypes(Str source, ProjectIndex index)
  {
    lines := source.splitLines
    changed := false
    replacedWithObj := false
    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      // Track which types have unresolvable external bases before replacement
      trackExternalBaseTypes(line, index)
      newLine := replaceBaseTypesInLine(line, index)
      if (newLine != line)
      {
        lines[i] = newLine
        changed = true
        // Check if the replacement resulted in ": Obj"
        t := newLine.trim
        ci := t.index("class ")
        if (ci != null)
        {
          colon := t.index(":", ci + 6)
          if (colon != null)
          {
            after := t[colon + 1 ..-1].trim
            if (after.startsWith("Obj") &&
                (after.size == 3 || after[3] == ' ' || after[3] == '{'))
              replacedWithObj = true
          }
        }
      }
    }

    // When a base type was replaced with Obj, also strip super constructor
    // arguments. Obj.make() takes no args, so ": super(x, y)" must become
    // ": super()" to avoid "Invalid args make()" errors.
    if (replacedWithObj)
    {
      for (i := 0; i < lines.size; i++)
      {
        newLine := replaceSuperCtorArgs(lines[i])
        if (newLine != lines[i])
        {
          lines[i] = newLine
          changed = true
        }
      }
    }

    return changed ? lines.join("\n") : source
  }

  **
  ** Replace ": super(...)" with ": super()" in a constructor line.
  ** Handles both inline "new make(...) : super(args) {" and multiline forms.
  **
  private Str replaceSuperCtorArgs(Str line)
  {
    // Look for ": super(" or ":super(" pattern (constructor chaining)
    // Also handle "super(" at the start of a line for multiline constructors
    superIdx := line.index("super(")
    if (superIdx == null) return line

    // Verify it's a constructor chain (preceded by : ) or a super.make call
    // Check for ": super(" or ":super("
    isCtorChain := false
    if (superIdx > 0)
    {
      // Walk backwards past whitespace to find ':'
      j := superIdx - 1
      while (j >= 0 && line[j].isSpace) j--
      if (j >= 0 && line[j] == ':') isCtorChain = true
    }

    if (!isCtorChain) return line

    // Find matching closing paren
    openParen := superIdx + 5  // position of '('
    closeParen := findMatchingParen(line, openParen)
    if (closeParen == null) return line

    // Replace super(args) with super()
    return line[0 .. openParen] + ")" + line[closeParen + 1 ..-1]
  }

  **
  ** Find the matching closing parenthesis, handling nesting.
  **
  private Int? findMatchingParen(Str line, Int openPos)
  {
    depth := 0
    inStr := false
    for (i := openPos; i < line.size; i++)
    {
      ch := line[i]
      if (ch == '"' && !inStr) inStr = true
      else if (ch == '"' && inStr) inStr = false
      else if (ch == '\\' && inStr) { i++; continue }
      if (!inStr)
      {
        if (ch == '(' || ch == '[') depth++
        else if (ch == ')' || ch == ']') { depth--; if (depth == 0) return i }
      }
    }
    return null
  }

  **
  ** Replace project types in a single inheritance line.
  ** "class Foo : ProjectBase {" → "class Foo : Obj {"
  **
  private Str replaceBaseTypesInLine(Str line, ProjectIndex index)
  {
    trimmed := line.trim

    // Must be a class or mixin declaration with inheritance
    classIdx := trimmed.index("class ")
    mixinIdx := trimmed.index("mixin ")
    if (classIdx == null && mixinIdx == null) return line

    isMixin := mixinIdx != null && (classIdx == null || mixinIdx < classIdx)
    keywordPos := classIdx ?: mixinIdx
    keywordLen := 6  // "class " and "mixin " are both 6 chars

    // Skip lines where the keyword is inside a string literal
    // (e.g. "class Build : BuildPod\n..." written as a string value).
    // Without this guard the closing quote would be dropped, leaving an
    // unterminated string that causes "Leading space in multi-line Str" errors.
    if (isInsideStringLiteral(trimmed, keywordPos)) return line

    // Find the colon after the class/mixin name
    colonIdx := trimmed.index(":", keywordPos + keywordLen)
    if (colonIdx == null) return line

    // Make sure it's " : " (inheritance), not ":=" (walrus operator)
    if (colonIdx + 1 < trimmed.size && trimmed[colonIdx + 1] == '=') return line

    // Get the part after the colon
    afterColon := trimmed[colonIdx + 1 ..-1].trim

    // Remove trailing { if present
    braceTrail := ""
    if (afterColon.endsWith("{"))
    {
      braceTrail = " {"
      afterColon = afterColon[0 ..< afterColon.size - 1].trim
    }

    // Split by comma for multiple base types
    parts := afterColon.split(',')
    anyReplaced := false

    newParts := Str[,]
    parts.each |part|
    {
      name := part.trim
      // Replace if:
      //   a) it's a project type (index.hasType) — substitute with the
      //      best resolvable ancestor so the compiler keeps inherited members, OR
      //   b) it's an external type not found in any loadable using pod
      //      (unloadable pod type) — substitute with Obj to prevent
      //      "Unknown type" compiler errors that stop method-body analysis.
      isProjectType := name.size > 0 && name[0].isUpper &&
                       !knownSysTypes.contains(name) && index.hasType(name)
      isUnresolvableExternal := name.size > 0 && name[0].isUpper &&
                                !knownSysTypes.contains(name) && !index.hasType(name) &&
                                !usingPodIdx.hasType(name)
      if (isProjectType || isUnresolvableExternal)
      {
        anyReplaced = true
        // For project types: look up the best resolvable ancestor
        resolved := isProjectType ? index.findResolvableBaseType(name) : null
        if (resolved != null && !knownSysTypes.contains(resolved))
        {
          // The resolved ancestor is from an external pod. Keep it only if
          // the single-file compiler can also find it (i.e., it's in a
          // loadable using pod).  Otherwise fall back to Obj.
          resolvedExternalBaseTypes.add(resolved)
          if (!usingPodIdx.hasType(resolved))
            resolved = null  // fall back to Obj
        }

        // For mixins, don't replace with Obj — mixins can't extend classes.
        // Instead, drop the unresolvable base type entirely.
        fallback := resolved ?: "Obj"
        if (isMixin && fallback == "Obj")
          {} // skip — don't add Obj as a mixin base type
        else
          newParts.add(fallback)
      }
      else
      {
        newParts.add(name)
      }
    }

    if (!anyReplaced) return line

    // Deduplicate: "Obj, Obj" from multiple replaced types causes
    // "cannot mixin class sys::Obj". Keep only the first Obj.
    seenObj := false
    deduped := Str[,]
    newParts.each |p|
    {
      if (p == "Obj")
      {
        if (!seenObj) { deduped.add(p); seenObj = true }
      }
      else deduped.add(p)
    }
    newParts = deduped

    // Reconstruct preserving leading whitespace
    indent := StrBuf()
    for (j := 0; j < line.size; j++)
    {
      if (line[j].isSpace) indent.addChar(line[j])
      else break
    }

    // If all base types were dropped (mixin case), remove the colon entirely
    if (newParts.isEmpty)
    {
      beforeColon := trimmed[0 ..< colonIdx].trimEnd
      return "${indent}${beforeColon}${braceTrail}"
    }

    beforeColon := trimmed[0 .. colonIdx]
    joined := newParts.join(", ")
    return "${indent}${beforeColon} ${joined}${braceTrail}"
  }

  **
  ** Replace project type names throughout the source with Obj.
  ** When a file references types from the same pod,
  ** the single-file compiler can't resolve them. These errors cause the compiler
  ** to bomb (via bombIfErr) before reaching ResolveExpr, where real errors like
  ** undeclared variables would be detected. By replacing project type names with
  ** Obj, we prevent these early bombs and let the compiler reach later stages.
  **
  private Str replaceProjectTypeNames(Str source, ProjectIndex index)
  {
    lines := source.splitLines
    changed := false
    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      newLine := replaceTypeNamesInLine(line, index)
      if (newLine != line)
      {
        lines[i] = newLine
        changed = true
      }
    }
    return changed ? lines.join("\n") : source
  }

  **
  ** Replace project type identifiers in a single line with Obj.
  ** Skips: using statements, comments, strings, class/mixin declarations.
  **
  private Str replaceTypeNamesInLine(Str line, ProjectIndex index)
  {
    trimmed := line.trim

    // Skip using statements — they reference pods, not project types
    if (trimmed.startsWith("using ")) return line

    // Skip full-line comments
    if (trimmed.startsWith("//") || trimmed.startsWith("**") || trimmed.startsWith("*")) return line

    // Skip class/mixin declarations — the type name here IS the definition.
    // Base types are already handled by replaceProjectBaseTypes.
    if (trimmed.contains("class ") || trimmed.contains("mixin ")) return line

    result := StrBuf(line.size)
    pos := 0
    inStr := false
    anyReplaced := false

    while (pos < line.size)
    {
      ch := line[pos]

      // String handling
      if (ch == '"')
      {
        inStr = !inStr
        result.addChar(ch)
        pos++
        continue
      }
      if (inStr)
      {
        if (ch == '\\' && pos + 1 < line.size)
        {
          result.addChar(ch)
          pos++
          result.addChar(line[pos])
          pos++
          continue
        }
        result.addChar(ch)
        pos++
        continue
      }

      // Single-line comment — append rest of line as-is
      if (ch == '/' && pos + 1 < line.size && line[pos + 1] == '/')
      {
        result.add(line[pos..-1])
        return anyReplaced ? result.toStr : line
      }

      // Uppercase identifier — potential project type reference.
      // Only treat as a type name if preceded by a non-alphanumeric char
      // (space, paren, colon, etc.) to avoid replacing camelCase parts
      // like the "StrEnum" in "validateStrEnum".
      if (ch.isUpper)
      {
        start := pos
        while (pos < line.size && (line[pos].isAlphaNum || line[pos] == '_'))
          pos++
        name := line[start..<pos]

        // Check if preceded by a letter/digit/underscore — if so, this is
        // a camelCase continuation (e.g., "validateStrEnum"), not a type ref.
        prevIsIdent := start > 0 && (line[start - 1].isAlphaNum || line[start - 1] == '_')

        // Replace project types AND unresolvable external types with Obj.
        // Unresolvable external = not in sys/knownSysTypes, not in project,
        // not in any loadable using pod, AND the file has at least one
        // unloadable pod (so the type could plausibly come from it).
        // Guarding on hasUnloadablePods avoids replacing genuine typos in
        // files with no unknown pods.
        // Don't replace ALL_CAPS identifiers — they're constants, not types.
        isAllCaps := name.all |c| { c.isUpper || c == '_' || c.isDigit }
        isProjectTy := index.hasType(name)
        isUnresolvableExt := !isProjectTy && !usingPodIdx.hasType(name) &&
                             usingPodIdx.hasUnloadablePods
        if (!prevIsIdent && !isAllCaps && name.size > 1 && !knownSysTypes.contains(name) &&
            (isProjectTy || isUnresolvableExt))
        {
          result.add("Obj")
          anyReplaced = true
        }
        else
        {
          result.add(name)
        }
        continue
      }

      result.addChar(ch)
      pos++
    }

    return anyReplaced ? result.toStr : line
  }

  **
  ** Extract all project base types from the source.
  ** Scans for "class Foo : BaseType" patterns and returns base type names
  ** that are project types (exist in the index). Walks the inheritance chain
  ** to include transitive base types as well.
  **
  private Str[] extractBaseTypes(Str source, ProjectIndex index)
  {
    result := Str[,]
    lines := source.splitLines

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i].trim

      // Look for class/mixin declarations with inheritance
      classIdx := line.index("class ")
      mixinIdx := line.index("mixin ")
      if (classIdx == null && mixinIdx == null) continue

      keywordPos := classIdx ?: mixinIdx
      // Skip keywords found inside string literals
      if (isInsideStringLiteral(line, keywordPos)) continue

      // Find the colon after the class/mixin name
      colonIdx := line.index(":", keywordPos + 6)
      if (colonIdx == null) continue
      // Skip := (walrus operator)
      if (colonIdx + 1 < line.size && line[colonIdx + 1] == '=') continue

      // Get the part after the colon
      afterColon := line[colonIdx + 1 ..-1].trim
      if (afterColon.endsWith("{"))
        afterColon = afterColon[0 ..< afterColon.size - 1].trim

      // Split by comma for multiple base types
      parts := afterColon.split(',')
      parts.each |part|
      {
        name := part.trim
        if (name.size > 0 && name[0].isUpper && index.hasType(name))
        {
          if (!result.contains(name)) result.add(name)
          // Walk the inheritance chain to include transitive base types
          addTransitiveBaseTypes(name, index, result)
        }
      }
    }

    return result
  }

  **
  ** Walk the inheritance chain for a project type, adding all
  ** transitive base types that are in the project index.
  **
  private Void addTransitiveBaseTypes(Str typeName, ProjectIndex index, Str[] result)
  {
    visited := Str:Bool[typeName: true]
    queue := Str[typeName]

    while (!queue.isEmpty)
    {
      current := queue.removeAt(0)
      // Find base types of current in the index
      syms := index.findSymbols(current)
      typeSym := syms.find |s| { s.kind == SymbolKind.type }
      if (typeSym == null) continue

      // Try to extract base type from the file
      baseType := index.extractBaseTypeName(current)
      if (baseType != null && !visited.containsKey(baseType) && index.hasType(baseType))
      {
        visited[baseType] = true
        if (!result.contains(baseType)) result.add(baseType)
        queue.add(baseType)
      }
    }
  }

  **
  ** Check if a type defined in the preprocessed source had its base type
  ** replaced with Obj during preprocessing. This is detected by checking
  ** if the class declaration has ": Obj" as its base in the preprocessed lines.
  **
  private Bool isTypeWithReplacedBase(Str typeName, Str[] lines)
  {
    for (i := 0; i < lines.size; i++)
    {
      line := lines[i].trim
      classIdx := line.index("class ")
      mixinIdx := line.index("mixin ")
      if (classIdx == null && mixinIdx == null) continue
      keywordPos := classIdx ?: mixinIdx
      if (isInsideStringLiteral(line, keywordPos)) continue

      // Check if this line declares the type we're looking for
      afterKeyword := line[keywordPos + 6 ..-1].trim
      nameEnd := 0
      while (nameEnd < afterKeyword.size && (afterKeyword[nameEnd].isAlphaNum || afterKeyword[nameEnd] == '_'))
        nameEnd++
      declaredName := afterKeyword[0 ..< nameEnd]
      if (declaredName != typeName) continue

      // Check if base type is Obj (meaning it was replaced during preprocessing)
      colonIdx := line.index(":", keywordPos + 6)
      if (colonIdx == null) return false
      if (colonIdx + 1 < line.size && line[colonIdx + 1] == '=') return false
      afterColon := line[colonIdx + 1 ..-1].trim
      if (afterColon.startsWith("Obj")) return true
    }
    return false
  }

  **
  ** Check if a variable name is an inherited member from any of the base types.
  ** Also checks external ancestors via reflection to verify the member exists.
  **
  private Bool isInheritedMember(Str name, Str[] baseTypes, ProjectIndex index)
  {
    // Direct member of a project base type
    if (baseTypes.any |baseType| { index.hasMember(baseType, name) })
      return true

    // Check external ancestors: when a project base type extends an external type,
    // use reflection to verify the member actually exists in the external type.
    return baseTypes.any |baseType|
    {
      extBase := index.findResolvableBaseType(baseType)
      if (extBase == null) return false
      return index.hasExternalMember(name, extBase, baseType)
    }
  }

  **
  ** Validate cross-file references: check that ProjectType.member patterns
  ** reference members that actually exist in the project index.
  **
  LspDiagnostic[] validateCrossFileReferences(Str source, ProjectIndex index)
  {
    return crossFileValidator.validateCrossFileReferences(source, index)
  }

  // ==================================================================
  // Method Parameter Validation
  // ==================================================================

  **
  ** Validate method calls have the correct number of parameters.
  ** Scans for var.method(args) patterns, resolves the variable type,
  ** looks up the method in CompletionDefs, and checks argument count.
  **
  private LspDiagnostic[] validateMethodParams(Str source, ProjectIndex index)
  {
    return methodParamValidator.validateMethodParams(source, index)
  }

  **
  ** Warn on 'using' imports that are never referenced in the file:
  **
  **   using pod::TypeName  — warn if TypeName is not mentioned anywhere
  **   using pod            — warn if no public type from the pod is mentioned
  **
  ** Java FFI usings and 'using sys' are always skipped.
  ** Pods that cannot be loaded are skipped (we can't enumerate their types).
  **
  private LspDiagnostic[] checkUnusedUsings(Str source)
  {
    return unusedUsingValidator.checkUnusedUsings(source)
  }

  **
  ** Pedantic mode: check for := declarations without explicit types.
  ** Warns when a variable is declared with := but has no type annotation
  ** on the left side and no "as" cast on the right side.
  **
  private LspDiagnostic[] checkUntypedDeclarations(Str source)
  {
    return pedanticValidator.checkUntypedDeclarations(source)
  }

  **
  ** Check for unsafe usage of nullable variables (Type?) inside method bodies.
  ** Warns when a "." access is made on a variable declared with a nullable type
  ** and no prior null guard (if (x == null) return/throw) is in scope.
  ** Handles "if (x != null) { ... }" blocks as conditional-safe via brace tracking.
  **
  private LspDiagnostic[] checkNullableUsage(Str source)
  {
    return nullableUsageValidator.checkNullableUsage(source)
  }

  **
  ** Check for unused private fields and unused local variables.
  ** Private fields: lines with "private " that have no parentheses (not methods).
  ** Local vars: lines with ":=" at the single-word LHS pattern ("name :=").
  **
  private LspDiagnostic[] checkUnusedVars(Str source)
  {
    return unusedVarValidator.checkUnusedVars(source)
  }

  **
  ** Project-wide check for static const fields that share identical string values.
  ** Returns a map of fileUri -> diagnostics to add for each file.
  **
  [Str:LspDiagnostic[]] checkDuplicateConstValues([Str:Str] sources)
  {
    return duplicateConstValidator.checkDuplicateConstValues(sources)
  }
}
