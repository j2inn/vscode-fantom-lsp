
using compiler

**
** LspCompiler - Factory for creating compiler instances for LSP analysis
**
class LspCompiler
{
  **
  ** Create a compiler instance for analyzing a source file
  **
  static Compiler create(Str uri, Str source)
  {
    // Create a compiler log that writes to file instead of stdout
    logFile := LspUtil.tempDir + `fantom-lsp-compiler.log`
    log := CompilerLog(logFile.out(true))

    // Try to get project info (pod name and source directories)
    projectInfo := getProjectInfo(uri)
    podName := projectInfo["podName"] as Str
    srcDirs := projectInfo["srcDirs"] as Uri[]
    baseDir := projectInfo["baseDir"] as File

    // Decide pod name based on whether the file is inside srcDirs
    // If file is inside srcDirs -> use the pod name (types within same pod visible)
    // If file is outside srcDirs -> use lsp_temp (so "using podName" can resolve)
    tempPodName := "lsp_temp"
    if (podName != null && baseDir != null && srcDirs != null)
    {
      if (isFileInSrcDirs(uri, baseDir, srcDirs))
      {
        tempPodName = podName
        LspProtocol.logInfo("File is inside srcDirs, compiling as pod: $podName")
      }
      else
      {
        LspProtocol.logInfo("File is outside srcDirs, compiling as lsp_temp")
      }
    }
    else if (podName != null)
    {
      tempPodName = podName
    }

    LspProtocol.logInfo("Compiling as pod: $tempPodName")

    // Use single file compilation with pod name for script mode type resolution
    // This preserves correct line numbers for Go to Definition
    LspProtocol.logInfo("Compiling single file with pod context")

    input := CompilerInput
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
    }

    return Compiler(input)
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

