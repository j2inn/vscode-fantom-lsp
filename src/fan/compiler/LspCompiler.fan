
using compiler
using concurrent

**
** LspCompiler - Factory for creating compiler instances for LSP analysis
**
class LspCompiler
{
  ** Actor.locals key of the namespace shared by the compiles of a thread
  private static const Str namespaceKey := "vscodeFantomLsp.compilerNamespace"

  ** Incremented to make every thread recreate its shared namespace
  private static const AtomicInt namespaceGeneration := AtomicInt()

  **
  ** Create a compiler instance for analyzing a source file.
  ** When 'stubs' (stub sources keyed by file URI, see 'SourceStubber') are
  ** given, they are compiled alongside the file so project types resolve.
  **
  static Compiler create(Str uri, Str source, Str:Str stubs := Str:Str[:])
  {
    in := input(uri, source)
    c := stubs.isEmpty ? Compiler(in) : StubbedCompiler(in, stubs)
    sharedNamespace.lastCompiler = c
    return c
  }

  **
  ** Make every thread use a new compiler namespace for its next compile,
  ** so that pods changed on disk are reloaded.
  **
  static Void resetNamespaces()
  {
    namespaceGeneration.increment
  }

  **
  ** Build the single-file (script mode) compiler input for a source file.
  **
  static CompilerInput input(Str uri, Str source)
  {
    // Create a compiler log that writes to file instead of stdout
    logFile := LspUtil.tempDir + `fantom-lsp-compiler.log`
    log := CompilerLog(logFile.out(true))

    tempPodName := podNameFor(uri)
    LspProtocol.logInfo("Compiling as pod: $tempPodName")

    // Use single file compilation with pod name for script mode type resolution
    // This preserves correct line numbers for Go to Definition
    return CompilerInput
    {
      it.mode = CompilerInputMode.str
      it.srcStr = source
      it.srcStrLoc = Loc.make(uri)
      it.podName = tempPodName
      it.version = Version("1.0")
      it.summary = "LSP analysis"
      it.isScript = true  // Script mode allows loose type resolution
      it.output = CompilerOutputMode.transientPod
      it.log = log
      it.includeDoc = true
      it.ns = sharedNamespace.ns
    }
  }

  **
  ** Compiler namespace shared by the compiles of the current thread.
  ** A namespace caches the reflected types of the installed pods it loads;
  ** building them costs tens of milliseconds for large pods, so a new
  ** namespace per compile makes every analysis pay that cost. The types
  ** being compiled are never cached in the namespace. It is recreated after
  ** 'resetNamespaces', and after a compile that imported a Java FFI package,
  ** because FFI bridges are cached in the namespace but bound to the
  ** compiler that created them.
  **
  private static SharedNamespace sharedNamespace()
  {
    shared := Actor.locals[namespaceKey] as SharedNamespace
    generation := namespaceGeneration.val
    if (shared == null || shared.generation != generation || shared.lastCompilerUsedFfi)
    {
      shared = SharedNamespace(ReflectNamespace(), generation)
      Actor.locals[namespaceKey] = shared
    }
    return shared
  }

  **
  ** Pod name a file is compiled under: the pod name from build.fan when the
  ** file is inside the pod's srcDirs (types within the same pod visible),
  ** otherwise "lsp_temp" (so "using podName" can resolve).
  **
  static Str podNameFor(Str uri)
  {
    projectInfo := getProjectInfo(uri)
    podName := projectInfo["podName"] as Str
    srcDirs := projectInfo["srcDirs"] as Uri[]
    baseDir := projectInfo["baseDir"] as File

    if (podName == null) return "lsp_temp"
    if (baseDir == null || srcDirs == null) return podName
    return isFileInSrcDirs(uri, baseDir, srcDirs) ? podName : "lsp_temp"
  }

  **
  ** Get project information (podName, srcDirs, baseDir) from build.fan
  **
  private static Str:Obj? getProjectInfo(Str uri)
  {
    result := Str:Obj?[:]

    try
    {
      // Convert URI to File
      file := LspUtil.uriToFile(uri)

      // Walk up looking for build.fan
      dir := file.parent
      while (dir != null)
      {
        buildFan := dir + `build.fan`
        if (buildFan.exists)
        {
          LspProtocol.logInfo("Found build.fan at: ${buildFan.osPath}")

          // Parse build.fan
          content := buildFan.readAllStr

          // Extract podName
          podName := parsePodName(content)
          if (podName != null)
          {
            result["podName"] = podName
            result["baseDir"] = dir
            LspProtocol.logInfo("Found podName: $podName")

            // Extract srcDirs
            srcDirs := parseSrcDirs(content)
            if (!srcDirs.isEmpty)
            {
              result["srcDirs"] = srcDirs
              LspProtocol.logInfo("Found ${srcDirs.size} srcDirs")
            }
          }

          return result
        }
        dir = dir.parent
      }
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error getting project info: $e")
    }

    return result
  }

  **
  ** Check if a file URI is inside one of the srcDirs
  **
  private static Bool isFileInSrcDirs(Str uri, File baseDir, Uri[] srcDirs)
  {
    try
    {
      file := LspUtil.uriToFile(uri)
      filePath := file.normalize.osPath

      for (i := 0; i < srcDirs.size; i++)
      {
        srcDir := baseDir.plus(srcDirs[i], false)
        if (srcDir.exists && srcDir.isDir)
        {
          srcPath := srcDir.normalize.osPath
          isWin := Env.cur.os == "win32"
          if (isWin)
          {
            if (filePath.lower.startsWith(srcPath.lower))
              return true
          }
          else
          {
            if (filePath.startsWith(srcPath))
              return true
          }
        }
      }
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error checking srcDirs: $e")
    }
    return false
  }

  **
  ** Parse podName from build.fan content
  **
  private static Str? parsePodName(Str content)
  {
    try
    {
      // Look for podName = "..." pattern
      idx := content.index("podName")
      if (idx == null) return null

      // Find the equals sign
      eqIdx := content.index("=", idx)
      if (eqIdx == null) return null

      // Find the opening quote after equals
      quoteIdx := content.index("\"", eqIdx)
      if (quoteIdx == null) return null

      // Find the closing quote
      endQuoteIdx := content.index("\"", quoteIdx + 1)
      if (endQuoteIdx == null) return null

      // Extract pod name
      podName := content[quoteIdx+1..<endQuoteIdx]
      return podName.trim.size > 0 ? podName.trim : null
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error parsing podName: $e")
      return null
    }
  }

  **
  ** Parse srcDirs from build.fan content
  **
  private static Uri[] parseSrcDirs(Str content)
  {
    try
    {
      // Look for srcDirs = [...] pattern
      idx := content.index("srcDirs")
      if (idx == null) return Uri[,]

      // Find the opening bracket after srcDirs
      openBracket := content.index("[", idx)
      if (openBracket == null) return Uri[,]

      // Find the closing bracket
      closeBracket := content.index("]", openBracket)
      if (closeBracket == null) return Uri[,]

      // Extract the content between brackets
      dirList := content[openBracket+1..<closeBracket]

      // Parse individual paths (e.g., `fan/`, `src/`)
      uris := Uri[,]
      dirList.split(',').each |part|
      {
        trimmed := part.trim
        // Remove backticks and quotes
        cleaned := trimmed.replace("`", "").replace("\"", "").replace("'", "").trim
        if (cleaned.size > 0)
        {
          uris.add(Uri.decode(cleaned))
        }
      }

      return uris
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error parsing srcDirs: $e")
      return Uri[,]
    }
  }

  **
  ** Create a compiler instance for pod-wide compilation.
  ** Compiles all source files together so cross-file types resolve correctly.
  **
  static Compiler createPodCompiler(File baseDir, Str podName, Uri[] srcDirs)
  {
    logFile := LspUtil.tempDir + `fantom-lsp-compiler.log`
    log := CompilerLog(logFile.out(true))

    LspProtocol.logInfo("Creating pod compiler for '$podName' at ${baseDir.osPath}")
    LspProtocol.logInfo("  srcDirs: $srcDirs")

    input := CompilerInput
    {
      it.mode = CompilerInputMode.file
      it.baseDir = baseDir
      it.srcFiles = srcDirs
      it.podName = podName
      it.version = Version("1.0")
      it.summary = "LSP workspace analysis"
      it.isScript = true
      it.output = CompilerOutputMode.transientPod
      it.log = log
      it.includeDoc = true
    }

    return Compiler(input)
  }

  **
  ** Get project info from a workspace root URI.
  ** Returns map with "podName", "srcDirs", "baseDir" keys.
  **
  static Str:Obj? getProjectInfoFromUri(Str uri)
  {
    return getProjectInfo(uri)
  }

  **
  ** Find build.fan starting from a directory and return project info.
  **
  static Str:Obj? getProjectInfoFromDir(File dir)
  {
    // Delegate to getProjectInfo using the directory's URI
    return getProjectInfo(LspUtil.fileToUri(dir))
  }

  **
  ** Analyze source and return compiler errors
  ** Runs the compiler frontend and catches errors
  **
  static CompilerErr[] analyze(Compiler c)
  {
    try
    {
      // Run frontend (parsing and type checking)
      c.frontend
    }
    catch (CompilerErr e)
    {
      // Expected - errors accumulate in c.errs
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Unexpected error during compilation: $e")
    }

    return c.errs
  }
}

**************************************************************************
** SharedNamespace
**************************************************************************

**
** A compiler namespace reused by the compiles of one thread
** (see 'LspCompiler.sharedNamespace').
**
internal class SharedNamespace
{
  ** The shared namespace
  CNamespace ns

  ** Value of the namespace generation when 'ns' was created
  Int generation

  ** Last compiler created with 'ns'
  Compiler? lastCompiler

  new make(CNamespace ns, Int generation)
  {
    this.ns = ns
    this.generation = generation
  }

  ** True if the last compiler imported a Java FFI package ('using [java]...')
  Bool lastCompilerUsedFfi()
  {
    units := lastCompiler?.pod?.units
    if (units == null) return false
    return units.any |unit| { unit.usings.any |u| { u.podName.startsWith("[") } }
  }
}
