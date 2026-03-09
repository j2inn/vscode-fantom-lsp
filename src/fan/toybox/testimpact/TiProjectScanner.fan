
**
** Scans a Fantom project for .fan source files and produces a FanFileInfo
** for each one using the injected IFanFileAnalyzer strategy.
**
** Reads srcDirs from the project's build.fan; testDir is always included.
**
internal class TiProjectScanner
{
  **
  ** Scan all .fan files in the project.
  ** Returns an empty list (and logs to stderr) if build.fan is not found.
  **
  FanFileInfo[] scan(File podRoot, File testDir, IFanFileAnalyzer analyzer)
  {
    buildFan := podRoot + `build.fan`
    if (!buildFan.exists)
    {
      Env.cur.err.printLine("TestImpactAnalyzer: no build.fan found in ${podRoot.osPath}")
      return FanFileInfo[,]
    }

    content  := buildFan.readAllStr
    srcDirs  := parseSrcDirs(podRoot, content)

    Str:Bool seen := [:]
    allFiles      := File[,]
    collectFanFiles(srcDirs, seen, allFiles)
    collectFanFiles([testDir], seen, allFiles)

    fileInfos := FanFileInfo[,]
    allFiles.each |f|
    {
      try { fileInfos.add(analyzer.analyzeFile(f)) }
      catch (Err e) {}
    }
    return fileInfos
  }

  // ---- Private helpers ----

  private Void collectFanFiles(File[] dirs, Str:Bool seen, File[] out)
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

  private File[] parseSrcDirs(File podRoot, Str content)
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
