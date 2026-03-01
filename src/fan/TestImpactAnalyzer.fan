
**
** TestImpactAnalyzer - Given a pod root and a list of changed files,
** determines which Fantom test classes are transitively affected.
**
** Algorithm:
**   1. Parse build.fan to find srcDirs; also scan testDir explicitly
**   2. Walk all .fan files (srcDirs + testDir, deduplicated)
**   3. For each file: extract defined types and referenced type names
**   4. Build reverse dependency graph: type -> [types that reference it]
**   5. BFS from types defined in changed files
**   6. Output test class names from testDir that are reachable
**
** CLI usage:
**   fan vscodeFantomLsp --test-impact <pod-root> --diff <ref1> <ref2> [--test-dir <path>]
**
class TestImpactAnalyzer
{
  **
  ** Find test classes affected by a git diff between two refs.
  **
  ** podRoot: directory containing build.fan
  ** ref1, ref2: git refs (commit hashes or branch names)
  ** testDir: directory containing test classes (default: <pod-root>/test/)
  **
  static Str[] findAffectedTestsFromGitDiff(File podRoot, Str ref1, Str ref2, File testDir)
  {
    changedFiles := gitDiffFiles(podRoot, ref1, ref2)
    if (changedFiles == null) return Str[,]
    return findAffectedTests(podRoot, changedFiles, testDir)
  }

  **
  ** Find test classes affected by the given changed files.
  **
  ** podRoot:      directory containing build.fan
  ** changedFiles: list of changed files (absolute paths)
  ** testDir:      directory containing test classes
  **
  static Str[] findAffectedTests(File podRoot, File[] changedFiles, File testDir)
  {
    buildFan := podRoot + `build.fan`
    if (!buildFan.exists)
    {
      Env.cur.err.printLine("TestImpactAnalyzer: no build.fan found in ${podRoot.osPath}")
      return Str[,]
    }

    content := buildFan.readAllStr
    srcDirs  := parseSrcDirs(podRoot, content)

    // Collect all .fan files: srcDirs + testDir (deduplicated by osPath)
    Str:Bool seen  := [:]
    allFiles       := File[,]
    collectFanFiles(srcDirs, seen, allFiles)
    collectFanFiles([testDir], seen, allFiles)

    // Analyze each file: extract defined types and referenced type names
    fileInfos := FanFileInfo[,]
    allFiles.each |f|
    {
      try { fileInfos.add(analyzeFile(f)) }
      catch (Err e) {} // skip unparseable files
    }

    // Build reverse dependency graph:
    //   if defType (in file F) references refType, then reverseDeps[refType] += defType
    //   meaning: if refType changes, defType is transitively affected
    Str:Str[] reverseDeps := [:]
    fileInfos.each |fi|
    {
      fi.definedTypes.each |defType|
      {
        fi.referencedTypes.each |refType|
        {
          list := reverseDeps[refType]
          if (list == null) { list = Str[,]; reverseDeps[refType] = list }
          list.add(defType)
        }
      }
    }

    // Seed BFS with types defined in the changed files
    Str:Bool visited := [:]
    queue := Str[,]
    changedFiles.each |cf|
    {
      cfNorm := cf.normalize.osPath
      fileInfos.each |fi|
      {
        if (!filesMatch(fi.file, cf, cfNorm)) return
        fi.definedTypes.each |t|
        {
          if (!visited.containsKey(t)) { visited[t] = true; queue.add(t) }
        }
      }
    }

    // BFS through reverse dependency graph to find all transitively affected types
    while (!queue.isEmpty)
    {
      current := queue.removeAt(0)
      deps := reverseDeps[current]
      if (deps == null) continue
      deps.each |dep|
      {
        if (!visited.containsKey(dep)) { visited[dep] = true; queue.add(dep) }
      }
    }

    // Output only test class names from files inside testDir that are reachable
    testDirNorm := testDir.normalize.osPath
    results := Str[,]
    fileInfos.each |fi|
    {
      if (!isUnderDir(fi.file, testDirNorm)) return
      fi.testTypes.each |t|
      {
        if (visited.containsKey(t) && !results.contains(t))
          results.add(t)
      }
    }

    return results
  }

  // ---- Private: Git ----

  **
  ** Run a git command from dir; return stdout as Str, or null on failure.
  **
  private static Str? runGit(File dir, Str[] gitArgs)
  {
    outBuf := Buf()
    args := Str[,]
    args.add("git")
    args.addAll(gitArgs)
    p := Process(args)
    p.dir = dir
    p.out = outBuf.out
    p.err = Env.cur.err  // pass git's stderr through to terminal
    sep := " "
    Env.cur.err.printLine("TestImpactAnalyzer: running: ${args.join(sep)} (in ${dir.osPath})")
    exitCode := p.run.join
    if (exitCode != 0)
    {
      Env.cur.err.printLine("TestImpactAnalyzer: git ${gitArgs.first} failed (exit ${exitCode})")
      return null
    }
    return outBuf.flip.readAllStr
  }

  **
  ** Get the list of files changed between two git refs.
  ** Paths are resolved to absolute using the git repository root.
  **
  private static File[]? gitDiffFiles(File podRoot, Str ref1, Str ref2)
  {
    // Resolve git root so we can make diff paths absolute
    gitRootPath := runGit(podRoot, ["rev-parse", "--show-toplevel"])
    if (gitRootPath == null) return null
    gitRootPath = gitRootPath.trim

    diffOut := runGit(podRoot, ["diff", "--name-only", ref1, ref2])
    if (diffOut == null) return null

    files := File[,]
    diffOut.splitLines.each |line|
    {
      line = line.trim
      if (!line.isEmpty)
        files.add(File.os("${gitRootPath}/${line}"))
    }
    return files
  }

  // ---- Private: File Analysis ----

  private static Void collectFanFiles(File[] dirs, Str:Bool seen, File[] out)
  {
    dirs.each |dir|
    {
      if (!dir.exists || !dir.isDir) return
      dir.walk |f|
      {
        if (f.isDir || f.ext != "fan") return
        norm := f.normalize.osPath
        if (!seen.containsKey(norm)) { seen[norm] = true; out.add(f) }
      }
    }
  }

  **
  ** Analyze a single .fan file.
  ** Tracks per-type test status by scanning class declarations and method signatures.
  ** A type is considered a test class if:
  **   - Its declaration extends Test (": Test", ": sys::Test"), OR
  **   - It contains Void testXxx() methods (tracked per current type context)
  **
  private static FanFileInfo analyzeFile(File f)
  {
    lines := f.readAllStr.splitLines
    definedTypes := Str[,]
    testTypes    := Str[,]
    Str:Bool referencedSet   := [:]
    Str:Bool currentTypeIsTest := [:]

    // Track the current type context to attribute test methods to the right type
    Str? currentType := null

    for (i := 0; i < lines.size; i++)
    {
      line    := lines[i]
      trimmed := line.trim
      if (trimmed.isEmpty || trimmed.startsWith("//") || trimmed.startsWith("**")) continue

      // Non-indented line may be a new type declaration
      if (line.size > 0 && !line[0].isSpace)
      {
        typeName := matchTypeDecl(trimmed)
        if (typeName != null)
        {
          definedTypes.add(typeName)
          currentType = typeName
          if (extendsTest(trimmed))
            currentTypeIsTest[typeName] = true
        }
      }
      else if (currentType != null)
      {
        // Inside a type body: detect test methods
        if (hasTestMethod(trimmed))
          currentTypeIsTest[currentType] = true
      }

      // Extract all uppercase identifiers as potential type references
      extractUppercaseIdents(line).each |ident| { referencedSet[ident] = true }
    }

    // Collect test type names
    currentTypeIsTest.keys.each |t| { testTypes.add(t) }

    // Remove self-defined types from references (not external dependencies)
    definedTypes.each |t| { referencedSet.remove(t) }

    return FanFileInfo(f, definedTypes, testTypes, referencedSet.keys)
  }

  private static Bool extendsTest(Str trimmed)
  {
    return trimmed.contains(": Test") || trimmed.contains(":Test") ||
           trimmed.contains(": sys::Test")
  }

  private static Bool hasTestMethod(Str trimmed)
  {
    // "Void testXxx(" — Xxx starts with uppercase
    idx := trimmed.index("Void test")
    if (idx == null) return false
    after := idx + 9 // "Void test".size == 9
    return after < trimmed.size && trimmed[after].isUpper
  }

  private static Str? matchTypeDecl(Str trimmed)
  {
    keywords := ["class ", "mixin "]
    for (i := 0; i < keywords.size; i++)
    {
      idx := trimmed.index(keywords[i])
      if (idx == null) continue
      afterKeyword := trimmed[idx + keywords[i].size..-1].trim
      name := extractIdentifier(afterKeyword)
      if (name != null && name.size > 0 && name[0].isUpper)
        return name
    }
    return null
  }

  private static Str[] extractUppercaseIdents(Str line)
  {
    result := Str[,]
    i := 0
    while (i < line.size)
    {
      c := line[i]

      // Skip string literals
      if (c == '"')
      {
        i++
        while (i < line.size && line[i] != '"') i++
        i++
        continue
      }

      // Skip line comments
      if (c == '/' && i + 1 < line.size && line[i+1] == '/') break

      if (c.isUpper)
      {
        end := i + 1
        while (end < line.size && (line[end].isAlphaNum || line[end] == '_')) end++
        ident := line[i..<end]
        if (ident.size >= 2) result.add(ident)
        i = end
      }
      else i++
    }
    return result
  }

  private static Str? extractIdentifier(Str text)
  {
    end := 0
    while (end < text.size && (text[end].isAlphaNum || text[end] == '_')) end++
    return end > 0 ? text[0..<end] : null
  }

  private static Bool filesMatch(File indexed, File changed, Str changedNorm)
  {
    // Exact normalized absolute path
    if (indexed.normalize.osPath == changedNorm) return true
    // Indexed path ends with changed (handles relative input paths)
    if (indexed.osPath.endsWith(changed.osPath)) return true
    // Basename match as last resort
    return indexed.name == changed.name
  }

  private static Bool isUnderDir(File f, Str dirNorm)
  {
    p := f.normalize.osPath
    return p == dirNorm ||
           p.startsWith(dirNorm + "/") ||
           p.startsWith(dirNorm + "\\")
  }

  private static File[] parseSrcDirs(File podRoot, Str content)
  {
    dirs := File[,]
    try
    {
      idx := content.index("srcDirs")
      if (idx == null) return dirs
      openBracket  := content.index("[", idx)
      if (openBracket == null) return dirs
      closeBracket := content.index("]", openBracket)
      if (closeBracket == null) return dirs

      dirList := content[openBracket + 1 ..< closeBracket]
      dirList.split(',').each |part|
      {
        cleaned := part.trim.replace("`", "").replace("\"", "").replace("'", "").trim
        if (cleaned.size > 0)
          dirs.add(podRoot.plus(Uri.decode(cleaned), false))
      }
    }
    catch (Err e) {}
    return dirs
  }
}

**
** Internal data holder for per-file analysis in TestImpactAnalyzer.
** testTypes holds only the type names in this file that extend Test
** or contain Void testXxx() methods.
**
internal class FanFileInfo
{
  File   file
  Str[]  definedTypes
  Str[]  testTypes
  Str[]  referencedTypes

  new make(File file, Str[] definedTypes, Str[] testTypes, Str[] referencedTypes)
  {
    this.file            = file
    this.definedTypes    = definedTypes
    this.testTypes       = testTypes
    this.referencedTypes = referencedTypes
  }
}
