**
** Collapses runs of two or more consecutive spaces into a single space,
** skipping over string literals and trailing // comments.
**
** Handles all Fantom string literal types:
** "double-quoted" — with escape sequences
** 'char' — single-quoted character literal
** `backtick` — DSL / raw string (no escapes)
** """triple""" — triple-quoted string with escape sequences
**
** The input is already trimmed (no leading/trailing whitespace), so this
** only affects interior spacing.
**
internal class SpaceCollapser
{
  internal Str collapse(Str line)
  {
    buf := StrBuf()
    inStr := false // inside "..."
    inTriple := false // inside """..."""
    inChar := false // inside '.'
    inDsl := false // inside `...`
    escaped := false
    prevSpc := false
    n := line.size

    for (i := 0; i < n; i++)
    {
      ch := line[i]

      if (escaped) { escaped = false; buf.addChar(ch); prevSpc = false; continue }

      // Inside triple-quoted string — verbatim copy, look for closing """
      if (inTriple)
      {
        if (ch == '\\') { escaped = true; buf.addChar(ch); continue }
        if (ch == '"' && i + 2 < n && line[i+1] == '"' && line[i+2] == '"')
        {
          buf.addChar(ch); buf.addChar(line[i+1]); buf.addChar(line[i+2])
          i += 2; inTriple = false; prevSpc = false; continue
        }
        buf.addChar(ch); prevSpc = false; continue
      }

      // Inside regular double-quoted string — verbatim copy
      if (inStr)
      {
        if (ch == '\\') { escaped = true; buf.addChar(ch); continue }
        if (ch == '"') inStr = false
        buf.addChar(ch); prevSpc = false; continue
      }

      // Inside single-quoted char literal — verbatim copy
      if (inChar)
      {
        if (ch == '\\') { escaped = true; buf.addChar(ch); continue }
        if (ch == '\'') inChar = false
        buf.addChar(ch); prevSpc = false; continue
      }

      // Inside backtick DSL string — verbatim copy, no escapes
      if (inDsl)
      {
        if (ch == '`') inDsl = false
        buf.addChar(ch); prevSpc = false; continue
      }

      // Single-line comment: copy the rest of the line verbatim
      if (ch == '/' && i + 1 < n && line[i + 1] == '/')
      {
        for (j := i; j < n; j++) buf.addChar(line[j])
        break
      }

      // Detect triple-quoted string start before single double-quote
      if (ch == '"' && i + 2 < n && line[i+1] == '"' && line[i+2] == '"')
      {
        buf.addChar(ch); buf.addChar(line[i+1]); buf.addChar(line[i+2])
        i += 2; inTriple = true; prevSpc = false; continue
      }

      if (ch == '"') { inStr = true; buf.addChar(ch); prevSpc = false; continue }
      if (ch == '\'') { inChar = true; buf.addChar(ch); prevSpc = false; continue }
      if (ch == '`') { inDsl = true; buf.addChar(ch); prevSpc = false; continue }

      if (ch == ' ')
      {
        if (!prevSpc) buf.addChar(' ')
        prevSpc = true
      }
      else
      {
        buf.addChar(ch)
        prevSpc = false
      }
    }

    return buf.toStr
  }
}
