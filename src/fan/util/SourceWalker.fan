**
** SourceWalker — multi-line walker over a complete Fantom source string.
**
** Wraps FantomScanner and carries cross-line state (block-comment
** continuation) from one line to the next.  Provides two usage styles:
**
**   1. Callback style — pass a closure to walkLines() or walkChars();
**      the walker drives iteration.
**
**   2. Manual style — call nextLine() in a while loop and use the exposed
**      FantomScanner directly for full control.
**
** Cross-line block comment state is seeded automatically from the previous
** line's scanner into each new scanner.
**
class SourceWalker
{
  ** The full source text split into lines (read-only after construction).
  const Str[] lines

  ** Index of the current line (0-based).
  Int lineIdx := 0

  ** The scanner for the current line (null before first nextLine() call).
  FantomScanner? scanner := null

  new make(Str source) { lines = source.splitLines }

  // -------------------------------------------------------------------------
  // Manual iteration
  // -------------------------------------------------------------------------

  ** True when all lines have been consumed.
  Bool isDone() { lineIdx >= lines.size }

  **
  ** Advance to the next line and return a fresh FantomScanner seeded with
  ** the block-comment state from the previous line.
  ** Returns null when there are no more lines.
  **
  FantomScanner? nextLine()
  {
    if (lineIdx >= lines.size) return null
    prevInBlock := scanner?.inBlock ?: false
    scanner = FantomScanner.makeWithState(lines[lineIdx], prevInBlock)
    lineIdx++
    return scanner
  }

  // -------------------------------------------------------------------------
  // Callback style
  // -------------------------------------------------------------------------

  **
  ** Walk every line, calling onLine for each.
  ** The closure receives (lineIndex, FantomScanner).
  ** The scanner is fresh (pos == 0) at the start of each call.
  **
  Void walkLines(|Int lineIdx, FantomScanner scanner| onLine)
  {
    while (!isDone)
    {
      s := nextLine
      if (s != null) onLine(lineIdx - 1, s)
    }
  }

  **
  ** Walk every character in every line (skipping newlines), calling onChar
  ** for each.  The closure receives (lineIndex, colIndex, ch, scanner).
  ** Context state in the scanner reflects the position *after* consuming ch.
  **
  Void walkChars(|Int lineIdx, Int col, Int ch, FantomScanner scanner| onChar)
  {
    walkLines |li, s|
    {
      while (!s.isDone)
      {
        col := s.pos
        ch := s.advance
        if (ch != null) onChar(li, col, ch, s)
      }
    }
  }
}
