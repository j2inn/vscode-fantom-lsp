
**
** Represents a single changed hunk from git diff -U0.
** startLine/endLine are 1-based line numbers on the new (right-hand) side of the diff.
**
internal class DiffHunk
{
  File file
  Int  startLine
  Int  endLine

  new make(File file, Int startLine, Int endLine)
  {
    this.file      = file
    this.startLine = startLine
    this.endLine   = endLine
  }
}
