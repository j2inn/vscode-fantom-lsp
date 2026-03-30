**
** FormatterService - LSP formatting support for Fantom source files.
**
** Implements textDocument/formatting and textDocument/rangeFormatting.
** The formatter normalises indentation (brace-tracking), trims trailing
** whitespace, collapses excessive blank lines, and inserts a final newline.
** Settings come from initializationOptions (via FormatterOptions) and may
** be overridden per-file by .editorconfig.
**
** Line-ending handling
** --------------------
** The formatter detects the dominant line ending in the input (\n, \r\n, or
** \r) and uses the same style in the formatted output. This means a Windows
** CRLF file stays CRLF after formatting, and a Unix LF file stays LF.
** The .editorconfig 'end_of_line' property (if present) overrides detection.
**
** Space collapsing
** ----------------
** When FormatterOptions.collapseSpaces is true (the default), runs of two or
** more consecutive spaces in code regions (outside string literals and //
** comments) are collapsed to a single space. This fixes patterns like:
** val ? 0 : 1 → val ? 0 : 1
** String types respected: "double", 'char', `backtick`, and """triple""".
**
** Line wrapping
** -------------
** When FormatterOptions.maxLineLength > 0, lines that exceed that length are
** wrapped. The formatter looks for the rightmost split point before the limit:
** 1. A comma inside parentheses / brackets (depth ≥ 1)
** 2. A '&&' or '||' logical operator at any depth
** 3. A ternary '?' surrounded by spaces at depth 0
** 4. A word-boundary space inside a string literal (produces concatenation)
** "very long string" becomes "first part" + \n"second part"
** Continuation lines are indented one level deeper than the base line.
** Backtick (DSL) strings are never split.
**
class FormatterService
{
  private EditorConfigReader editorCfg := EditorConfigReader()

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  **
  ** Format the entire document. Returns a list of LSP TextEdit maps
  ** (typically a single whole-document replacement), or an empty list
  ** when no changes are needed.
  **
  [Str:Obj?][] format(Str uri, Str text, FormatterOptions baseOpts, Str? workspaceRoot)
  {
    opts := resolveOpts(uri, workspaceRoot, baseOpts)
    formatted := doFormat(text, opts)
    if (formatted == text) return [Str:Obj?][,]
    return [wholeDocEdit(text, formatted)]
  }

  **
  ** Format a specific range of lines. Returns a list of LSP TextEdit maps.
  **
  [Str:Obj?][] formatRange(Str uri, Str text, LspRange range, FormatterOptions baseOpts, Str? workspaceRoot)
  {
    opts := resolveOpts(uri, workspaceRoot, baseOpts)
    lines := text.splitLines

    startLine := range.start.line.max(0).min(lines.size - 1)
    endLine := range.end.line.max(0).min(lines.size - 1)
    if (startLine > endLine) return [Str:Obj?][,]

    indentLevel := computeIndentAt(lines, startLine, opts)
    rangeLines := lines[startLine..endLine]
    le := detectLineEnding(text)
    formatted := formatLines(rangeLines, opts, indentLevel, le)
    // Compare against original using the same line ending for fair comparison
    original := rangeLines.join(le)
    if (formatted == original) return [Str:Obj?][,]

    editRange := Str:Obj?["start": Str:Obj?["line": startLine, "character": 0], "end": Str:Obj?["line": endLine, "character": lines[endLine].size] ]
    return [Str:Obj?["range": editRange, "newText": formatted]]
  }

  // ---------------------------------------------------------------------------
  // Private: options
  // ---------------------------------------------------------------------------

  private FormatterOptions resolveOpts(Str uri, Str? workspaceRoot, FormatterOptions base)
  {
    if (!base.respectEditorConfig) return base
    return editorCfg.apply(uri, workspaceRoot, base)
  }

  // ---------------------------------------------------------------------------
  // Private: formatting core
  // ---------------------------------------------------------------------------

  ** Format the entire source text, preserving the original line-ending style.
  private Str doFormat(Str text, FormatterOptions opts)
  {
    le := detectLineEnding(text)
    lines := text.splitLines // strips line endings; handles \n, \r\n, and \r
    result := formatLines(lines, opts, 0, le)

    if (opts.insertFinalNewline && !result.endsWith(le))
    result = result + le

    return result
  }

  **
  ** Format a list of lines and return them joined with 'le' (line ending).
  ** No trailing line ending is appended here; callers add it if needed.
  **
  private Str formatLines(Str[] lines, FormatterOptions opts, Int startIndent, Str le)
  {
    Str[] out := [,]
    indent := startIndent
    blankRun := 0

    // Pre-pass: join continuation lines (trailing-dot or unclosed-paren splits)
    // back into single logical lines so wrapLine can re-split optimally.
    processedLines := joinContinuationLines(lines)

    processedLines.each |line|
    {
      // 'line' from joinContinuationLines: joined lines are trimmed; passthrough
      // lines are CR-stripped but otherwise original (may have trailing spaces).
      trimmed := line.trim

      // Blank line
      if (trimmed.isEmpty)
      {
        blankRun++
        if (opts.maxBlankLines <= 0 || blankRun <= opts.maxBlankLines)
        out.add("")
        return
      }
      blankRun = 0

      // Count braces (outside strings/comments) for indent tracking
      bc := braceCounts(trimmed)
      opens := bc[0]
      closes := bc[1]
      leadingClose := countLeadingClose(trimmed)

      // Decrease indent before printing lines that open with '}'
      indent = (indent - leadingClose).max(0)

      // Build content.
      // trimTrailingWhitespace=true  → use 'trimmed' (trailing spaces gone).
      // trimTrailingWhitespace=false → use line.trimStart() which strips only
      //   leading whitespace, preserving any intentional trailing spaces.
      // collapseSpaces is applied to the code region only.
      rawContent := line.trimStart
      content := opts.trimTrailingWhitespace
      ? (opts.collapseSpaces ? collapseInlineSpaces(trimmed) : trimmed)
      : (opts.collapseSpaces ? collapseInlineSpaces(rawContent) : rawContent)

      // Reconstruct full line (indent + content), then wrap if needed
      fullLine := makeIndent(opts, indent) + content
      if (opts.maxLineLength > 0 && fullLine.size > opts.maxLineLength)
      wrapLine(fullLine, opts.maxLineLength, opts, indent).each |l| { out.add(l) }
      else
      out.add(fullLine)

      indent = (indent + opens - closes + leadingClose).max(0)
    }

    return out.join(le)
  }

  // ---------------------------------------------------------------------------
  // Private: space collapsing
  // ---------------------------------------------------------------------------

  **
  ** Collapse runs of 2+ consecutive spaces into a single space, but only in
  ** code regions — inside string literals and after // the text is copied
  ** verbatim.
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
  private Str collapseInlineSpaces(Str line)
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

  // ---------------------------------------------------------------------------
  // Private: line joining (continuation lines)
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
  private Str[] joinContinuationLines(Str[] lines)
  {
    Str[] result := [,]
    i := 0
    while (i < lines.size)
    {
      raw := stripCr(lines[i])
      // Convert any trailing // comment to /* */ before testing for continuation
      // so that "foo( // remark" is seen as "foo( /* remark */" — open paren
      // still detected as continuation, comment text preserved but harmless.
      buf := convertLineComment(raw.trim)
      joined := false

      // Accumulate continuation lines
      while (!buf.isEmpty && endsAsContinuation(buf) && i + 1 < lines.size)
      {
        nextRaw := stripCr(lines[i+1]).trim
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

**
** Count the net depth of unclosed '{' in 'buf', ignoring any '{' or '}'
  ** inside string literals (double, triple, char, backtick) or block comments.
  **
  ** Used by joinContinuationLines to detect closure-body context: when the
  ** brace depth is > 0 at a join point, the two adjacent joined segments are
  ** separate statements and need a ';' separator.
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

  // ---------------------------------------------------------------------------
  // Private: line wrapping
  // ---------------------------------------------------------------------------

  **
  ** Wrap a single formatted line (already including its leading indent) into
  ** multiple lines if it exceeds maxLen.
  **
  ** Split priority (looking for the rightmost point before maxLen):
  ** 1. Comma at paren/bracket depth ≥ 1 → split AFTER the comma
  ** 2. '&&' or '||' at any depth → split BEFORE the operator
  ** 3. Ternary '?' surrounded by spaces, depth 0 → split BEFORE the '?'
  ** 4. Space inside a double/triple-quoted string → split with concatenation
  ** e.g. "hello world" becomes "hello" + \n"world"
  ** Backtick (DSL) strings are never split.
  **
  ** Modes returned by findWrapPoint / findStringSplitPoint:
  ** 0 = split AFTER splitIdx (comma stays in part1)
  ** 1 = split BEFORE splitIdx (operator starts part2)
  ** 2 = split inside regular double-quoted string at a word-boundary space
  ** 3 = split inside triple-quoted string at a word-boundary space
  **
  ** Continuation lines are indented one level deeper than indentLevel.
  ** Recursively wraps continuation lines that are still too long.
  **
  private Str[] wrapLine(Str fullLine, Int maxLen, FormatterOptions opts, Int indentLevel)
  {
    if (fullLine.size <= maxLen) return [fullLine]

    wp := findWrapPoint(fullLine, maxLen)
    splitIdx := wp[0]
    mode := wp[1]

    // If no code-level split point found, try splitting inside a string literal
    if (splitIdx < 0)
    {
      wp2 := findStringSplitPoint(fullLine, maxLen)
      splitIdx = wp2[0]
      mode = wp2[1]
    }

    if (splitIdx < 0) return [fullLine] // no split point at all, leave as-is

    part1 := ""
    rest := ""
    if (mode == 0)
    {
      // Split after the comma: part1 includes the comma
      part1 = fullLine[0..splitIdx]
      rest = splitIdx + 1 < fullLine.size ? fullLine[splitIdx+1..-1].trim : ""
    }
    else if (mode == 1)
    {
      // Split before the operator: part1 is trimmed, part2 starts with operator
      part1 = fullLine[0..<splitIdx].trimEnd
      rest = fullLine[splitIdx..-1].trim
    }
    else if (mode == 2)
    {
      // Split inside a regular double-quoted string at a word-boundary space.
      // The space at splitIdx is consumed (acts as the word separator).
      // part1: everything up to the space, close the string, append " +"
      /* rest: open a new string, then everything after the space (the */ /* original closing '"' and any trailing code are preserved) */
      part1 = fullLine[0..<splitIdx] + "\" +"
      rest = "\"" + (splitIdx + 1 < fullLine.size ? fullLine[splitIdx+1..-1] : "\"")
    }
    else if (mode == 3)
    {
      // Same as mode 2 but for triple-quoted strings
      part1 = fullLine[0..<splitIdx] + "\"\"\" +"
      rest = "\"\"\"" + (splitIdx + 1 < fullLine.size ? fullLine[splitIdx+1..-1] : "\"\"\"")
    }

    if (rest.isEmpty) return [part1]

    contLine := makeIndent(opts, indentLevel + 1) + rest

    result := Str[,]
    result.add(part1)
    wrapLine(contLine, maxLen, opts, indentLevel + 1).each |l| { result.add(l) }
    return result
  }

  **
  ** Find a word-boundary split point inside a string literal that extends
  ** past maxLen. Only double-quoted and triple-quoted strings are eligible;
  ** backtick (DSL) strings are left intact.
  **
  ** Returns [spaceIdx, mode]:
  ** mode 2 = space inside a regular double-quoted string
  ** mode 3 = space inside a triple-quoted string
  ** Returns [-1, -1] when no suitable split is found.
  **
  private Int[] findStringSplitPoint(Str line, Int maxLen)
  {
    if (line.size <= maxLen) return [-1, -1]

    inStr := false // inside regular "..."
    inTriple := false // inside """..."""
    escaped := false
    strStart := -1 // where the current string opened
    strMode := -1 // 2 or 3 (matches wrapLine mode)
    lastSpace := -1 // last space seen inside current string, before maxLen

    n := line.size
    for (i := 0; i < n; i++)
    {
      ch := line[i]

      if (escaped) { escaped = false; continue }

      if (inTriple)
      {
        if (ch == '\\') { escaped = true; continue }
        if (ch == '"' && i + 2 < n && line[i+1] == '"' && line[i+2] == '"')
        {
          // Triple string closes here.  Return if it crossed maxLen.
          if (strStart < maxLen && i >= maxLen && lastSpace >= 0)
          return [lastSpace, 3]
          inTriple = false; strStart = -1; strMode = -1; lastSpace = -1; i += 2; continue
        }
        if (i < maxLen && ch == ' ') lastSpace = i
        continue
      }

      if (inStr)
      {
        if (ch == '\\') { escaped = true; continue }
        if (ch == '"')
        {
          // Regular string closes here.  Return if it crossed maxLen.
          if (strStart < maxLen && i >= maxLen && lastSpace >= 0)
          return [lastSpace, 2]
          inStr = false; strStart = -1; strMode = -1; lastSpace = -1; continue
        }
        if (i < maxLen && ch == ' ') lastSpace = i
        continue
      }

      // Code region
      if (ch == '/' && i + 1 < n && line[i+1] == '/') break
      if (i >= maxLen) break // past limit in code; only strings can cross it

      // Triple-quoted string start (check before single-quote)
      if (ch == '"' && i + 2 < n && line[i+1] == '"' && line[i+2] == '"')
      {
        inTriple = true; strStart = i; strMode = 3; lastSpace = -1; i += 2; continue
      }

      // Regular double-quoted string start
      if (ch == '"') { inStr = true; strStart = i; strMode = 2; lastSpace = -1; continue }

      // Single-quoted char literal — skip safely (char literals are always short)
      if (ch == '\'')
      {
        i++ // move to char (or backslash)
        if (i < n && line[i] == '\\') i++ // skip escape char
        i++ // skip char; loop will advance past closing quote
        continue
      }

      // Backtick DSL string — skip entirely; never split inside backtick strings
      if (ch == '`')
      {
        i++
        while (i < n && line[i] != '`') i++
        continue // loop will advance past closing backtick
      }
    }

    // Still inside a string at end of line (string not closed on this line)
    if ((inStr || inTriple) && strStart < maxLen && lastSpace >= 0)
    return [lastSpace, strMode]

    return [-1, -1]
  }

  **
  ** Find the best wrap point in 'line' strictly before position 'maxLen'.
  **
  ** Returns [splitIdx, mode]:
  ** mode 0: split AFTER splitIdx (comma stays in part1)
  ** mode 1: split BEFORE splitIdx (operator starts part2)
  ** Returns [-1, -1] when no suitable point is found.
  **
  ** All Fantom string literal types are tracked so that delimiters inside
  ** strings do not produce false wrap candidates:
  ** "double-quoted", 'char', `backtick`, """triple"""
  **
  private Int[] findWrapPoint(Str line, Int maxLen)
  {
    inStr := false // inside "..."
    inTriple := false // inside """..."""
    inChar := false // inside '.'
    inDsl := false // inside `...`
    escaped := false
    depth := 0
    limit := line.size.min(maxLen)

    lastComma := -1 // last comma at depth >= 1 before limit
    lastOp := -1 // last logical operator before limit

    for (i := 0; i < limit; i++)
    {
      ch := line[i]

      if (escaped) { escaped = false; continue }

      if (inTriple)
      {
        if (ch == '\\') escaped = true
        else if (ch == '"' && i + 2 < line.size && line[i+1] == '"' && line[i+2] == '"')
        { inTriple = false; i += 2 }
        continue
      }

      if (inStr)
      {
        if (ch == '\\') escaped = true
        else if (ch == '"') inStr = false
        continue
      }

      if (inChar)
      {
        if (ch == '\\') escaped = true
        else if (ch == '\'') inChar = false
        continue
      }

      if (inDsl)
      {
        if (ch == '`') inDsl = false
        continue
      }

      if (ch == '/' && i + 1 < line.size && line[i + 1] == '/') break

      // Detect triple-quoted string start before single double-quote
      if (ch == '"' && i + 2 < line.size && line[i+1] == '"' && line[i+2] == '"')
      { inTriple = true; i += 2; continue }

      if (ch == '"') { inStr = true; continue }
      if (ch == '\'') { inChar = true; continue }
      if (ch == '`') { inDsl = true; continue }

      if (ch == '(' || ch == '[' || ch == '{') depth++
        else if (ch == ')' || ch == ']' || ch == '}') depth = (depth - 1).max(0)
      else if (ch == ',' && depth >= 1)
      lastComma = i
      // && and || can appear at any depth (e.g. inside an if-condition)
      else if (ch == '&' && i + 1 < line.size && line[i + 1] == '&')
      lastOp = i
      else if (ch == '|' && i + 1 < line.size && line[i + 1] == '|')
      lastOp = i
      // Ternary ? at depth 0 only — flanked by spaces to avoid Str? nullable types
      else if (depth == 0 && ch == '?' && i > 0 && line[i - 1] == ' ' && i + 1 < line.size && line[i + 1] == ' ')
      lastOp = i
    }

    if (lastComma >= 0) return [lastComma, 0]
    if (lastOp >= 0) return [lastOp, 1]
    return [-1, -1]
  }

  // ---------------------------------------------------------------------------
  // Private: indent computation for range formatting
  // ---------------------------------------------------------------------------

  **
  ** Compute the brace-based indent level that would apply at 'targetLine'
  ** by scanning from the top of the file.
  **
  private Int computeIndentAt(Str[] lines, Int targetLine, FormatterOptions opts)
  {
    indent := 0
    for (i := 0; i < targetLine && i < lines.size; i++)
    {
      trimmed := stripCr(lines[i]).trim
      if (trimmed.isEmpty) continue
      bc := braceCounts(trimmed)
      opens := bc[0]
      closes := bc[1]
      leadingClose := countLeadingClose(trimmed)
      indent = (indent - leadingClose).max(0)
      indent = (indent + opens - closes + leadingClose).max(0)
    }
    return indent
  }

  // ---------------------------------------------------------------------------
  // Private: line-ending detection
  // ---------------------------------------------------------------------------

  **
  ** Detect the dominant line ending used in 'text'.
  ** Returns "\r\n" (CRLF), "\r" (CR only), or "\n" (LF, the default).
  ** Checks the first line ending found and uses that style for the whole file.
  **
  private Str detectLineEnding(Str text)
  {
    for (i := 0; i < text.size; i++)
    {
      ch := text[i]
      if (ch == '\r')
      {
        if (i + 1 < text.size && text[i + 1] == '\n') return "\r\n"
        return "\r"
      }
      if (ch == '\n') return "\n"
    }
    return "\n"
  }

  // ---------------------------------------------------------------------------
  // Private: brace counting
  // ---------------------------------------------------------------------------

  **
  ** Count '{' and '}' in a line, ignoring characters inside string literals
  ** and single-line comments (//).
  ** Returns [opens, closes].
  **
  private Int[] braceCounts(Str line)
  {
    opens := 0
    closes := 0
    inStr := false
    inBlock := false // inside /* ... */
    escaped := false
    n := line.size

    for (i := 0; i < n; i++)
    {
      ch := line[i]

      if (escaped) { escaped = false; continue }

      // Block comments: skip entirely so '{}' inside /* */ is not miscounted
      if (inBlock)
      {
        if (ch == '*' && i+1 < n && line[i+1] == '/') { inBlock = false; i++ }
        continue
      }

      if (inStr)
      {
        if (ch == '\\') escaped = true
        else if (ch == '"') inStr = false
        continue
      }

      // Block comment opener (must check before single-line comment)
      if (ch == '/' && i+1 < n && line[i+1] == '*') { inBlock = true; i++; continue }

      // Single-line comment: stop scanning
      if (ch == '/' && i + 1 < n && line[i+1] == '/') break

      if (ch == '"') { inStr = true; continue }
      if (ch == '{') opens++
        else if (ch == '}') closes++
    }

    return [opens, closes]
  }

  **
  ** Count how many '}' appear before the first non-brace, non-whitespace
** character on the trimmed line.
** e.g. "} else {" -> 1, "}}" -> 2, "foo {" -> 0
**
private Int countLeadingClose(Str line)
{
  count := 0
  for (i := 0; i < line.size; i++)
  {
    ch := line[i]
    if (ch == '}') count++
  else if (ch == ' ' || ch == '\t') {} // whitespace between braces is OK
  else break
}
return count
}

// ---------------------------------------------------------------------------
// Private: helpers
// ---------------------------------------------------------------------------

** Build an indent string for the given level
private Str makeIndent(FormatterOptions opts, Int level)
{
  if (level <= 0) return ""
  if (opts.useTabs) return "\t".mult(level)
  n := level * opts.indentSize
  buf := StrBuf(n)
  n.times { buf.addChar(' ') }
  return buf.toStr
}

** Strip leading whitespace only (preserve trailing whitespace)
private Str stripLeading(Str s)
{
  i := 0
  while (i < s.size && (s[i] == ' ' || s[i] == '\t')) i++
  return i == 0 ? s : s[i..-1]
}

**
** Strip a trailing '\r' if present.
** Fantom's splitLines strips '\n' and '\r\n' cleanly, but on some builds a
** lone '\r' at the end of a line element may survive for CRLF input.
**
private Str stripCr(Str s)
{
  if (s.size > 0 && s[-1] == '\r') return s[0..<s.size-1]
  return s
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

**
** Build a TextEdit that replaces the whole document with 'formatted'.
**
** The end position is computed by walking the original text and counting
** logical line separators (\n, \r\n treated as one, \r alone as one).
** This correctly handles LF, CRLF and CR-only files:
**
** LF trailing "a\nb\n" → endLine=2, endChar=0
** CRLF trailing "a\r\nb\r\n" → endLine=2, endChar=0
** CR trailing "a\rb\r" → endLine=2, endChar=0
** LF no trailing "a\nb" → endLine=1, endChar=1
** CRLF no trail "a\r\nb" → endLine=1, endChar=1
**
private Str:Obj? wholeDocEdit(Str original, Str formatted)
{
  lineSeps := 0
  lastSepEnd := -1

  i := 0
  while (i < original.size)
  {
    ch := original[i]
    if (ch == '\r')
    {
      lineSeps++
      i++
      if (i < original.size && original[i] == '\n') i++ // consume \n of \r\n
      lastSepEnd = i
    }
    else if (ch == '\n')
    {
      lineSeps++
      i++
      lastSepEnd = i
    }
    else i++
  }

  trailingNl := (lastSepEnd == original.size)
  endLine := lineSeps
  endChar := trailingNl ? 0 : (original.size - lastSepEnd.max(0))

  return Str:Obj?["range": Str:Obj?["start": Str:Obj?["line": 0, "character": 0], "end": Str:Obj?["line": endLine, "character": endChar] ], "newText": formatted ]
}
}
