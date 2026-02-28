
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
  **
  ** Analyze source code and return diagnostics for a single file.
  ** Filters errors about types/variables that exist in the project index,
  ** since those are false positives from single-file compilation.
  **
  LspDiagnostic[] analyze(Str uri, Str source, ProjectIndex index, Bool pedanticMode := false, Bool enableUnusedImport := true)
  {
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
          diagnostics.add(compilerErrToDiagnostic(err, severity))
        }
      }

      compiler.warns.each |warn|
      {
        if (!isProjectTypeFalsePositive(warn, index, lines, baseTypes))
          diagnostics.add(compilerErrToDiagnostic(warn, DiagnosticSeverity.warning))
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
      crossFileErrs := validateCrossFileReferences(source, index)
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
      paramErrs := validateMethodParams(source, index)
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
        unusedDiags := checkUnusedUsings(source)
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
        pedanticDiags := checkUntypedDeclarations(source)
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
      unusedDiags := checkUnusedVars(source)
      diagnostics.addAll(unusedDiags)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Unused var check error: $e")
    }

    // Nullable usage check: warn when a nullable variable is used without a null guard
    try
    {
      nullableDiags := checkNullableUsage(source)
      diagnostics.addAll(nullableDiags)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Nullable usage check error: $e")
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
  ** When a file references types from the same pod (e.g., IntelliplantNACoreModelProductParams),
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
    diagnostics := LspDiagnostic[,]
    lines := source.splitLines

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      trimmed := line.trim

      // Skip comment lines
      if (trimmed.startsWith("//") || trimmed.startsWith("**")) continue
      // Skip import lines
      if (trimmed.startsWith("using ")) continue
      // Skip class/mixin declaration lines (inheritance handled elsewhere)
      if (trimmed.startsWith("class ") || trimmed.startsWith("mixin ")) continue

      // Scan for TypeName.memberName patterns
      pos := 0
      while (pos < line.size)
      {
        // Skip string literals
        if (line[pos] == '"')
        {
          pos++
          while (pos < line.size && line[pos] != '"')
          {
            if (line[pos] == '\\') pos++  // skip escaped char
            pos++
          }
          pos++
          continue
        }

        // Skip Uri literals (backtick-delimited strings)
        if (line[pos] == '`')
        {
          pos++
          while (pos < line.size && line[pos] != '`')
          {
            if (line[pos] == '\\') pos++
            pos++
          }
          pos++
          continue
        }

        // Skip single-line comments
        if (pos + 1 < line.size && line[pos] == '/' && line[pos + 1] == '/')
          break

        // Look for an uppercase letter that could start a type name
        if (line[pos].isUpper)
        {
          // Extract the identifier
          nameStart := pos
          while (pos < line.size && (line[pos].isAlphaNum || line[pos] == '_'))
            pos++
          typeName := line[nameStart ..< pos]

          // Must be followed by a dot
          if (pos < line.size && line[pos] == '.')
          {
            dotPos := pos
            pos++

            // Must be followed by an identifier (member name)
            if (pos < line.size && (line[pos].isAlpha || line[pos] == '_'))
            {
              memberStart := pos
              while (pos < line.size && (line[pos].isAlphaNum || line[pos] == '_'))
                pos++
              memberName := line[memberStart ..< pos]

              // Check: is typeName a project type with the member missing?
              if (index.hasType(typeName) && !index.hasMember(typeName, memberName))
              {
                // Don't flag well-known patterns that aren't member access:
                // - Type.make (constructor), Type.fromStr, etc. from Obj
                // - Following by # (type literal, already handled)
                if (!isBuiltinSlot(memberName) &&
                    !(index.isEnumType(typeName) && isEnumBuiltinSlot(memberName)))
                {
                  // Check if the member might be inherited from a project base type
                  baseTypes := index.getBaseTypeChain(typeName)
                  memberInherited := baseTypes.any |bt| { index.hasMember(bt, memberName) }

                  // If not found in project base types, check if there's an external
                  // base type that could provide the member (we can't verify those)
                  if (!memberInherited)
                  {
                    externalBase := index.findResolvableBaseType(typeName)
                    if (externalBase != null) memberInherited = true
                  }

                  if (!memberInherited)
                  {
                    col := nameStart
                    range := LspRange(
                      LspPosition(i, col),
                      LspPosition(i, col + typeName.size + 1 + memberName.size)
                    )
                    diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.error,
                      "'${memberName}' is not a member of '${typeName}'", "fantom"))
                  }
                }
              }
            }
          }
          continue
        }
        pos++
      }
    }
    return diagnostics
  }

  ** Built-in slots inherited from Obj/Enum that types commonly have
  private static const Str[] builtinSlots := [
    "make", "typeof", "toStr", "hash", "equals",
    "compare", "with", "trap", "isImmutable", "toImmutable",
    "type", "fromStr", "defVal"
  ]

  ** Slots that only enum types inherit (compiler-generated)
  private static const Str[] enumBuiltinSlots := [
    "vals", "fromStr", "name", "ordinal"
  ]

  private Bool isBuiltinSlot(Str name) { builtinSlots.contains(name) }

  private Bool isEnumBuiltinSlot(Str name) { enumBuiltinSlots.contains(name) }

  **
  ** Convert CompilerErr to LSP Diagnostic
  **
  private LspDiagnostic compilerErrToDiagnostic(CompilerErr err, Int severity)
  {
    range := LspUtil.locToRange(err.loc)
    return LspDiagnostic(range, severity, err.msg, "fantom")
  }

  // ==================================================================
  // Method Parameter Validation
  // ==================================================================

  ** Completion definitions for looking up method signatures
  private const CompletionDefs defs := CompletionDefs.cur

  **
  ** Validate method calls have the correct number of parameters.
  ** Scans for var.method(args) patterns, resolves the variable type,
  ** looks up the method in CompletionDefs, and checks argument count.
  **
  private LspDiagnostic[] validateMethodParams(Str source, ProjectIndex index)
  {
    diagnostics := LspDiagnostic[,]
    lines := source.splitLines

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      trimmed := line.trim

      // Skip comments and blank lines
      if (trimmed.isEmpty || trimmed.startsWith("//") || trimmed.startsWith("**")) continue
      if (trimmed.startsWith("using ")) continue

      // Find method call patterns: varName.methodName(...)
      calls := findMethodCalls(line)
      lineIdx := i
      calls.each |call|
      {
        // Skip static type calls (TypeName.method) — these are calls on
        // types, not instances. The method signatures may differ from what
        // YML defines for instances (e.g., NavTree.find vs List.find).
        if (call.varName.size > 0 && call.varName[0].isUpper) return

        // Resolve the variable's type
        typeName := resolveVarType(call.varName, source, lineIdx, index)
        if (typeName == null) return

        // Look up the type's completions in YML
        items := defs.itemsFor(typeName)
        if (items == null) return

        // Find the method definition
        methodItem := items.find |item| { item.label == call.methodName }
        if (methodItem == null) return
        if (methodItem.detail == null) return

        // Parse expected parameter count from the detail string
        paramInfo := parseMethodParams(methodItem.detail)
        if (paramInfo == null) return

        // Count actual arguments
        actualCount := call.argCount
        // If there's a trailing closure after the parens, add it
        if (call.hasTrailingClosure) actualCount++

        // Validate
        if (actualCount < paramInfo.minArgs)
        {
          col := call.callStart
          endCol := call.callEnd.min(line.size)
          range := LspRange(LspPosition(lineIdx, col), LspPosition(lineIdx, endCol))
          expected := paramInfo.minArgs == paramInfo.maxArgs
            ? "${paramInfo.minArgs}" : "${paramInfo.minArgs}-${paramInfo.maxArgs}"
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.error,
            "'${call.methodName}' expects ${expected} argument(s), but got ${actualCount}", "fantom"))
        }
        else if (actualCount > paramInfo.maxArgs)
        {
          col := call.callStart
          endCol := call.callEnd.min(line.size)
          range := LspRange(LspPosition(lineIdx, col), LspPosition(lineIdx, endCol))
          expected := paramInfo.minArgs == paramInfo.maxArgs
            ? "${paramInfo.minArgs}" : "${paramInfo.minArgs}-${paramInfo.maxArgs}"
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.error,
            "'${call.methodName}' expects ${expected} argument(s), but got ${actualCount}", "fantom"))
        }
      }
    }

    return diagnostics
  }

  **
  ** Find all var.method(args) call patterns in a line.
  ** Returns a list of MethodCall descriptors.
  **
  private MethodCall[] findMethodCalls(Str line)
  {
    calls := MethodCall[,]
    pos := 0

    while (pos < line.size)
    {
      // Skip string literals
      if (line[pos] == '"')
      {
        pos++
        while (pos < line.size && line[pos] != '"')
        {
          if (line[pos] == '\\') pos++
          pos++
        }
        pos++
        continue
      }

      // Skip Uri literals (backtick-delimited strings)
      if (line[pos] == '`')
      {
        pos++
        while (pos < line.size && line[pos] != '`')
        {
          if (line[pos] == '\\') pos++
          pos++
        }
        pos++
        continue
      }

      // Skip comments
      if (pos + 1 < line.size && line[pos] == '/' && line[pos + 1] == '/')
        break

      // Look for identifier.identifier( pattern
      if (line[pos].isAlpha || line[pos] == '_')
      {
        // Extract first identifier (variable name)
        varStart := pos
        while (pos < line.size && (line[pos].isAlphaNum || line[pos] == '_'))
          pos++
        varName := line[varStart ..< pos]

        // Check for dot
        if (pos < line.size && line[pos] == '.')
        {
          pos++ // skip dot

          // Extract method name
          if (pos < line.size && (line[pos].isAlpha || line[pos] == '_'))
          {
            methodStart := pos
            while (pos < line.size && (line[pos].isAlphaNum || line[pos] == '_'))
              pos++
            methodName := line[methodStart ..< pos]

            // Skip if method name starts with uppercase (it's a type access, not method call on var)
            if (methodName.size > 0 && methodName[0].isLower)
            {
              // Check what follows: ( or space+| (trailing closure) or nothing
              restPos := pos
              while (restPos < line.size && line[restPos].isSpace) restPos++

              if (restPos < line.size && line[restPos] == '(')
              {
                // Has parenthesized arguments
                parenStart := restPos
                parenEnd := findMatchingParen(line, parenStart)
                if (parenEnd != null)
                {
                  argStr := line[parenStart + 1 ..< parenEnd].trim
                  argCount := argStr.isEmpty ? 0 : countArgs(argStr)
                  callEnd := parenEnd + 1

                  // Check for trailing closure after parens.
                  // A single '|' starts a closure; '||' is logical OR — not a closure.
                  afterParen := callEnd
                  while (afterParen < line.size && line[afterParen].isSpace) afterParen++
                  hasClosure := afterParen < line.size && line[afterParen] == '|' &&
                                (afterParen + 1 >= line.size || line[afterParen + 1] != '|')

                  calls.add(MethodCall {
                    it.varName = varName
                    it.methodName = methodName
                    it.argCount = argCount
                    it.hasTrailingClosure = hasClosure
                    it.callStart = varStart
                    it.callEnd = callEnd
                  })
                  pos = callEnd
                }
              }
              else if (restPos < line.size && line[restPos] == '|' &&
                       (restPos + 1 >= line.size || line[restPos + 1] != '|'))
              {
                // Trailing closure only (no parens): var.method |x| { }
                calls.add(MethodCall {
                  it.varName = varName
                  it.methodName = methodName
                  it.argCount = 0
                  it.hasTrailingClosure = true
                  it.callStart = varStart
                  it.callEnd = pos
                })
              }
              // else: no parens, no closure - property access or no-arg call, skip
            }
          }
        }
        continue
      }
      pos++
    }

    return calls
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
  ** Count the number of arguments in an argument string.
  ** Handles nested parens, brackets, closures, and string literals.
  **
  private Int countArgs(Str argStr)
  {
    if (argStr.trim.isEmpty) return 0
    depth := 0
    pipeDepth := 0
    inStr := false
    count := 1

    for (i := 0; i < argStr.size; i++)
    {
      ch := argStr[i]
      if (ch == '"' && !inStr) inStr = true
      else if (ch == '"' && inStr) inStr = false
      else if (ch == '\\' && inStr) { i++; continue }
      if (inStr) continue

      if (ch == '(' || ch == '[' || ch == '{') depth++
      else if (ch == ')' || ch == ']' || ch == '}') depth--
      else if (ch == '|') pipeDepth = pipeDepth == 0 ? 1 : 0
      else if (ch == ',' && depth == 0 && pipeDepth == 0) count++
    }
    return count
  }

  **
  ** Resolve a variable's type by scanning source for declarations.
  ** Simplified version that handles common patterns.
  **
  ** Delegate to shared TypeResolver utility
  private Str? resolveVarType(Str varName, Str source, Int currentLine, ProjectIndex index)
  {
    return TypeResolver.resolveVarType(varName, source, currentLine, index)
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
    diagnostics := LspDiagnostic[,]
    lines := source.splitLines

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      trimmed := line.trim
      if (!trimmed.startsWith("using ")) continue

      rest := trimmed["using ".size..-1].trim
      if (rest.contains("[java]")) continue

      colonIdx := rest.index("::")
      if (colonIdx != null)
      {
        // --- Specific type import: "using pod::TypeName" ---
        typeName := rest[colonIdx + 2..-1].trim
        if (typeName.isEmpty || !typeName[0].isUpper) continue

        // Strip "as Alias" suffix
        spaceIdx := typeName.index(" ")
        if (spaceIdx != null) typeName = typeName[0..<spaceIdx]

        if (!isTypeUsedInSource(typeName, lines, i))
        {
          range := LspRange(LspPosition(i, 0), LspPosition(i, line.size))
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.warning,
            "Unused import '${typeName}'", "fantom"))
        }
      }
      else
      {
        // --- Whole-pod import: "using pod" ---
        podName := rest
        spaceIdx := podName.index(" ")
        if (spaceIdx != null) podName = podName[0..<spaceIdx]
        if (podName == "sys") continue  // sys is always implicitly available

        // Only check if we can actually load the pod (already cached by usingPodIdx)
        pod := Pod.find(podName, false)
        if (pod == null) continue

        // Warn if no public type from the pod is referenced in the source
        anyUsed := pod.types.any |t|
        {
          t.isPublic && isTypeUsedInSource(t.name, lines, i)
        }
        if (!anyUsed)
        {
          range := LspRange(LspPosition(i, 0), LspPosition(i, line.size))
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.warning,
            "Unused import '${podName}'", "fantom"))
        }
      }
    }

    return diagnostics
  }

  **
  ** Check whether typeName appears as a whole identifier in any source line
  ** other than the using line at usingLineIdx.
  **
  private Bool isTypeUsedInSource(Str typeName, Str[] lines, Int usingLineIdx)
  {
    for (i := 0; i < lines.size; i++)
    {
      if (i == usingLineIdx) continue
      line := lines[i].trim
      if (line.startsWith("using ")) continue
      if (line.startsWith("//") || line.startsWith("**") || line.startsWith("*")) continue
      if (containsIdentifier(line, typeName)) return true
    }
    return false
  }

  **
  ** Return true if word appears as a complete identifier (respecting _ boundaries)
  ** anywhere in line.
  **
  private Bool containsIdentifier(Str line, Str word)
  {
    idx := 0
    while (true)
    {
      found := line.index(word, idx)
      if (found == null) return false
      endPos := found + word.size
      beforeOk := found == 0 || !LspUtil.isIdentifierChar(line[found - 1])
      afterOk  := endPos >= line.size || !LspUtil.isIdentifierChar(line[endPos])
      if (beforeOk && afterOk) return true
      idx = found + 1
    }
    return false
  }

  **
  ** Pedantic mode: check for := declarations without explicit types.
  ** Warns when a variable is declared with := but has no type annotation
  ** on the left side and no "as" cast on the right side.
  **
  private LspDiagnostic[] checkUntypedDeclarations(Str source)
  {
    diagnostics := LspDiagnostic[,]
    lines := source.splitLines

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      trimmed := line.trim

      // Skip comments, blank lines, using statements
      if (trimmed.isEmpty || trimmed.startsWith("//") ||
          trimmed.startsWith("**") || trimmed.startsWith("*") ||
          trimmed.startsWith("using ")) continue

      // Find := operator
      walrusIdx := trimmed.index(":=")
      if (walrusIdx == null) continue

      // Skip for-loop init clauses: "for (i := 0; ...)"
      if (trimmed.startsWith("for ") || trimmed.startsWith("for(")) continue
      // Skip catch blocks: "catch (Err e)"
      if (trimmed.startsWith("catch ") || trimmed.startsWith("catch(")) continue

      // Get left side (before :=) and right side (after :=)
      lhs := trimmed[0..<walrusIdx].trim
      rhs := trimmed[walrusIdx + 2 ..-1].trim

      // Skip if empty LHS or RHS
      if (lhs.isEmpty || rhs.isEmpty) continue

      // Check if there is an explicit type on the left side.
      // Strip modifiers, then check if first word starts with uppercase (a type).
      stripped := lhs
      modifiers := ["public", "private", "protected", "internal",
                    "static", "const", "final", "abstract",
                    "virtual", "override", "native", "once", "readonly"]
      modifiers.each |mod|
      {
        while (stripped.startsWith("${mod} "))
          stripped = stripped[mod.size + 1 ..-1].trim
      }

      // If remaining LHS has at least two words, and the first starts
      // with uppercase, it has an explicit type (e.g. "Str name")
      words := stripped.split(' ').findAll |w| { !w.isEmpty }
      hasExplicitType := words.size >= 2 && words[0].size > 0 && words[0][0].isUpper

      if (hasExplicitType) continue

      // Check if RHS has "as" cast
      if (rhs.contains(" as ")) continue

      // Get the variable name (last word on LHS)
      varName := words.size >= 1 ? words[-1] : lhs

      // Find the := position in the original line for accurate range
      origWalrus := line.index(":=")
      if (origWalrus == null) continue

      varStart := line.index(varName)
      if (varStart == null) varStart = 0

      range := LspRange(
        LspPosition(i, varStart),
        LspPosition(i, origWalrus + 2)
      )
      diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.warning,
        "'${varName}' declared without explicit type", "fantom-pedantic"))
    }

    return diagnostics
  }

  **
  ** Parse method signature from the detail string to get parameter info.
  ** E.g. "L add(V val)" -> min=1, max=1
  **      "Void each(|V,Int| c)" -> min=1, max=1 (closure counts as 1)
  **      "V? getSafe(Int index, V? def := null)" -> min=1, max=2
  **      "V? first()" -> min=0, max=0
  **      "Int size" -> null (field, not method)
  **
  private MethodParamInfo? parseMethodParams(Str detail)
  {
    // Find the parameter list between ( and )
    parenOpen := detail.index("(")
    if (parenOpen == null) return null // field, no parens

    parenClose := detail.indexr(")")
    if (parenClose == null) return null

    paramStr := detail[parenOpen + 1 ..< parenClose].trim
    if (paramStr.isEmpty) return MethodParamInfo { it.minArgs = 0; it.maxArgs = 0 }

    // Split parameters, respecting nested | for closure types
    params := splitParams(paramStr)
    minArgs := 0
    maxArgs := params.size

    params.each |p|
    {
      trimP := p.trim
      // Optional param: has ":= " default value
      if (!trimP.contains(":=")) minArgs++
    }

    return MethodParamInfo { it.minArgs = minArgs; it.maxArgs = maxArgs }
  }

  **
  ** Check for unsafe usage of nullable variables (Type?) inside method bodies.
  ** Warns when a "." access is made on a variable declared with a nullable type
  ** and no prior null guard (if (x == null) return/throw) is in scope.
  ** Handles "if (x != null) { ... }" blocks as conditional-safe via brace tracking.
  **
  private LspDiagnostic[] checkNullableUsage(Str source)
  {
    diagnostics := LspDiagnostic[,]
    lines := source.splitLines

    // Per-method state (reset on each new method signature)
    nullableVars := Str:Bool[:]    // vars declared as Type? — potentially null
    safeVars := Str:Bool[:]        // vars confirmed non-null via guard (if x==null return)
    condSafeDepths := Str:Int[:]   // vars safe inside an if(x!=null){} block → min brace depth
    braceDepth := 0
    inMethodBody := false

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      trimmed := line.trim

      if (trimmed.isEmpty || trimmed.startsWith("//") ||
          trimmed.startsWith("**") || trimmed.startsWith("*")) continue

      indent := 0
      while (indent < line.size && line[indent] == ' ') indent++

      // --- Class-body level (indent == 2): detect method signatures ---
      if (indent == 2)
      {
        if (trimmed.contains("(") && !trimmed.startsWith("@") &&
            !trimmed.startsWith("**") && !trimmed.startsWith("//"))
        {
          nullableVars = Str:Bool[:]
          safeVars = Str:Bool[:]
          condSafeDepths = Str:Int[:]
          braceDepth = 0
          inMethodBody = false
          parseNullableParams(trimmed, nullableVars)
        }
        if (trimmed == "{") inMethodBody = true
        if (trimmed == "}") inMethodBody = false
        continue
      }

      if (!inMethodBody) continue

      // Count braces on this line
      opens := 0; closes := 0
      for (ci := 0; ci < trimmed.size; ci++)
      {
        ch := trimmed[ci]
        if (ch == '{') opens++
        else if (ch == '}') closes++
      }

      // Apply opening braces first (so same-line "if (x!=null){" is at new depth)
      braceDepth += opens

      // --- Detect nullable local variable: "Type? varName :=" ---
      walrusIdx := trimmed.index(":=")
      if (walrusIdx != null && !trimmed.startsWith("for ") && !trimmed.startsWith("for("))
      {
        lhs := trimmed[0..<walrusIdx].trim
        words := lhs.split(' ').findAll |w| { !w.isEmpty }
        if (words.size >= 2)
        {
          typeWord := words[-2]
          varName  := words[-1]
          if (!typeWord.isEmpty && typeWord.endsWith("?") && typeWord[0].isUpper &&
              !varName.isEmpty && varName[0].isLower)
            nullableVars[varName] = true
        }
      }

      // --- Detect null guard: "if (x == null) …" with early exit → x is safe ---
      nullEqVar := extractNullEqualVar(trimmed)
      if (nullEqVar != null && nullableVars.containsKey(nullEqVar) &&
          !safeVars.containsKey(nullEqVar))
      {
        if (lineOrNextHasEarlyExit(lines, i))
          safeVars[nullEqVar] = true
      }

      // --- Detect conditional safe: "if (x != null)" → x is safe inside the block ---
      nullNeqVar := extractNullNotEqualVar(trimmed)
      if (nullNeqVar != null && nullableVars.containsKey(nullNeqVar) &&
          !safeVars.containsKey(nullNeqVar))
      {
        // If { is already on this line (braceDepth already incremented), use braceDepth;
        // otherwise anticipate the next line's { by adding 1.
        condSafeDepths[nullNeqVar] = opens > 0 ? braceDepth : braceDepth + 1
      }

      // --- Check for unsafe dot access on nullable vars ---
      nullableVars.keys.each |varName|
      {
        if (safeVars.containsKey(varName)) return  // absolutely safe

        // Conditionally safe inside an if(!=null) block?
        if (condSafeDepths.containsKey(varName))
        {
          condDepth := condSafeDepths[varName] ?: 0
          if (braceDepth >= condDepth) return
        }

        usageCol := findNullableUsage(line, varName)
        if (usageCol != null)
        {
          range := LspRange(LspPosition(i, usageCol), LspPosition(i, usageCol + varName.size))
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.warning,
            "'${varName}' might be null", "fantom"))
        }
      }

      // Apply closing braces, then evict condSafe vars that left their scope.
      // Only evict on closing-brace lines to avoid premature eviction on
      // "if (x != null)" lines (where the { appears on the next line).
      braceDepth -= closes
      if (braceDepth < 0) braceDepth = 0

      if (closes > 0)
      {
        toRemove := Str[,]
        condSafeDepths.each |minDepth, varName|
        {
          if (braceDepth < minDepth) toRemove.add(varName)
        }
        toRemove.each |varName| { condSafeDepths.remove(varName) }
      }
    }

    return diagnostics
  }

  **
  ** Parse method/constructor parameters from a signature line and populate
  ** nullableVars with any params declared as "Type? name".
  **
  private Void parseNullableParams(Str trimmedLine, Str:Bool nullableVars)
  {
    parenOpen := trimmedLine.index("(")
    if (parenOpen == null) return
    parenClose := trimmedLine.indexr(")")
    if (parenClose == null || parenClose <= parenOpen) return

    paramStr := trimmedLine[parenOpen + 1 ..< parenClose].trim
    if (paramStr.isEmpty) return

    paramStr.split(',').each |param|
    {
      p := param.trim
      if (p.isEmpty) return

      // Strip default value: "Type? name := default" → "Type? name"
      defIdx := p.index(":=")
      core := defIdx != null ? p[0..<defIdx].trim : p

      parts := core.split(' ').findAll |w| { !w.isEmpty }
      if (parts.size >= 2)
      {
        typeWord  := parts[0]
        paramName := parts[-1]
        if (!typeWord.isEmpty && typeWord.endsWith("?") && typeWord[0].isUpper &&
            !paramName.isEmpty && paramName[0].isLower)
          nullableVars[paramName] = true
      }
    }
  }

  **
  ** Extract variable name from "varName == null" or "null == varName" pattern.
  **
  private Str? extractNullEqualVar(Str trimmed)
  {
    // "varName == null"
    eqIdx := trimmed.index(" == null")
    if (eqIdx != null && eqIdx > 0)
    {
      end := eqIdx
      start := end - 1
      while (start > 0 && LspUtil.isIdentifierChar(trimmed[start - 1])) start--
      if (start < end)
      {
        varName := trimmed[start..<end]
        if (!varName.isEmpty && varName[0].isLower) return varName
      }
    }
    // "null == varName"
    nullEqIdx := trimmed.index("null == ")
    if (nullEqIdx != null)
    {
      start := nullEqIdx + "null == ".size
      end := start
      while (end < trimmed.size && LspUtil.isIdentifierChar(trimmed[end])) end++
      if (start < end)
      {
        varName := trimmed[start..<end]
        if (!varName.isEmpty && varName[0].isLower) return varName
      }
    }
    return null
  }

  **
  ** Extract variable name from "varName != null" or "null != varName" pattern.
  **
  private Str? extractNullNotEqualVar(Str trimmed)
  {
    // "varName != null"
    neIdx := trimmed.index(" != null")
    if (neIdx != null && neIdx > 0)
    {
      end := neIdx
      start := end - 1
      while (start > 0 && LspUtil.isIdentifierChar(trimmed[start - 1])) start--
      if (start < end)
      {
        varName := trimmed[start..<end]
        if (!varName.isEmpty && varName[0].isLower) return varName
      }
    }
    // "null != varName"
    nullNeIdx := trimmed.index("null != ")
    if (nullNeIdx != null)
    {
      start := nullNeIdx + "null != ".size
      end := start
      while (end < trimmed.size && LspUtil.isIdentifierChar(trimmed[end])) end++
      if (start < end)
      {
        varName := trimmed[start..<end]
        if (!varName.isEmpty && varName[0].isLower) return varName
      }
    }
    return null
  }

  **
  ** Return true if the line at lineIdx or the first non-blank line after it
  ** contains a method-exit keyword: return, throw, continue, or break.
  **
  private Bool lineOrNextHasEarlyExit(Str[] lines, Int lineIdx)
  {
    trimmed := lines[lineIdx].trim
    if (trimmed.contains("return") || trimmed.contains("throw") ||
        trimmed.contains("continue") || trimmed.contains("break"))
      return true
    for (j := lineIdx + 1; j < lines.size && j <= lineIdx + 3; j++)
    {
      next := lines[j].trim
      if (next.isEmpty || next.startsWith("//") || next.startsWith("**")) continue
      if (next.startsWith("return") || next.startsWith("throw") ||
          next.startsWith("continue") || next.startsWith("break"))
        return true
      break
    }
    return false
  }

  **
  ** Scan line for an unsafe "varName." dot access.
  ** Returns the column of varName, or null if no unsafe usage is found.
  ** Skips safe-navigation (?.), null-check contexts, and comment/string lines.
  **
  private Int? findNullableUsage(Str line, Str varName)
  {
    // Suppress the whole line if it contains any null comparison for this var
    if (line.index("${varName} == null") != null ||
        line.index("${varName} != null") != null ||
        line.index("null == ${varName}") != null ||
        line.index("null != ${varName}") != null ||
        line.index("${varName} ?:") != null)
      return null

    idx := 0
    while (true)
    {
      found := line.index(varName, idx)
      if (found == null) return null

      endPos := found + varName.size

      // Word boundary before varName
      beforeOk := found == 0 || !LspUtil.isIdentifierChar(line[found - 1])
      if (!beforeOk) { idx = found + 1; continue }

      // Must have a character after varName
      if (endPos >= line.size) return null

      nextChar := line[endPos]

      // Safe-navigation operator: varName?. → no warning
      if (nextChar == '?') { idx = found + 1; continue }

      // Must be a plain dot access
      if (nextChar != '.') { idx = found + 1; continue }

      return found
    }
    return null
  }

  **
  ** Check for unused private fields and unused local variables.
  ** Private fields: lines with "private " that have no parentheses (not methods).
  ** Local vars: lines with ":=" at the single-word LHS pattern ("name :=").
  **
  private LspDiagnostic[] checkUnusedVars(Str source)
  {
    diagnostics := LspDiagnostic[,]
    lines := source.splitLines
    modifierWords := ["public", "private", "protected", "internal",
                      "static", "const", "final", "abstract",
                      "virtual", "override", "native", "once", "readonly"]

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      trimmed := line.trim

      // Skip blank lines and comments
      if (trimmed.isEmpty || trimmed.startsWith("//") ||
          trimmed.startsWith("**") || trimmed.startsWith("*")) continue

      // Count leading spaces
      indent := 0
      while (indent < line.size && line[indent] == ' ') indent++

      walrusIdx := trimmed.index(":=")

      // --- Private field check ---
      // Matches: "  private [modifiers] TypeName fieldName" or with := RHS
      if (trimmed.startsWith("private "))
      {
        // Skip method declarations (they have parentheses in signature)
        if (trimmed.contains("(")) continue

        // Get declaration text (before := if present, else whole trimmed line)
        fieldDecl := walrusIdx != null ? trimmed[0..<walrusIdx].trim : trimmed

        // Skip accessor blocks: "private Str name { get { ... } }"
        if (fieldDecl.contains("{")) continue

        // Strip "private " prefix and all modifiers
        stripped := fieldDecl["private ".size..-1].trim
        modifierWords.each |mod|
        {
          while (stripped.startsWith("${mod} "))
            stripped = stripped[mod.size + 1 ..-1].trim
        }

        // Need at least "TypeName fieldName" (2 words: type + name)
        words := stripped.split(' ').findAll |w| { !w.isEmpty }
        if (words.size < 2) continue

        // Field name is last word, must start lowercase
        fieldName := words[-1]
        if (fieldName.isEmpty || !fieldName[0].isLower) continue
        if (fieldName == "_" || fieldName == "it" || fieldName.startsWith("_")) continue

        // Warn if name never appears elsewhere in the file
        if (!isNameUsedInFile(lines, fieldName, i))
        {
          col := findIdentifierPos(line, fieldName) ?: 0
          range := LspRange(LspPosition(i, col), LspPosition(i, col + fieldName.size))
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.warning,
            "'${fieldName}' is declared but never used", "fantom"))
        }
        continue
      }

      // --- Local variable check ---
      // Matches simple "name := value" pattern (single word LHS, no modifiers)
      if (walrusIdx != null && indent >= 4)
      {
        // Skip for-loop init and catch blocks
        if (trimmed.startsWith("for ") || trimmed.startsWith("for(")) continue
        if (trimmed.startsWith("catch ") || trimmed.startsWith("catch(")) continue

        // Get LHS and strip any modifiers
        lhs := trimmed[0..<walrusIdx].trim
        if (lhs.isEmpty) continue

        stripped := lhs
        modifierWords.each |mod|
        {
          while (stripped.startsWith("${mod} "))
            stripped = stripped[mod.size + 1 ..-1].trim
        }

        // Only handle single-word LHS (plain "name :=" without type annotation)
        // to avoid false positives on class-level fields like "Str name :="
        words := stripped.split(' ').findAll |w| { !w.isEmpty }
        if (words.size != 1) continue

        varName := words[0]
        if (varName.isEmpty || !varName[0].isLower) continue
        if (varName == "_" || varName == "it" || varName.startsWith("_")) continue

        // Warn if name never appears after its declaration line
        if (!isNameUsedAfterLine(lines, varName, i))
        {
          col := findIdentifierPos(line, varName) ?: 0
          range := LspRange(LspPosition(i, col), LspPosition(i, col + varName.size))
          diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.warning,
            "'${varName}' is declared but never used", "fantom"))
        }
      }
    }

    return diagnostics
  }

  **
  ** Return the character position of word as a whole identifier in line, or null.
  **
  private Int? findIdentifierPos(Str line, Str word)
  {
    idx := 0
    while (true)
    {
      found := line.index(word, idx)
      if (found == null) return null
      endPos := found + word.size
      beforeOk := found == 0 || !LspUtil.isIdentifierChar(line[found - 1])
      afterOk  := endPos >= line.size || !LspUtil.isIdentifierChar(line[endPos])
      if (beforeOk && afterOk) return found
      idx = found + 1
    }
    return null
  }

  **
  ** Return true if name appears as a whole identifier in any line except excludeLine.
  **
  private Bool isNameUsedInFile(Str[] lines, Str name, Int excludeLine)
  {
    for (i := 0; i < lines.size; i++)
    {
      if (i == excludeLine) continue
      ln := lines[i].trim
      if (ln.startsWith("//") || ln.startsWith("**") || ln.startsWith("*")) continue
      if (containsIdentifier(lines[i], name)) return true
    }
    return false
  }

  **
  ** Return true if name appears as a whole identifier in any line after fromLine.
  **
  private Bool isNameUsedAfterLine(Str[] lines, Str name, Int fromLine)
  {
    for (i := fromLine + 1; i < lines.size; i++)
    {
      ln := lines[i].trim
      if (ln.startsWith("//") || ln.startsWith("**") || ln.startsWith("*")) continue
      if (containsIdentifier(lines[i], name)) return true
    }
    return false
  }

  **
  ** Project-wide check for static const fields that share identical string values.
  ** Returns a map of fileUri -> diagnostics to add for each file.
  **
  [Str:LspDiagnostic[]] checkDuplicateConstValues([Str:Str] sources)
  {
    // Phase 1: scan each file for "const ... := <string literal>" lines.
    // valueMap: string value -> list of tab-separated "fileUri\tlineNum\tvarName" records
    valueMap := Str:Str[][:]

    sources.each |source, fileUri|
    {
      lines := source.splitLines
      for (i := 0; i < lines.size; i++)
      {
        line := lines[i]
        trimmed := line.trim

        // Skip comments and blank lines
        if (trimmed.isEmpty || trimmed.startsWith("//") ||
            trimmed.startsWith("**") || trimmed.startsWith("*")) continue

        // Must contain standalone "const" keyword
        if (!containsIdentifier(trimmed, "const")) continue

        // Must have :=
        walrusIdx := trimmed.index(":=")
        if (walrusIdx == null) continue

        // RHS must start with a string literal
        rhs := trimmed[walrusIdx + 2 ..-1].trim
        if (rhs.isEmpty || rhs[0] != '"') continue

        // Extract the string literal value
        strVal := extractStringLiteral(rhs)
        if (strVal == null || strVal.size < 5) continue

        // Extract var name (last word on LHS)
        lhs := trimmed[0..<walrusIdx].trim
        words := lhs.split(' ').findAll |w| { !w.isEmpty }
        varName := words.isEmpty ? "" : words[-1]

        // Store as tab-separated record
        record := "${fileUri}\t${i}\t${varName}"
        existing := valueMap[strVal]
        if (existing == null) { existing = Str[,]; valueMap[strVal] = existing }
        existing.add(record)
      }
    }

    // Phase 2: for values with 2+ occurrences, emit a warning on each occurrence.
    result := Str:LspDiagnostic[][:]
    valueMap.each |occList, strVal|
    {
      if (occList.size < 2) return

      displayVal := strVal.size > 30 ? strVal[0..29] + "..." : strVal

      occList.each |record|
      {
        parts := record.split('\t')
        fileUri := parts[0]
        lineNum := parts[1].toInt(10, false) ?: 0
        varName := parts.size > 2 ? parts[2] : ""

        source := sources[fileUri] ?: ""
        srcLines := source.splitLines
        lineText := lineNum < srcLines.size ? srcLines[lineNum] : ""
        col := varName.isEmpty ? 0 : (findIdentifierPos(lineText, varName) ?: 0)

        range := LspRange(
          LspPosition(lineNum, col),
          LspPosition(lineNum, col + varName.size)
        )
        msg := "Duplicate const value \"${displayVal}\" found in ${occList.size} places"
        diag := LspDiagnostic(range, DiagnosticSeverity.warning, msg, "fantom")

        if (!result.containsKey(fileUri)) result[fileUri] = LspDiagnostic[,]
        result[fileUri].add(diag)
      }
    }

    return result
  }

  **
  ** Extract the raw content of a Fantom string literal starting at s[0] == '"'.
  ** Returns null if the string is unterminated.
  **
  private Str? extractStringLiteral(Str s)
  {
    if (s.isEmpty || s[0] != '"') return null
    buf := StrBuf()
    i := 1
    while (i < s.size)
    {
      ch := s[i]
      if (ch == '\\') { i += 2; continue }
      if (ch == '"') return buf.toStr
      buf.addChar(ch)
      i++
    }
    return null
  }

  **
  ** Split a parameter string by commas, respecting nested | and < > structures.
  **
  private Str[] splitParams(Str paramStr)
  {
    params := Str[,]
    depth := 0
    pipeDepth := 0
    current := StrBuf()

    for (i := 0; i < paramStr.size; i++)
    {
      ch := paramStr[i]
      if (ch == '|') pipeDepth = pipeDepth == 0 ? 1 : 0
      else if (ch == '(' || ch == '[' || ch == '<') depth++
      else if (ch == ')' || ch == ']' || ch == '>') depth--
      else if (ch == ',' && depth == 0 && pipeDepth == 0)
      {
        params.add(current.toStr)
        current.clear
        continue
      }
      current.addChar(ch)
    }
    if (current.size > 0) params.add(current.toStr)
    return params
  }
}

**************************************************************************
** MethodCall - describes a method call found in source
**************************************************************************
internal class MethodCall
{
  Str varName := ""
  Str methodName := ""
  Int argCount := 0
  Bool hasTrailingClosure := false
  Int callStart := 0
  Int callEnd := 0
}

**************************************************************************
** MethodParamInfo - expected parameter counts for a method
**************************************************************************
internal class MethodParamInfo
{
  Int minArgs := 0
  Int maxArgs := 0
}
