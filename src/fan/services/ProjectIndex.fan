//
// Copyright (c) 2025, Brian Frank and Andy Frank
// Licensed under the Academic Free License version 3.0
//
// History:
//   11 Feb 26  Creation
//

**
** ProjectIndex - Central index for Fantom project symbols.
** Parses build.fan for project structure, indexes all source files,
** provides scope-aware definition lookup, and runs build for diagnostics.
**
class ProjectIndex
{
  ** Project root directory (where build.fan is)
  File? baseDir { private set }

  ** Pod name from build.fan
  Str? podName { private set }

  ** Source directories from build.fan
  Uri[] srcDirs := Uri[,] { private set }

  ** All source files discovered under srcDirs
  File[] sourceFiles := File[,] { private set }

  ** Per-file symbol index, keyed by file URI
  private Str:FileIndex fileIndexes := Str:FileIndex[:]

  ** All symbols by name for fast lookup
  private Str:IndexedSymbol[] symbolsByName := Str:IndexedSymbol[][:]

  ** AST-derived base type info: typeName -> baseTypeName
  Str:Str baseTypeByType := Str:Str[:]

  ** Workspace root directory (set during init)
  File? workspaceRoot { private set }

  ** All pods discovered in workspace, one per build.fan
  PodInfo[] pods := PodInfo[,] { private set }

  ** Lookup map: podName -> PodInfo
  private Str:PodInfo podsByName := Str:PodInfo[:]

  **
  ** Initialize the index from a workspace root URI.
  ** Discovers build.fan, parses project info, indexes all source files.
  **
  Void init(Str workspaceRootUri)
  {
    request := ProjectIndexInitRequestBuilder()
      .withWorkspaceRootUri(workspaceRootUri)
      .build

    initRequest(request)
  }

  **
  ** Initialize the index using a builder-created request object.
  **
  Void initRequest(ProjectIndexInitRequest request)
  {
    workspaceRootUri := request.workspaceRootUri

    try
    {
      // Ensure URI ends with / so Fantom treats it as a directory
      dirUri := workspaceRootUri
      if (!dirUri.endsWith("/")) dirUri = dirUri + "/"
      dir := LspUtil.uriToFile(dirUri)
      workspaceRoot = dir

      LspProtocol.logInfo("ProjectIndex: workspace dir=${dir.osPath}")

      // Discover all pods in the workspace (walk DOWN the tree)
      discovered := discoverPods(dir)
      pods = discovered
      pods.each |pod|
      {
        if (pod.podName != null)
          podsByName[pod.podName] = pod
      }

      if (pods.isEmpty)
      {
        LspProtocol.logInfo("ProjectIndex: no build.fan files found in workspace")
        return
      }

      LspProtocol.logInfo("ProjectIndex: discovered ${pods.size} pod(s)")

      // Select primary pod: prefer a root-level build.fan (directly in workspaceRoot)
      primary := pods.find |pod| { pod.baseDir.osPath == dir.osPath }
      if (primary == null) primary = pods.first

      // Backward-compat single-pod fields reflect the primary pod
      baseDir = primary.baseDir
      podName = primary.podName
      srcDirs = primary.srcDirs

      // sourceFiles = union across all pods (enables cross-pod features)
      allFiles := File[,]
      pods.each |pod| { allFiles.addAll(pod.sourceFiles) }
      sourceFiles = allFiles

      LspProtocol.logInfo("ProjectIndex: ${pods.size} pod(s), ${sourceFiles.size} total source files")

      // Index synchronously only for single-pod or small workspaces to avoid
      // blocking the LSP initialize response. Large multi-pod workspaces defer
      // to backgroundInit which runs indexAll in a background thread.
      if (pods.size <= 1 || sourceFiles.size <= 200)
        indexAll
      else
        LspProtocol.logInfo("ProjectIndex: large multi-pod workspace — deferring indexAll to backgroundInit")
    }
    catch (Err e)
    {
      LspProtocol.logInfo("ProjectIndex init error: $e")
    }
  }

  **
  ** Refresh discovered pods/source files from disk.
  ** Keeps workspace metadata current when files are added/removed.
  **
  Void refreshWorkspaceFiles()
  {
    root := workspaceRoot
    if (root == null) return

    try
    {
      discovered := discoverPods(root)
      if (discovered.isEmpty) return

      pods = discovered
      podsByName.clear
      discovered.each |pod|
      {
        if (pod.podName != null)
          podsByName[pod.podName] = pod
      }

      // Keep backward-compat single-pod fields aligned to primary pod
      primary := discovered.find |pod| { pod.baseDir.osPath == root.osPath }
      if (primary == null) primary = discovered.first

      baseDir = primary.baseDir
      podName = primary.podName
      srcDirs = primary.srcDirs

      // sourceFiles = union across all pods
      allFiles := File[,]
      discovered.each |pod| { allFiles.addAll(pod.sourceFiles) }
      sourceFiles = allFiles
    }
    catch (Err e)
    {
      LspProtocol.logInfo("ProjectIndex refresh error: $e")
    }
  }

  **
  ** Index a saved file only when it has no error-severity diagnostics.
  ** Returns true when indexing occurred, false when skipped.
  **
  Bool indexSavedFile(Str fileUri, Str source, Bool hasErrors)
  {
    // Ensure newly created/deleted files are visible to the workspace index.
    refreshWorkspaceFiles

    if (hasErrors)
    {
      LspProtocol.logInfo("ProjectIndex: skipped indexing saved file with errors: $fileUri")
      return false
    }

    indexFile(fileUri, source)
    return true
  }

  **
  ** Re-index all source files from disk.
  **
  Void indexAll()
  {
    refreshWorkspaceFiles

    fileIndexes.clear
    symbolsByName.clear
    sourceFiles.each |f|
    {
      try
      {
        fileUri := LspUtil.fileToUri(f)
        source := f.readAllStr
        doIndex(fileUri, source)
      }
      catch (Err e)
      {
        LspProtocol.logInfo("ProjectIndex: error indexing ${f.name}: $e")
      }
    }
    LspProtocol.logInfo("ProjectIndex: indexed ${symbolsByName.size} unique symbol names")
  }

  **
  ** Re-index a single file (called on didChange with current buffer content).
  **
  **
  ** Index a file and return the set of type names whose members changed.
  ** Returns empty list if no member-level changes detected.
  **
  Str[] indexFile(Str fileUri, Str source)
  {
    // Capture old symbols for diff
    oldIdx := fileIndexes[fileUri]
    oldMembers := Str:Str[][:]  // typeName -> member names
    if (oldIdx != null)
    {
      oldIdx.symbols.each |sym|
      {
        if (sym.typeName != null &&
            (sym.kind == SymbolKind.method || sym.kind == SymbolKind.field))
        {
          if (!oldMembers.containsKey(sym.typeName))
            oldMembers[sym.typeName] = Str[,]
          oldMembers[sym.typeName].add(sym.name)
        }
      }
      // Remove old symbols from global index
      oldIdx.symbols.each |sym|
      {
        list := symbolsByName[sym.name]
        if (list != null)
        {
          symbolsByName[sym.name] = list.findAll |s| { s.fileUri != fileUri }
        }
      }
    }

    doIndex(fileUri, source)

    // Capture new symbols and compute diff
    newIdx := fileIndexes[fileUri]
    newMembers := Str:Str[][:]
    if (newIdx != null)
    {
      newIdx.symbols.each |sym|
      {
        if (sym.typeName != null &&
            (sym.kind == SymbolKind.method || sym.kind == SymbolKind.field))
        {
          if (!newMembers.containsKey(sym.typeName))
            newMembers[sym.typeName] = Str[,]
          newMembers[sym.typeName].add(sym.name)
        }
      }
    }

    // Find types whose members changed
    changedTypes := Str[,]
    allTypes := Str:Bool[:]
    oldMembers.keys.each |t| { allTypes[t] = true }
    newMembers.keys.each |t| { allTypes[t] = true }
    allTypes.keys.each |typeName|
    {
      oldList := oldMembers[typeName] ?: Str[,]
      newList := newMembers[typeName] ?: Str[,]
      oldList.sort; newList.sort
      if (oldList != newList) changedTypes.add(typeName)
    }
    return changedTypes
  }

  **
  ** Check if a type name exists in the project index.
  **
  Bool hasType(Str name)
  {
    syms := symbolsByName[name]
    if (syms == null) return false
    return syms.any |s| { s.kind == SymbolKind.type }
  }

  **
  ** Check if a file URI is part of the project's discovered source files.
  ** Returns false if init failed (no build.fan) or the file is outside srcDirs.
  **
  Bool isProjectFile(Str fileUri)
  {
    normalized := LspUtil.normalizeFileUri(fileUri)
    return sourceFiles.any |f| { LspUtil.fileToUri(f) == normalized }
  }

  **
  ** Find which PodInfo a given file URI belongs to.
  ** Returns null if the file is not part of any discovered pod.
  **
  PodInfo? getPodForFile(Str fileUri)
  {
    normalized := LspUtil.normalizeFileUri(fileUri)
    return pods.find |pod|
    {
      pod.sourceFiles.any |f| { LspUtil.fileToUri(f) == normalized }
    }
  }

  **
  ** Return the build.fan file for the pod that contains fileUri,
  ** or null if the file is not part of any known pod.
  **
  File? buildFanForFile(Str fileUri)
  {
    return getPodForFile(fileUri)?.buildFan
  }

  **
  ** Check if a type has a specific member (field or method).
  **
  Bool hasMember(Str typeName, Str memberName)
  {
    syms := symbolsByName[memberName]
    if (syms == null) return false
    return syms.any |s|
    {
      s.typeName == typeName &&
      (s.kind == SymbolKind.method || s.kind == SymbolKind.field || s.kind == SymbolKind.enumVal)
    }
  }

  **
  ** Check if a type is an enum class (has any enumVal symbols).
  **
  Bool isEnumType(Str typeName)
  {
    return symbolsByName.any |syms|
    {
      syms.any |s| { s.typeName == typeName && s.kind == SymbolKind.enumVal }
    }
  }

  **
  ** Find a specific member symbol by type and member name.
  ** Returns null if not found.
  **
  IndexedSymbol? findMemberSymbol(Str typeName, Str memberName)
  {
    syms := symbolsByName[memberName]
    if (syms == null) return null
    return syms.find |s|
    {
      s.typeName == typeName &&
      (s.kind == SymbolKind.method || s.kind == SymbolKind.field || s.kind == SymbolKind.enumVal)
    }
  }

  **
  ** Get all method and field symbols belonging to a type.
  **
  IndexedSymbol[] getTypeMembers(Str typeName)
  {
    result := IndexedSymbol[,]
    symbolsByName.each |syms, name|
    {
      syms.each |sym|
      {
        if (sym.typeName == typeName &&
            (sym.kind == SymbolKind.method || sym.kind == SymbolKind.field || sym.kind == SymbolKind.enumVal))
          result.add(sym)
      }
    }
    return result
  }

  **
  ** Get the chain of project base types for a given type.
  ** Walks up the inheritance chain returning only project types (types in the index).
  ** Stops when it hits a non-project type or no base type.
  **
  Str[] getBaseTypeChain(Str typeName)
  {
    result := Str[,]
    visited := Str:Bool[:]
    current := typeName

    while (true)
    {
      if (visited.containsKey(current)) break
      visited[current] = true

      baseType := extractBaseTypeName(current)
      if (baseType == null) break

      if (hasType(baseType))
      {
        result.add(baseType)
        current = baseType
      }
      else break
    }
    return result
  }

  **
  ** Check if an external type (from a pod) has a given member slot.
  ** Uses the using pods from the file that defines baseTypeName to locate
  ** the external type, then checks via reflection.
  **
  Bool hasExternalMember(Str memberName, Str externalTypeName, Str baseTypeName)
  {
    try
    {
      // Find the file that defines baseTypeName to get its using pods
      syms := findSymbols(baseTypeName)
      typeSym := syms.find |s| { s.kind == SymbolKind.type }
      if (typeSym == null) return false

      idx := fileIndexes[typeSym.fileUri]
      if (idx == null) return false

      // Try sys pod plus each using pod to find the external type
      allPods := Str["sys"]
      allPods.addAll(idx.usingPods)

      return allPods.any |podName|
      {
        pod := Pod.find(podName, false)
        if (pod == null) return false
        type := pod.type(externalTypeName, false)
        if (type == null) return false
        return type.slot(memberName, false) != null
      }
    }
    catch (Err e) { return false }
  }

  **
  ** Find the first non-project base type for a project type.
  ** Walks up the inheritance chain through project types until it finds
  ** a type from a 'using' pod (resolvable by the compiler in script mode).
  ** Returns null if no resolvable ancestor is found.
  **
  ** E.g., NAProjTest → FinProjTest (from finStackHost pod) → returns "FinProjTest"
  **
  Str? findResolvableBaseType(Str typeName)
  {
    // Guard against infinite loops (circular inheritance)
    visited := Str:Bool[:]
    current := typeName

    while (true)
    {
      if (visited.containsKey(current)) return null
      visited[current] = true

      // Find the type symbol to get its file
      syms := findSymbols(current)
      typeSym := syms.find |s| { s.kind == SymbolKind.type }
      if (typeSym == null) return null

      // Read the source file and find the extends clause
      baseType := extractBaseTypeFromFile(typeSym.fileUri, current)
      if (baseType == null) return null

      // If the base type is NOT in the project index, it's from a pod
      // and the compiler can resolve it — use it as the replacement
      if (!hasType(baseType)) return baseType

      // Otherwise it's another project type — keep walking up
      current = baseType
    }
    return null  // unreachable
  }

  **
  ** Extract the base type name for a project type.
  ** Finds the type's file in the index and reads the inheritance clause.
  **
  Str? extractBaseTypeName(Str typeName)
  {
    // Check AST-derived base type map first
    astBase := baseTypeByType[typeName]
    if (astBase != null) return astBase

    syms := findSymbols(typeName)
    typeSym := syms.find |s| { s.kind == SymbolKind.type }
    if (typeSym == null) return null
    return extractBaseTypeFromFile(typeSym.fileUri, typeName)
  }

  **
  ** Extract the base type name from a file's class declaration.
  ** Reads the source and finds "class TypeName : BaseType" pattern.
  **
  private Str? extractBaseTypeFromFile(Str fileUri, Str typeName)
  {
    try
    {
      // Try to read from actual file first, then fall back to indexed source
      Str? source := null
      normalizedUri := LspUtil.normalizeFileUri(fileUri)
      file := sourceFiles.find |f| { LspUtil.fileToUri(f) == normalizedUri }
      if (file != null && file.exists)
        source = file.readAllStr
      else
      {
        // Fall back to indexed source (for unit tests / in-memory indexing)
        idxFile := fileIndexes[fileUri]
        if (idxFile != null && idxFile.source.size > 0)
          source = idxFile.source
      }
      if (source == null) return null
      lines := source.splitLines

      for (i := 0; i < lines.size; i++)
      {
        line := lines[i].trim
        // Look for "class TypeName :" or "mixin TypeName :"
        classIdx := line.index("class ")
        mixinIdx := line.index("mixin ")
        if (classIdx == null && mixinIdx == null) continue

        // Check if this line declares the type we're looking for
        if (!line.contains(typeName)) continue

        // Find the colon
        colonIdx := line.index(":")
        if (colonIdx == null) continue
        // Skip := (walrus operator)
        if (colonIdx + 1 < line.size && line[colonIdx + 1] == '=') continue

        // Extract the first base type after the colon
        afterColon := line[colonIdx + 1 ..-1].trim
        // Remove trailing {
        if (afterColon.endsWith("{"))
          afterColon = afterColon[0 ..< afterColon.size - 1].trim
        // Take first type (before comma if multiple)
        commaIdx := afterColon.index(",")
        if (commaIdx != null) afterColon = afterColon[0 ..< commaIdx].trim

        if (afterColon.size > 0 && afterColon[0].isUpper)
          return afterColon

      }
    }
    catch (Err e) {}
    return null
  }

  **
  ** Get all type names in the index (for completion).
  **
  Str[] allTypeNames()
  {
    result := Str[,]
    symbolsByName.each |syms, name|
    {
      if (syms.any |s| { s.kind == SymbolKind.type })
        result.add(name)
    }
    return result
  }

  **
  ** Find all symbols with a given name.
  **
  IndexedSymbol[] findSymbols(Str name)
  {
    return symbolsByName[name] ?: IndexedSymbol[,]
  }

  **
  ** Scope-aware definition lookup.
  ** Finds the best matching symbol for a name at a given cursor position.
  **
  IndexedSymbol? findDefinition(Str name, Str fileUri, Int line, Int col)
  {
    candidates := findSymbols(name)
    if (candidates.isEmpty) return null

    // Determine which type and method the cursor is inside
    cursorType := findEnclosingType(fileUri, line)
    cursorMethod := findEnclosingMethod(fileUri, line)

    best := null as IndexedSymbol
    bestPriority := Int.maxVal

    candidates.each |sym|
    {
      priority := scorePriority(sym, fileUri, line, cursorType, cursorMethod)
      if (priority < bestPriority)
      {
        bestPriority = priority
        best = sym
      }
    }

    return best
  }

  **
  ** Run "fan build.fan" and parse its output for diagnostics.
  ** Returns a map of file URI -> diagnostic list.
  **
  Str:LspDiagnostic[] buildAndCollectDiagnostics()
  {
    result := Str:LspDiagnostic[][:]
    if (baseDir == null) return result

    try
    {
      buildFan := baseDir + `build.fan`
      if (!buildFan.exists) return result

      // Get fan executable from current Fantom environment (fan.bat on Windows)
      isWindows := Env.cur.os == "win32"
      fanBin := isWindows ? `bin/fan.bat` : `bin/fan`
      fanExe := Env.cur.homeDir + fanBin
      LspProtocol.logInfo("ProjectIndex: running ${fanExe.osPath} ${buildFan.osPath}")

      // Redirect output to temp file (stdout is the LSP protocol stream)
      tmpFile := File.createTemp("lsp-build-", ".log")
      try
      {
        outStream := tmpFile.out
        p := Process([fanExe.osPath, buildFan.osPath])
        p.dir = baseDir
        p.mergeErr = true
        p.out = outStream
        p.run
        p.join
        outStream.flush.close

        output := tmpFile.readAllStr
        LspProtocol.logInfo("ProjectIndex: build output ${output.size} chars")

        output.splitLines.each |line|
        {
          parsed := parseBuildError(line)
          if (parsed != null)
          {
            fileUri := parsed["uri"] as Str
            diag := parsed["diagnostic"] as LspDiagnostic
            if (fileUri != null && diag != null)
            {
              if (!result.containsKey(fileUri))
                result[fileUri] = LspDiagnostic[,]
              result[fileUri].add(diag)
            }
          }
        }
      }
      finally
      {
        try { tmpFile.delete } catch {}
      }

      LspProtocol.logInfo("ProjectIndex: build found ${result.size} files with diagnostics")
    }
    catch (Err e)
    {
      LspProtocol.logInfo("ProjectIndex: build error: $e")
    }

    return result
  }

  // ---- Private: Indexing ----

  **
  ** Index a single file and add symbols to the maps.
  **
  private Void doIndex(Str fileUri, Str source)
  {
    idx := FileIndex { it.fileUri = fileUri; it.source = source }

    // Try AST-based indexing first
    if (indexFromAst(fileUri, source, idx))
    {
      fileIndexes[fileUri] = idx
      idx.symbols.each |sym|
      {
        list := symbolsByName[sym.name]
        if (list == null) symbolsByName[sym.name] = IndexedSymbol[sym]
        else list.add(sym)
      }
      return
    }

    // Fallback: text-based line-by-line scanning
    lines := source.splitLines

    currentType := null as Str
    currentTypeStartLine := -1
    currentTypeIsEnum := false
    currentMethod := null as Str
    currentMethodStartLine := -1
    braceDepth := 0
    typeBraceDepth := -1
    methodBraceDepth := -1

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      trimmed := line.trim

      // Skip empty lines and comments
      if (trimmed.isEmpty || trimmed.startsWith("//") || trimmed.startsWith("**")) continue

      // Track using statements
      if (trimmed.startsWith("using "))
      {
        rest := trimmed[6..-1].trim
        colonIdx := rest.index("::")
        podName := colonIdx != null ? rest[0..<colonIdx] : rest
        if (podName.size > 0 && !idx.usingPods.contains(podName))
          idx.usingPods.add(podName)
      }

      // Track brace depth changes for this line
      lineOpenBraces := countChar(line, '{')
      lineCloseBraces := countChar(line, '}')

      // Detect type declarations: class Foo, mixin Foo, enum class Foo
      typeMatch := matchTypeDecl(trimmed)
      if (typeMatch != null && currentType == null)
      {
        currentType = typeMatch
        currentTypeStartLine = i
        currentTypeIsEnum = trimmed.contains("enum ")
        typeBraceDepth = braceDepth
        col := findIdentCol(line, typeMatch)
        idx.symbols.add(IndexedSymbol
        {
          it.name = typeMatch
          it.kind = SymbolKind.type
          it.fileUri = fileUri
          it.line = i
          it.col = col
          it.doc = extractDocComment(lines, i)
        })

        // Handle single-line enum: enum class Foo { a, b, c }
        if (currentTypeIsEnum && lineOpenBraces > 0 && lineOpenBraces == lineCloseBraces)
        {
          openIdx := trimmed.index("{")
          closeIdx := trimmed.indexr("}")
          if (openIdx != null && closeIdx != null && closeIdx > openIdx + 1)
          {
            body := trimmed[openIdx + 1 ..< closeIdx].trim
            body.split(',').each |part|
            {
              valName := part.trim
              // Strip constructor args if any: "red(0xFF)" -> "red"
              parenIdx := valName.index("(")
              if (parenIdx != null) valName = valName[0 ..< parenIdx].trim
              if (valName.size > 0 && valName[0].isAlpha)
              {
                idx.symbols.add(IndexedSymbol
                {
                  it.name = valName
                  it.kind = SymbolKind.enumVal
                  it.typeName = typeMatch
                  it.fileUri = fileUri
                  it.line = i
                  it.col = findIdentCol(line, valName)
                })
              }
            }
          }
        }
      }

      // Detect method declarations (inside a type)
      if (currentType != null && braceDepth == typeBraceDepth + 1)
      {
        methodMatch := matchMethodDecl(trimmed)
        if (methodMatch != null)
        {
          currentMethod = methodMatch
          currentMethodStartLine = i
          methodBraceDepth = braceDepth
          col := findIdentCol(line, methodMatch)
          idx.symbols.add(IndexedSymbol
          {
            it.name = methodMatch
            it.kind = SymbolKind.method
            it.typeName = currentType
            it.fileUri = fileUri
            it.line = i
            it.col = col
            it.doc = extractDocComment(lines, i)
            it.paramStr = extractParamStr(line)
          })

          // Parse method parameters
          parseMethodParams(line, currentType, methodMatch, fileUri, i, idx)
        }
      }

      // Detect field declarations (inside type, at type brace depth + 1, not inside a method)
      if (currentType != null && currentMethod == null && braceDepth == typeBraceDepth + 1)
      {
        // Detect enum values first (bare identifiers, possibly with trailing comma)
        if (currentTypeIsEnum)
        {
          enumVal := matchEnumValue(trimmed)
          if (enumVal != null)
          {
            col := findIdentCol(line, enumVal)
            idx.symbols.add(IndexedSymbol
            {
              it.name = enumVal
              it.kind = SymbolKind.enumVal
              it.typeName = currentType
              it.fileUri = fileUri
              it.line = i
              it.col = col
            })
          }
        }

        fieldMatch := matchFieldDecl(trimmed)
        if (fieldMatch != null)
        {
          col := findIdentCol(line, fieldMatch)
          fieldTypeStr := TypeResolver.extractDeclaredType(trimmed, fieldMatch)
          idx.symbols.add(IndexedSymbol
          {
            it.name = fieldMatch
            it.kind = SymbolKind.field
            it.typeName = currentType
            it.typeStr = fieldTypeStr
            it.fileUri = fileUri
            it.line = i
            it.col = col
            it.doc = extractDocComment(lines, i)
          })
        }
      }

      // Detect local variable declarations (inside a method)
      if (currentMethod != null && braceDepth > methodBraceDepth)
      {
        localMatch := matchLocalVarDecl(trimmed)
        if (localMatch != null)
        {
          col := findIdentCol(line, localMatch)
          idx.symbols.add(IndexedSymbol
          {
            it.name = localMatch
            it.kind = SymbolKind.localVar
            it.typeName = currentType
            it.methodName = currentMethod
            it.fileUri = fileUri
            it.line = i
            it.col = col
          })
        }

        // Detect closure parameters: |paramName| or |Type paramName|
        closureParams := matchClosureParams(line)
        closureParams.each |paramName|
        {
          col := findIdentCol(line, paramName)
          idx.symbols.add(IndexedSymbol
          {
            it.name = paramName
            it.kind = SymbolKind.param
            it.typeName = currentType
            it.methodName = currentMethod
            it.fileUri = fileUri
            it.line = i
            it.col = col
          })
        }
      }

      // Update brace depth
      braceDepth = braceDepth + lineOpenBraces - lineCloseBraces

      // Check if we exited the method scope.
      // Either on a later line, or on the same line if braces are balanced
      // (e.g., "Void foo() { doStuff() }")
      sameLineBalancedMethod := (i == currentMethodStartLine && lineOpenBraces > 0 && lineOpenBraces == lineCloseBraces)
      if (currentMethod != null && braceDepth <= methodBraceDepth &&
          (i > currentMethodStartLine || sameLineBalancedMethod))
      {
        currentMethod = null
        currentMethodStartLine = -1
        methodBraceDepth = -1
      }

      // Check if we exited the type scope.
      // Either on a later line, or on the same line if braces are balanced
      // (e.g., "enum class Foo { a, b, c }")
      sameLineBalancedType := (i == currentTypeStartLine && lineOpenBraces > 0 && lineOpenBraces == lineCloseBraces)
      if (currentType != null && braceDepth <= typeBraceDepth &&
          (i > currentTypeStartLine || sameLineBalancedType))
      {
        currentType = null
        currentTypeStartLine = -1
        currentTypeIsEnum = false
        typeBraceDepth = -1
        currentMethod = null
        methodBraceDepth = -1
      }
    }

    // Store the file index
    fileIndexes[fileUri] = idx

    // Add symbols to the name lookup map
    idx.symbols.each |sym|
    {
      list := symbolsByName[sym.name]
      if (list == null)
      {
        symbolsByName[sym.name] = IndexedSymbol[sym]
      }
      else
      {
        list.add(sym)
      }
    }
  }

  // ---- Private: AST-based indexing ----

  **
  ** Index a file using the compiler AST via AstIndex wrapper.
  ** Returns true if AST parsing succeeded, false to fallback to text.
  **
  private Bool indexFromAst(Str fileUri, Str source, FileIndex idx)
  {
    ast := AstIndex.parse(fileUri, source)
    if (ast == null) return false

    srcLines := source.splitLines

    // Extract using pods
    ast.usings.each |u|
    {
      if (!idx.usingPods.contains(u.podName))
        idx.usingPods.add(u.podName)
    }

    // Walk types
    ast.types.each |AstType t|
    {
      typeName := t.name

      // Index the type itself
      idx.symbols.add(IndexedSymbol
      {
        it.name = typeName
        it.kind = SymbolKind.type
        it.fileUri = fileUri
        it.line = t.line
        it.col = t.col
        it.doc = extractDocComment(srcLines, t.line)
      })

      // Store base type
      if (t.baseType != null)
        baseTypeByType[typeName] = t.baseType

      // Index enum values
      t.enumVals.each |AstEnumVal ev|
      {
        idx.symbols.add(IndexedSymbol
        {
          it.name = ev.name
          it.kind = SymbolKind.enumVal
          it.typeName = typeName
          it.fileUri = fileUri
          it.line = ev.line
          it.col = ev.col
          it.doc = extractDocComment(srcLines, ev.line)
        })
      }

      // Index fields
      t.fields.each |AstSlot f|
      {
        idx.symbols.add(IndexedSymbol
        {
          it.name = f.name
          it.kind = SymbolKind.field
          it.typeName = typeName
          it.fileUri = fileUri
          it.line = f.line
          it.col = f.col
          it.typeStr = f.typeName
          it.doc = extractDocComment(srcLines, f.line)
        })
      }

      // Index methods
      t.methods.each |AstSlot m|
      {
        // Build param string from AstSlot params
        pStr := m.params.isEmpty ? null :
          m.params.map |p| { p.typeName != null ? "${p.typeName} ${p.name}" : p.name }.join(", ")

        idx.symbols.add(IndexedSymbol
        {
          it.name = m.name
          it.kind = SymbolKind.method
          it.typeName = typeName
          it.fileUri = fileUri
          it.line = m.line
          it.col = m.col
          it.typeStr = m.typeName
          it.doc = extractDocComment(srcLines, m.line)
          it.paramStr = pStr
        })

        // Index method params
        m.params.each |AstParam p|
        {
          idx.symbols.add(IndexedSymbol
          {
            it.name = p.name
            it.kind = SymbolKind.param
            it.typeName = typeName
            it.methodName = m.name
            it.fileUri = fileUri
            it.line = p.line
            it.col = p.col
            it.typeStr = p.typeName
          })
        }

        // Index local variables and closure params
        m.localVars.each |AstLocalVar lv|
        {
          idx.symbols.add(IndexedSymbol
          {
            it.name = lv.name
            it.kind = lv.isClosureParam ? SymbolKind.param : SymbolKind.localVar
            it.typeName = typeName
            it.methodName = m.name
            it.fileUri = fileUri
            it.line = lv.line
            it.col = lv.col
            it.typeStr = lv.typeName
          })
        }
      }
    }

    return true
  }

  // ---- Private: Pattern Matching ----

  ** Match closure parameters from |param| or |Type param, Type param2| patterns.
  ** Returns a list of parameter names found in the line.
  ** Handles: |name|, |Type name|, |Type name, Type name2|, |Type name -> RetType|
  private Str[] matchClosureParams(Str line)
  {
    result := Str[,]
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
      // Skip single-line comments
      if (pos + 1 < line.size && line[pos] == '/' && line[pos + 1] == '/')
        break

      if (line[pos] == '|')
      {
        pipeStart := pos
        pos++

        // Find the closing pipe (or ->)
        pipeEnd := null as Int
        depth := 0
        scanPos := pos
        while (scanPos < line.size)
        {
          ch := line[scanPos]
          if (ch == '(' || ch == '[' || ch == '<') depth++
          else if (ch == ')' || ch == ']' || ch == '>') depth--
          else if (ch == '|' && depth == 0) { pipeEnd = scanPos; break }
          else if (ch == '-' && scanPos + 1 < line.size && line[scanPos + 1] == '>'
                   && depth == 0) { pipeEnd = scanPos; break }
          scanPos++
        }

        if (pipeEnd == null) { continue }

        // Extract the content between pipes
        inner := line[pos ..< pipeEnd].trim
        if (inner.isEmpty) { pos = pipeEnd + 1; continue }

        // Split by comma and extract param names
        parts := Str[,]
        partDepth := 0
        current := StrBuf()
        for (j := 0; j < inner.size; j++)
        {
          ch := inner[j]
          if (ch == '(' || ch == '[' || ch == '<' || ch == '|') partDepth++
          else if (ch == ')' || ch == ']' || ch == '>') partDepth--
          else if (ch == ',' && partDepth == 0)
          {
            parts.add(current.toStr.trim)
            current.clear
            continue
          }
          current.addChar(ch)
        }
        if (current.size > 0) parts.add(current.toStr.trim)

        parts.each |part|
        {
          p := part.trim
          if (p.isEmpty) return

          // Remove default value: "Type name := default"
          defIdx := p.index(":=")
          if (defIdx != null) p = p[0 ..< defIdx].trim

          // Split by space: "Type name" or just "name"
          words := p.split(' ').findAll |w| { w.size > 0 }
          if (words.size == 0) return

          // Last word is the param name
          paramName := words[-1]
          // Validate it's a valid identifier starting with lowercase
          if (paramName.size > 0 && paramName[0].isLower && isIdentifier(paramName))
            result.add(paramName)
        }

        pos = pipeEnd + 1
        continue
      }
      pos++
    }
    return result
  }

  ** Match an enum value: a bare lowercase identifier, optionally followed by comma or parens.
  ** E.g. "heating," or "dxIntesis64" or "red(0xFF0000)"
  private Str? matchEnumValue(Str trimmed)
  {
    // Skip comments, annotations, keywords
    if (trimmed.startsWith("//") || trimmed.startsWith("**") ||
        trimmed.startsWith("@") || trimmed.startsWith("{") ||
        trimmed.startsWith("}")) return null

    // Skip lines that look like field/method declarations (have a type before identifier)
    // Enum values are bare identifiers: "heating," or "heating"
    // Skip if line contains assignment (:= or =) — that's a field
    if (trimmed.contains(":=") || trimmed.contains(" := ")) return null

    // Extract leading identifier
    nameEnd := 0
    while (nameEnd < trimmed.size && (trimmed[nameEnd].isAlphaNum || trimmed[nameEnd] == '_'))
      nameEnd++
    if (nameEnd == 0) return null

    name := trimmed[0 ..< nameEnd]

    // Enum values are bare identifiers — skip Fantom keywords
    keywords := ["class", "mixin", "enum", "static", "const", "new",
                 "public", "private", "protected", "internal",
                 "abstract", "virtual", "override", "native",
                 "return", "if", "else", "for", "while", "try", "catch", "finally",
                 "switch", "case", "throw", "using", "Void", "Bool", "Int", "Str"]
    if (keywords.contains(name)) return null

    // After the name, expect end of line, comma, or opening paren (constructor args)
    rest := trimmed[nameEnd ..-1].trim
    if (rest.isEmpty || rest[0] == ',' || rest[0] == '(') return name

    return null
  }

  ** Match a type declaration: class Foo, mixin Foo, enum class Foo
  private Str? matchTypeDecl(Str trimmed)
  {
    // Patterns: "class Name", "mixin Name", "enum class Name"
    keywords := ["class ", "mixin "]
    for (i := 0; i < keywords.size; i++)
    {
      idx := trimmed.index(keywords[i])
      if (idx == null) continue

      // Extract the name after the keyword
      afterKeyword := trimmed[idx + keywords[i].size..-1].trim
      name := extractIdentifier(afterKeyword)
      if (name != null && name.size > 0 && name[0].isUpper)
        return name
    }
    return null
  }

  ** Match a method declaration: RetType name(, new make(, Void name(
  private Str? matchMethodDecl(Str trimmed)
  {
    // Skip comments, annotations
    if (trimmed.startsWith("//") || trimmed.startsWith("@") ||
        trimmed.startsWith("*") || trimmed.startsWith("{") ||
        trimmed.startsWith("}")) return null

    // Look for pattern: word( where word is preceded by a type or modifier
    parenIdx := trimmed.index("(")
    if (parenIdx == null || parenIdx == 0) return null

    // Get everything before the paren
    beforeParen := trimmed[0..<parenIdx].trim

    // Extract the last word (method name)
    lastSpace := beforeParen.indexr(" ")
    if (lastSpace == null) return null

    methodName := beforeParen[lastSpace + 1..-1]
    if (methodName.isEmpty) return null

    // Method name must be an identifier (can start with upper or lowercase)
    if (!methodName[0].isAlpha && methodName[0] != '_') return null

    // Check that what's before is a type or modifier (not a method call like "obj.foo(")
    beforeName := beforeParen[0..<lastSpace].trim
    if (beforeName.isEmpty) return null

    // Should end with an identifier char, '?' (nullable), or ']' (list/map types)
    lastChar := beforeName[-1]
    if (!lastChar.isAlpha && lastChar != '?' && lastChar != ']') return null

    return methodName
  }

  ** Match a field declaration: Type name or Type? name (with optional modifiers)
  private Str? matchFieldDecl(Str trimmed)
  {
    // Skip comments, annotations, method-like lines, control flow
    if (trimmed.startsWith("//") || trimmed.startsWith("@") ||
        trimmed.startsWith("*") || trimmed.startsWith("{") ||
        trimmed.startsWith("}") || trimmed.startsWith("return ") ||
        trimmed.startsWith("if ") || trimmed.startsWith("for ") ||
        trimmed.startsWith("while ") || trimmed.startsWith("throw "))
      return null

    // Check for "(" only in the declaration part (before :=).
    // Parentheses in the initializer (e.g., User(args)) are fine.
    declPart := trimmed
    walrusIdx := trimmed.index(":=")
    if (walrusIdx != null)
      declPart = trimmed[0 ..< walrusIdx]
    if (declPart.contains("(")) return null

    // Look for pattern: [modifiers] Type fieldName [:= ...]
    // Split by spaces and find a Type followed by a name
    parts := splitWords(declPart)
    if (parts.size < 2) return null

    // Find the last pair that looks like "Type name"
    for (i := parts.size - 1; i >= 1; i--)
    {
      name := parts[i]
      typePart := parts[i - 1]

      // Remove trailing := if present
      if (name.endsWith(":=")) name = name[0..<name.size - 2]
      // Remove nullable ? from type
      cleanType := typePart.endsWith("?") ? typePart[0..<typePart.size - 1] : typePart

      // Type must start with uppercase or '[' (bracket map/list types like [Str:Obj?])
      if (cleanType.size > 0 && (cleanType[0].isUpper || cleanType[0] == '[') &&
          name.size > 0 && isIdentifier(name))
        return name
    }

    return null
  }

  ** Match a local variable declaration: name := ... (walrus operator)
  private Str? matchLocalVarDecl(Str trimmed)
  {
    // Skip comments
    if (trimmed.startsWith("//") || trimmed.startsWith("*")) return null

    // Look for ":=" (walrus operator)
    walrusIdx := trimmed.index(":=")
    if (walrusIdx == null || walrusIdx == 0) return null

    beforeWalrus := trimmed[0..<walrusIdx].trim

    // Simple case: "name :=" — extract the last identifier before :=
    parts := splitWords(beforeWalrus)
    if (parts.isEmpty) return null

    // The variable name is the last word before :=
    name := parts[-1]
    if (!isIdentifier(name) || name.isEmpty) return null

    // If name starts with uppercase, it's a type (e.g., "Type name :="), take the one before
    if (name[0].isUpper && parts.size >= 2)
    {
      // Actually this means "Type name :=" — the variable is the last word,
      // but we already handled that. Let's just return names starting with lowercase.
      return null
    }

    // Skip if it's an assignment to existing field (e.g., "this.field :=")
    if (beforeWalrus.contains(".")) return null

    return name
  }

  ** Parse method parameters from a method declaration line
  private Void parseMethodParams(Str line, Str typeName, Str methodName,
                                  Str fileUri, Int lineNum, FileIndex idx)
  {
    try
    {
      parenOpen := line.index("(")
      if (parenOpen == null) return

      parenClose := line.index(")", parenOpen)
      if (parenClose == null) return

      paramStr := line[parenOpen + 1 ..< parenClose].trim
      if (paramStr.isEmpty) return

      // Split by comma
      paramParts := paramStr.split(',')
      paramParts.each |part|
      {
        p := part.trim
        if (p.isEmpty) return

        // Pattern: "Type name" or "Type? name" or "Type name := default"
        words := splitWords(p)
        if (words.size >= 2)
        {
          paramName := words[1]
          // Remove default value part
          eqIdx := paramName.index(":=")
          if (eqIdx != null) paramName = paramName[0..<eqIdx]

          if (isIdentifier(paramName) && paramName.size > 0)
          {
            col := findIdentCol(line, paramName)
            idx.symbols.add(IndexedSymbol
            {
              it.name = paramName
              it.kind = SymbolKind.param
              it.typeName = typeName
              it.methodName = methodName
              it.fileUri = fileUri
              it.line = lineNum
              it.col = col
            })
          }
        }
      }
    }
    catch (Err e) {}
  }

  // ---- Private: Priority Scoring ----

  ** Score the priority of a symbol match (lower = better)
  private Int scorePriority(IndexedSymbol sym, Str fileUri, Int line,
                             Str? cursorType, Str? cursorMethod)
  {
    sameFile := sym.fileUri == fileUri
    sameType := sameFile && sym.typeName != null && sym.typeName == cursorType
    sameMethod := sameType && sym.methodName != null && sym.methodName == cursorMethod

    switch (sym.kind)
    {
      case SymbolKind.localVar:
        if (sameMethod && sym.line <= line) return 0
        if (sameFile) return 50
        return 100
      case SymbolKind.param:
        if (sameMethod) return 1
        if (sameFile) return 51
        return 100
      case SymbolKind.field:
        if (sameType) return 2
        if (sameFile) return 5
        return 10
      case SymbolKind.method:
        if (sameType) return 3
        if (sameFile) return 6
        return 11
      case SymbolKind.enumVal:
        if (sameType) return 2
        if (sameFile) return 5
        return 10
      case SymbolKind.type:
        if (sameFile) return 4
        return 12
      default:
        return 50
    }
  }

  ** Find the enclosing type name at a given line in a file
  private Str? findEnclosingType(Str fileUri, Int line)
  {
    idx := fileIndexes[fileUri]
    if (idx == null) return null

    best := null as Str
    bestLine := -1

    idx.symbols.each |sym|
    {
      if (sym.kind == SymbolKind.type && sym.line <= line && sym.line > bestLine)
      {
        best = sym.name
        bestLine = sym.line
      }
    }
    return best
  }

  ** Find the enclosing method name at a given line in a file
  private Str? findEnclosingMethod(Str fileUri, Int line)
  {
    idx := fileIndexes[fileUri]
    if (idx == null) return null

    best := null as Str
    bestLine := -1

    idx.symbols.each |sym|
    {
      if (sym.kind == SymbolKind.method && sym.line <= line && sym.line > bestLine)
      {
        best = sym.name
        bestLine = sym.line
      }
    }
    return best
  }

  // ---- Private: Build Output Parsing ----

  ** Parse a single line of build output for compiler errors
  **
  ** Parse a single build output line for error/warning info.
  ** Returns map with "uri" and "diagnostic" keys, or null if not an error line.
  **
  [Str:Obj]? parseBuildErrorLine(Str line) { return parseBuildError(line) }

  private [Str:Obj]? parseBuildError(Str line)
  {
    try
    {
      parenIdx := line.index("(")
      if (parenIdx == null || parenIdx == 0) return null

      closeParenIdx := line.index(")", parenIdx)
      if (closeParenIdx == null) return null

      colonIdx := line.index(":", closeParenIdx)
      if (colonIdx == null) return null

      filePath := line[0..<parenIdx]
      if (!filePath.endsWith(".fan")) return null

      lineCol := line[parenIdx + 1 ..< closeParenIdx]
      commaIdx := lineCol.index(",")
      if (commaIdx == null) return null

      errLine := 1; errCol := 1
      try
      {
        errLine = Int.fromStr(lineCol[0..<commaIdx].trim)
        errCol = Int.fromStr(lineCol[commaIdx + 1 .. -1].trim)
      }
      catch (Err e) { return null }

      message := line[colonIdx + 1 .. -1].trim
      if (message.isEmpty) return null

      severity := DiagnosticSeverity.error
      if (message.startsWith("WARN ") || message.startsWith("Warn "))
        severity = DiagnosticSeverity.warning

      // Convert file path to proper URI (handles Windows backslashes)
      fileUri := LspUtil.pathToFileUri(filePath)

      range := LspRange(
        LspPosition(errLine - 1, errCol - 1),
        LspPosition(errLine - 1, errCol)
      )
      diag := LspDiagnostic(range, severity, message, "fantom")

      return Str:Obj["uri": fileUri, "diagnostic": diag]
    }
    catch (Err e) { return null }
  }

  // ---- Private: build.fan Parsing ----

  ** Parse podName from build.fan content
  private Str? parsePodName(Str content)
  {
    try
    {
      idx := content.index("podName")
      if (idx == null) return null
      eqIdx := content.index("=", idx)
      if (eqIdx == null) return null
      quoteIdx := content.index("\"", eqIdx)
      if (quoteIdx == null) return null
      endQuoteIdx := content.index("\"", quoteIdx + 1)
      if (endQuoteIdx == null) return null
      name := content[quoteIdx + 1 ..< endQuoteIdx].trim
      return name.isEmpty ? null : name
    }
    catch (Err e) { return null }
  }

  ** Parse srcDirs from build.fan content
  private Uri[] parseSrcDirs(Str content)
  {
    try
    {
      idx := content.index("srcDirs")
      if (idx == null) return Uri[,]
      openBracket := content.index("[", idx)
      if (openBracket == null) return Uri[,]
      closeBracket := content.index("]", openBracket)
      if (closeBracket == null) return Uri[,]

      dirList := content[openBracket + 1 ..< closeBracket]
      uris := Uri[,]
      dirList.split(',').each |part|
      {
        cleaned := part.trim.replace("`", "").replace("\"", "").replace("'", "").trim
        if (cleaned.size > 0)
          uris.add(Uri.decode(cleaned))
      }
      return uris
    }
    catch (Err e) { return Uri[,] }
  }

  // ---- Private: Multi-Pod Discovery ----

  **
  ** Discover all pods in the workspace by walking the directory tree.
  ** If a build.all exists at rootDir, parse its children first.
  ** Always walks the full tree so nested pods are found regardless.
  **
  private PodInfo[] discoverPods(File rootDir)
  {
    result := PodInfo[,]

    // Check for build.all (BuildGroup orchestrator) at the workspace root
    buildAll := rootDir + `build.all`
    if (buildAll.exists)
    {
      LspProtocol.logInfo("ProjectIndex: found build.all at ${buildAll.osPath}")
      result.addAll(discoverFromBuildAll(buildAll, rootDir))
    }

    // Walk the full tree to catch any pods not listed in build.all,
    // and to handle the common case of no build.all at all.
    collectBuildFans(rootDir, result)

    // Remove duplicates (same baseDir discovered via both build.all and tree walk)
    seen := Str:Bool[:]
    unique := PodInfo[,]
    result.each |pod|
    {
      key := pod.baseDir.osPath
      if (!seen.containsKey(key))
      {
        seen[key] = true
        unique.add(pod)
      }
    }

    LspProtocol.logInfo("ProjectIndex: discoverPods found ${unique.size} pod(s)")
    return unique
  }

  **
  ** Recursively collect PodInfo from all build.fan files under dir.
  ** Skips VCS and well-known non-pod directories.
  **
  private Void collectBuildFans(File dir, PodInfo[] result)
  {
    // Check this directory for a build.fan
    buildFan := dir + `build.fan`
    if (buildFan.exists)
    {
      pod := createPodInfo(buildFan)
      if (pod != null) result.add(pod)
    }

    // Recurse into subdirectories
    try
    {
      dir.listDirs.each |subDir|
      {
        if (!isPodDiscoverySkippedDir(subDir.name))
          collectBuildFans(subDir, result)
      }
    }
    catch (Err e)
    {
      LspProtocol.logInfo("ProjectIndex: error listing ${dir.osPath}: $e")
    }
  }

  **
  ** Discover pods listed in a build.all (BuildGroup) file.
  **
  private PodInfo[] discoverFromBuildAll(File buildAll, File rootDir)
  {
    result := PodInfo[,]
    try
    {
      content := buildAll.readAllStr
      children := parseBuildAllChildren(content, rootDir)
      children.each |childDir|
      {
        buildFan := childDir + `build.fan`
        if (buildFan.exists)
        {
          pod := createPodInfo(buildFan)
          if (pod != null) result.add(pod)
        }
      }
      LspProtocol.logInfo("ProjectIndex: discoverFromBuildAll found ${result.size} pod(s)")
    }
    catch (Err e)
    {
      LspProtocol.logInfo("ProjectIndex: error parsing build.all: $e")
    }
    return result
  }

  **
  ** Create a PodInfo from a build.fan file.
  ** Returns null if the file is a BuildGroup (not a pod) or has no podName.
  **
  private PodInfo? createPodInfo(File buildFanFile)
  {
    try
    {
      content := buildFanFile.readAllStr

      // Skip BuildGroup files — they orchestrate other pods, not pods themselves
      if (content.contains("BuildGroup") && !content.contains("BuildPod"))
        return null

      // Must have a podName to be a buildable pod
      name := parsePodName(content)
      if (name == null) return null

      dir := buildFanFile.parent
      srcs := parseSrcDirs(content)
      deps := parseDependencies(content)

      // Collect .fan source files from each srcDir
      files := File[,]
      srcs.each |uri|
      {
        srcDir := dir.plus(uri, false)
        if (srcDir.exists && srcDir.isDir)
          srcDir.walk |f|
          {
            if (!f.isDir && f.ext == "fan") files.add(f)
          }
      }
      // Include build.fan itself so it can be opened/navigated in the IDE
      files.add(buildFanFile)

      return PodInfo
      {
        it.baseDir     = dir
        it.buildFan    = buildFanFile
        it.podName     = name
        it.srcDirs     = srcs
        it.depends     = deps
        it.sourceFiles = files
      }
    }
    catch (Err e)
    {
      LspProtocol.logInfo("ProjectIndex: error in createPodInfo(${buildFanFile.osPath}): $e")
      return null
    }
  }

  **
  ** Parse the 'depends' list from build.fan content.
  ** Returns pod names with version numbers stripped.
  ** E.g. ["sys 1.0", "compiler 1.0"] -> ["sys", "compiler"]
  **
  private Str[] parseDependencies(Str content)
  {
    try
    {
      idx := content.index("depends")
      if (idx == null) return Str[,]
      openBracket := content.index("[", idx)
      if (openBracket == null) return Str[,]
      closeBracket := content.index("]", openBracket)
      if (closeBracket == null) return Str[,]

      depList := content[openBracket + 1 ..< closeBracket]
      result := Str[,]
      depList.split(',').each |part|
      {
        cleaned := part.trim.replace("`", "").replace("\"", "").replace("'", "").trim
        if (cleaned.isEmpty) return
        // Strip version: "sys 1.0" → "sys"
        spaceIdx := cleaned.index(" ")
        name := spaceIdx != null ? cleaned[0 ..< spaceIdx].trim : cleaned
        if (name.size > 0) result.add(name)
      }
      return result
    }
    catch (Err e) { return Str[,] }
  }

  **
  ** Parse the 'children' list from a build.all (BuildGroup) file.
  ** Returns the child directories as File objects.
  **
  private File[] parseBuildAllChildren(Str content, File rootDir)
  {
    try
    {
      idx := content.index("children")
      if (idx == null) return File[,]
      openBracket := content.index("[", idx)
      if (openBracket == null) return File[,]
      closeBracket := content.index("]", openBracket)
      if (closeBracket == null) return File[,]

      childList := content[openBracket + 1 ..< closeBracket]
      result := File[,]
      childList.split(',').each |part|
      {
        cleaned := part.trim.replace("`", "").replace("\"", "").replace("'", "").trim
        if (cleaned.isEmpty) return
        childDir := rootDir.plus(Uri.decode(cleaned), false)
        if (childDir.exists && childDir.isDir)
          result.add(childDir)
      }
      return result
    }
    catch (Err e) { return File[,] }
  }

  **
  ** Return true if this directory name should be skipped during pod discovery.
  **
  private static Bool isPodDiscoverySkippedDir(Str name)
  {
    // Skip VCS directories
    if (name == ".git" || name == ".hg" || name == ".svn") return true
    // Skip JS package directories
    if (name == "node_modules") return true
    // Skip Fantom lib directory (contains compiled .pod files, not source)
    if (name == "lib") return true
    // Skip any hidden directories
    if (name.startsWith(".")) return true
    return false
  }

  // ---- Private: Utilities ----

  private Int countChar(Str line, Int ch)
  {
    count := 0
    inStr := false
    inLineComment := false
    for (i := 0; i < line.size; i++)
    {
      c := line[i]
      if (inLineComment) break
      if (c == '/' && i + 1 < line.size && line[i+1] == '/') inLineComment = true
      if (c == '"') inStr = !inStr
      if (!inStr && c == ch) count++
    }
    return count
  }

  private Str? extractIdentifier(Str text)
  {
    end := 0
    while (end < text.size && (text[end].isAlphaNum || text[end] == '_')) end++
    return end > 0 ? text[0..<end] : null
  }

  private Int findIdentCol(Str line, Str name)
  {
    idx := line.index(name)
    return idx ?: 0
  }

  private Str[] splitWords(Str text)
  {
    return text.split(' ').findAll |w| { w.size > 0 }
  }

  private Bool isIdentifier(Str text)
  {
    if (text.isEmpty) return false
    if (!text[0].isAlpha && text[0] != '_') return false
    for (i := 1; i < text.size; i++)
    {
      if (!text[i].isAlphaNum && text[i] != '_') return false
    }
    return true
  }

  **
  ** Extract doc comment text from source lines above a given 0-based line number.
  ** Scans backwards collecting ** comment lines, skipping blank lines.
  ** Returns null if no doc comment found.
  **
  static Str? extractDocComment(Str[] lines, Int lineNum)
  {
    if (lineNum <= 0 || lineNum >= lines.size) return null

    docLines := Str[,]
    i := lineNum - 1

    // Skip blank lines between symbol and doc comment
    while (i >= 0 && lines[i].trim.isEmpty) i--

    // Collect ** lines
    while (i >= 0)
    {
      trimmed := lines[i].trim
      if (trimmed.startsWith("**"))
      {
        // Strip leading ** and optional space
        text := trimmed[2..-1]
        if (text.startsWith(" ")) text = text[1..-1]
        docLines.insert(0, text)
        i--
      }
      else break
    }

    if (docLines.isEmpty) return null
    return docLines.join("\n").trim
  }

  **
  ** Build a parameter string from a method declaration line.
  ** Extracts text between ( and ) — e.g. "Str name, Int count".
  ** Returns null if no params found.
  **
  static Str? extractParamStr(Str line)
  {
    parenOpen := line.index("(")
    if (parenOpen == null) return null
    parenClose := line.index(")", parenOpen)
    if (parenClose == null) return null
    paramStr := line[parenOpen + 1 ..< parenClose].trim
    return paramStr.isEmpty ? null : paramStr
  }
}

**************************************************************************
** SymbolKind
**************************************************************************

enum class SymbolKind
{
  type,
  method,
  field,
  localVar,
  param,
  enumVal
}

**************************************************************************
** IndexedSymbol
**************************************************************************

class IndexedSymbol
{
  Str name := ""
  SymbolKind kind := SymbolKind.type
  Str? typeName
  Str? methodName
  Str fileUri := ""
  Int line := 0
  Int col := 0
  Str? typeStr  // resolved type name from AST (e.g. "Str", "Int")
  Str? doc      // doc comment text (from ** comments above symbol)
  Str? paramStr // method parameter signature (e.g. "Str name, Int count")
}

**************************************************************************
** FileIndex
**************************************************************************

class FileIndex
{
  Str fileUri := ""
  Str source := ""
  IndexedSymbol[] symbols := IndexedSymbol[,]
  Str[] usingPods := Str[,]
}

**************************************************************************
** PodInfo
**************************************************************************

**
** PodInfo holds metadata about a single Fantom pod discovered in the workspace.
** One PodInfo is created per build.fan file found during workspace initialisation.
**
class PodInfo
{
  ** Directory that contains this pod's build.fan
  File baseDir := File.os(".")

  ** The build.fan file for this pod
  File buildFan := File.os(".")

  ** Pod name parsed from build.fan (podName = "...")
  Str? podName

  ** Source directories parsed from build.fan (srcDirs = [...])
  Uri[] srcDirs := Uri[,]

  ** Dependency pod names parsed from build.fan (depends = [...])
  ** Version numbers are stripped: "sys 1.0" -> "sys"
  Str[] depends := Str[,]

  ** All .fan source files collected from srcDirs, plus the build.fan itself
  File[] sourceFiles := File[,]
}
