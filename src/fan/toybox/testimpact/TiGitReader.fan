
**
** Reads git diff -U0 output for a given pod root and two git refs.
** Produces a list of DiffHunk records describing the line ranges that changed.
**
internal class TiGitReader
{
  private File podRoot

  new make(File podRoot)
  {
    this.podRoot = podRoot
  }

  **
  ** Run "git diff -U0 ref1 ref2" and parse the output into DiffHunk records.
  ** Returns null if git fails.
  **
  DiffHunk[]? readHunks(Str ref1, Str ref2)
  {
    gitRootPath := runGit(["rev-parse", "--show-toplevel"])
    if (gitRootPath == null) return null
    gitRootPath = gitRootPath.trim

    diffOut := runGit(["diff", "-U0", ref1, ref2])
    if (diffOut == null) return null

    hunks         := DiffHunk[,]
    File? currentFile := null

    diffOut.splitLines.each |line|
    {
      // "+++ b/path/to/file.fan"
      if (line.startsWith("+++ b/"))
      {
        relPath     := line[6..-1].trim
        currentFile = File.os("${gitRootPath}/${relPath}")
        return
      }

      // "@@ -old +new[,count] @@" — only the new-side range matters
      if (line.startsWith("@@") && currentFile != null)
      {
        plusIdx := line.index("+")
        if (plusIdx == null) return
        rest     := line[plusIdx + 1..-1]
        spaceIdx := rest.index(" ")
        rangeStr := spaceIdx != null ? rest[0..<spaceIdx] : rest

        commaIdx  := rangeStr.index(",")
        startLine := 1
        lineCount := 1
        try
        {
          if (commaIdx != null)
          {
            startLine = Int.fromStr(rangeStr[0..<commaIdx])
            lineCount = Int.fromStr(rangeStr[commaIdx + 1..-1])
          }
          else
          {
            startLine = Int.fromStr(rangeStr)
          }
        }
        catch (Err e) { return }

        // lineCount == 0 means a pure deletion; treat it as touching the line before
        if (lineCount == 0) startLine = (startLine > 0) ? startLine - 1 : 1
        endLine := startLine + lineCount - 1
        if (endLine < startLine) endLine = startLine
        hunks.add(DiffHunk(currentFile, startLine, endLine))
        return
      }
    }
    return hunks
  }

  **
  ** Run a single git sub-command from podRoot.
  ** Returns stdout as a String, or null on failure.
  **
  private Str? runGit(Str[] gitArgs)
  {
    outBuf := Buf()
    args   := Str[,]
    args.add("git")
    args.addAll(gitArgs)
    p     := Process(args)
    p.dir  = podRoot
    p.out  = outBuf.out
    p.err  = Env.cur.err
    sep   := " "
    Env.cur.err.printLine("TestImpactAnalyzer: running: ${args.join(sep)} (in ${podRoot.osPath})")
    exitCode := p.run.join
    if (exitCode != 0)
    {
      Env.cur.err.printLine("TestImpactAnalyzer: git ${gitArgs.first} failed (exit ${exitCode})")
      return null
    }
    return outBuf.flip.readAllStr
  }
}
