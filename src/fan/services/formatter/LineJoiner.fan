**
** Pre-pass that joins lines split mid-expression (continuation lines) back
** into single logical lines before wrapping and indentation are applied.
**
internal class LineJoiner
{
  private FormatterUtils utils := FormatterUtils()

  // ---------------------------------------------------------------------------
  // Public entry point
  // ---------------------------------------------------------------------------

  **
  ** Pre-pass: join lines that were split mid-expression back into single
  ** logical lines. A line "continues" when it ends with unclosed
  ** parentheses / brackets or with a trailing '.' (member-access split).
  **
  ** Blank lines are never crossed. The separator between the joined
  ** fragments is empty when the current fragment ends with '.', '(', or '['
  ** (no extra space needed), and a single space otherwise.
  **
  ** After joining, the regular wrapLine pass will re-split any result that
  ** still exceeds maxLineLength.
  **
  internal Str[] join(Str[] lines)
  {
    Str[] result := [,]
    i := 0
    while (i < lines.size)
    {
      raw := utils.stripCr(lines[i])
      // Convert any trailing // comment to /* */ before testing for continuation
      // so that "foo( // remark" is seen as "foo( /* remark */" — open paren
      // still detected as continuation, comment text preserved but harmless.
      buf := convertLineComment(raw.trim)
      joined := false

      // Accumulate continuation lines.
      // List/map literals (unclosed '[' with no unclosed '(') are never joined:
      // each element stays on its own line and the indentation fixer re-indents
      // them correctly.  Joining these would produce one massive line that the
      // bracket-expansion pass then has to fully reconstruct — with embedded
      // comments this reconstruction is lossy.
      while (!buf.isEmpty && endsAsContinuation(buf)
        && !openDepthOnlyBrackets(buf)
        && i + 1 < lines.size)
      {
        nextRaw := utils.stripCr(lines[i+1]).trim
        if (nextRaw.isEmpty) break // never cross a blank line
        nextConverted := convertLineComment(nextRaw)
        i++
        // Lines whose entire content was an empty // comment (nothing after //)
        // reduce to "" — skip them silently.
        if (nextConverted.isEmpty) continue
        lastCh := buf[buf.size-1]
        nextCh := nextConverted.isEmpty ? ' ' : nextConverted[0]
        // Two-char suffix: ++ and -- end a statement, even though their last
        // char (+/-) looks like a binary operator.
        lastTwo := buf.size >= 2 ? buf[buf.size-2..buf.size-1] : "  "
        Str sep := " "
        if (lastCh == '.' || lastCh == '(' || lastCh == '[')
        sep = ""
        // Leading-dot chain on next line: join without separator.
        else if (nextCh == '.')
        sep = ""
        // Closing delimiter starts the next fragment: always space.
        else if (nextCh == '}' || nextCh == ')' || nextCh == ']')
      sep = " "
      // Opening/punctuation last char: space (not semicolon).
      else if (lastCh == '{' || lastCh == ',' || lastCh == ';')
        sep = " "
        // Closed block statement: '}' already terminates the statement in
        // Fantom; adding '; ' after it is a syntax error.
        else if (lastCh == '}')
      sep = " "
      // Postfix ++ / -- end a statement — must not be treated as operators.
      else if (lastTwo == "++" || lastTwo == "--")
      sep = braceDepthAt(buf) > 0 ? "; " : " "
      // Expression-continuation operators — next fragment is part of the
      // same expression, not a new statement; never insert a semicolon.
      else if (lastCh == '&' || lastCh == '|' || lastCh == '+' || lastCh == '-' || lastCh == '*' || lastCh == '/' || lastCh == '%')
      sep = " "
      // Inside an open brace context (closure body): separate statements.
      else if (braceDepthAt(buf) > 0)
      sep = "; "
      buf = buf + sep + nextConverted
      joined = true
    }

    /* For passthrough lines, preserve the original (CR-stripped but not */ /* trimmed) so that trimTrailingWhitespace=false can see trailing spaces. */
    // For joined lines, the concatenated buf is inherently trimmed.
    result.add(joined ? buf : raw)
    i++
  }
  return result
}

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  **
  ** Returns true if a trimmed line "continues" onto the next line, meaning
  ** the parser would not end a statement here. Two conditions qualify:
  ** 1. Unclosed parentheses / brackets at end of line (depth > 0)
  ** 2. Last code character is '.' (member access split across lines)
  **
  ** All Fantom string literal types and single-line comments are tracked so
  ** that delimiters inside strings / comments do not produce false results.
  **
  ** Fantom doc-comment lines (starting with '**') are never continuations.
  **
  private Bool endsAsContinuation(Str line)
  {
    // Doc-comment lines must never be joined to the line that follows them.
    if (line.startsWith("**")) return false

    inStr := false
    inTriple := false
    inChar := false
    inDsl := false
    inBlock := false // inside /* ... */ (produced by convertLineComment)
    escaped := false
    depth := 0
    lastCode := 0
    n := line.size

    for (i := 0; i < n; i++)
    {
      ch := line[i]

      if (escaped) { escaped = false; lastCode = ch; continue }

      // Block comments (/* ... */) are skipped entirely — they never affect
      /* depth or lastCode, and their content (which may include '//' text */ /* from a converted line comment) must not stop scanning prematurely. */
      if (inBlock)
      {
        if (ch == '*' && i+1 < n && line[i+1] == '/') { inBlock = false; i++ }
        continue
      }

      if (inTriple)
      {
        if (ch == '\\') { escaped = true; continue }
        if (ch == '"' && i+2 < n && line[i+1] == '"' && line[i+2] == '"')
        { inTriple = false; lastCode = '"'; i += 2 }
          continue
        }

        if (inStr)
        {
          if (ch == '\\') { escaped = true; continue }
          if (ch == '"') { inStr = false; lastCode = '"' }
        continue
      }

      if (inChar)
      {
        if (ch == '\\') { escaped = true; continue }
        if (ch == '\'') { inChar = false; lastCode = '\'' }
        continue
      }

      if (inDsl)
      {
        if (ch == '`') { inDsl = false; lastCode = '`' }
        continue
      }

      // Block comment opener (must check before single-line comment)
      if (ch == '/' && i+1 < n && line[i+1] == '*') { inBlock = true; i++; continue }

      // Single-line comment: stop scanning
      if (ch == '/' && i+1 < n && line[i+1] == '/') break

      // Triple-quoted string start (must check before single '"')
      if (ch == '"' && i+2 < n && line[i+1] == '"' && line[i+2] == '"')
      { inTriple = true; i += 2; continue }

      if (ch == '"') { inStr = true; continue }
      if (ch == '\'') { inChar = true; continue }
      if (ch == '`') { inDsl = true; continue }

      if (ch == '(' || ch == '[') depth++
      else if (ch == ')' || ch == ']') depth = (depth-1).max(0)

      if (ch != ' ' && ch != '\t') lastCode = ch
    }

    return depth > 0 || lastCode == '.'
  }

  **
  ** Return true when 'line' ends with unclosed brackets and ALL of those
  ** unclosed openers are square brackets '[' (not parentheses '(' or braces
  ** '{').  In that case the continuation spans a list or map literal and
  ** must NOT be joined: each element should remain on its own line.
  **
  ** String literals, block comments, and single-line comments are tracked
  ** so delimiters inside them do not produce false results.
  **
  private Bool openDepthOnlyBrackets(Str line)
  {
    if (line.startsWith("**")) return false

    inStr    := false
    inTriple := false
    inChar   := false
    inDsl    := false
    inBlock  := false
    escaped  := false
    squareDepth := 0 // unclosed '['
    parenDepth  := 0 // unclosed '(' or '{'
    n := line.size

    for (i := 0; i < n; i++)
    {
      ch := line[i]
      if (escaped) { escaped = false; continue }

      if (inBlock)
      {
        if (ch == '*' && i+1 < n && line[i+1] == '/') { inBlock = false; i++ }
        continue
      }
      if (inTriple)
      {
        if (ch == '\\') { escaped = true; continue }
        if (ch == '"' && i+2 < n && line[i+1] == '"' && line[i+2] == '"')
        { inTriple = false; i += 2 }
        continue
      }
      if (inStr)
      {
        if (ch == '\\') { escaped = true; continue }
        if (ch == '"') inStr = false
        continue
      }
      if (inChar)
      {
        if (ch == '\\') { escaped = true; continue }
        if (ch == '\'') inChar = false
        continue
      }
      if (inDsl) { if (ch == '`') inDsl = false; continue }

      if (ch == '/' && i+1 < n && line[i+1] == '*') { inBlock = true; i++; continue }
      if (ch == '/' && i+1 < n && line[i+1] == '/') break

      if (ch == '"' && i+2 < n && line[i+1] == '"' && line[i+2] == '"')
      { inTriple = true; i += 2; continue }
      if (ch == '"') { inStr  = true; continue }
      if (ch == '\'') { inChar = true; continue }
      if (ch == '`')  { inDsl  = true; continue }

      if      (ch == '[') squareDepth++
      else if (ch == ']') squareDepth = (squareDepth - 1).max(0)
      else if (ch == '(' || ch == '{') parenDepth++
      else if (ch == ')' || ch == '}') parenDepth = (parenDepth - 1).max(0)
    }

    return squareDepth > 0 && parenDepth == 0
  }

  **
  ** Count the net depth of unclosed '{' in 'buf', ignoring any '{' or '}'
  ** inside string literals (double, triple, char, backtick) or block comments.
  **
  ** Used by join to detect closure-body context: when the brace depth is > 0
  ** at a join point, the two adjacent joined segments are separate statements
  ** and need a ';' separator.
  **
  private Int braceDepthAt(Str buf)
  {
    inStr := false // inside "..."
    inTriple := false // inside """..."""
    inChar := false // inside '.'
    inDsl := false // inside `...`
    inBlock  := false   // inside /* ... */ (from converted // comments)
    escaped  := false
    depth    := 0
    n        := buf.size

    for (i := 0; i < n; i++)
    {
      ch := buf[i]

      if (escaped) { escaped = false; continue }

      // Block comment (produced by convertLineComment from joined // fragments)
      if (inBlock)
      {
        if (ch == '*' && i+1 < n && buf[i+1] == '/') { inBlock = false; i++ }
        continue
      }

      if (inTriple)
      {
        if (ch == '\\') { escaped = true; continue }
        if (ch == '"' && i+2 < n && buf[i+1] == '"' && buf[i+2] == '"')
        { inTriple = false; i += 2 }
        continue
      }

      if (inStr)
      {
        if (ch == '\\') { escaped = true; continue }
        if (ch == '"') inStr = false
        continue
      }

      if (inChar)
      {
        if (ch == '\\') { escaped = true; continue }
        if (ch == '\'') inChar = false
        continue
      }

      if (inDsl)
      {
        if (ch == '`') inDsl = false
        continue
      }

      // Block comment open
      if (ch == '/' && i+1 < n && buf[i+1] == '*') { inBlock = true; i++; continue }

      // Triple-quoted string start (must check before single double-quote)
      if (ch == '"' && i+2 < n && buf[i+1] == '"' && buf[i+2] == '"')
      { inTriple = true; i += 2; continue }

      if (ch == '"') { inStr = true; continue }
      if (ch == '\'') { inChar = true; continue }
      if (ch == '`') { inDsl = true; continue }

      if (ch == '{') depth++
        else if (ch == '}') depth = (depth-1).max(0)
    }

    return depth
  }

  **
  ** Convert a trailing '//' line comment in 'line' into an inline block
  ** comment (/* text */) so that joining continuation lines does not produce
  ** code that comments-out everything that follows on the same logical line.
  **
  ** String literals (double, single, triple-quoted, backtick) are tracked so
  ** that '//' inside a string is never mistaken for a comment delimiter.
  **
  ** Returns:
  ** - "code /* text */" — when there is a non-empty trailing comment
  ** - "/* text */" — when the entire line is a non-empty comment
  ** - "code" — when there is no comment or the comment is blank
  **
  ** Note: '*'-only comment text (e.g. "// *") is preserved as "/* * */"
  ** because the comment text is kept verbatim; only surrounding whitespace
  ** is trimmed.
  **
  private Str convertLineComment(Str line)
  {
    inStr := false
    inTriple := false
    inChar := false
    inDsl := false
    escaped := false
    n := line.size

    for (i := 0; i < n; i++)
    {
      ch := line[i]

      if (escaped) { escaped = false; continue }

      if (inTriple)
      {
        if (ch == '\\') { escaped = true; continue }
        if (ch == '"' && i+2 < n && line[i+1] == '"' && line[i+2] == '"')
        { inTriple = false; i += 2 }
        continue
      }

      if (inStr)
      {
        if (ch == '\\') { escaped = true; continue }
        if (ch == '"') inStr = false
        continue
      }

      if (inChar)
      {
        if (ch == '\\') { escaped = true; continue }
        if (ch == '\'') inChar = false
        continue
      }

      if (inDsl)
      {
        if (ch == '`') inDsl = false
        continue
      }

      if (ch == '/' && i+1 < n && line[i+1] == '/')
      {
        code := line[0..<i].trim
        comment := line[i+2..-1].trim // text after "//"
        if (comment.isEmpty) return code
        if (code.isEmpty) return "/* ${comment} */"
        return "${code} /* ${comment} */"
      }

      if (ch == '"' && i+2 < n && line[i+1] == '"' && line[i+2] == '"')
      { inTriple = true; i += 2; continue }

      if (ch == '"') { inStr = true; continue }
      if (ch == '\'') { inChar = true; continue }
      if (ch == '`') { inDsl = true; continue }
    }

    return line
  }
}
