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
** \r) and uses the same style in the formatted output.  This means a Windows
** CRLF file stays CRLF after formatting, and a Unix LF file stays LF.
** The .editorconfig 'end_of_line' property (if present) overrides detection.
**
class FormatterService
{
  private EditorConfigReader editorCfg := EditorConfigReader()

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  **
  ** Format the entire document.  Returns a list of LSP TextEdit maps
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
  ** Format a specific range of lines.  Returns a list of LSP TextEdit maps.
  **
  [Str:Obj?][] formatRange(Str uri, Str text, LspRange range, FormatterOptions baseOpts, Str? workspaceRoot)
  {
    opts := resolveOpts(uri, workspaceRoot, baseOpts)
    lines := text.splitLines

    startLine := range.start.line.max(0).min(lines.size - 1)
    endLine   := range.end.line.max(0).min(lines.size - 1)
    if (startLine > endLine) return [Str:Obj?][,]

    indentLevel := computeIndentAt(lines, startLine, opts)
    rangeLines  := lines[startLine..endLine]
    le          := detectLineEnding(text)
    formatted   := formatLines(rangeLines, opts, indentLevel, le)
    // Compare against original using the same line ending for fair comparison
    original    := rangeLines.join(le)
    if (formatted == original) return [Str:Obj?][,]

    editRange := Str:Obj?[
      "start": Str:Obj?["line": startLine, "character": 0],
      "end":   Str:Obj?["line": endLine,   "character": lines[endLine].size]
    ]
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
    le    := detectLineEnding(text)
    lines := text.splitLines  // strips line endings; handles \n, \r\n, and \r
    result := formatLines(lines, opts, 0, le)

    // insertFinalNewline: add the line ending if the result doesn't end with one.
    // Since we already joined with 'le', a trailing empty element from splitLines
    // (which appears for CRLF-terminated files) produced a trailing 'le' already.
    // For LF-only files splitLines does NOT produce a trailing empty element, so
    // we may need to add one explicitly.
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
    indent   := startIndent
    blankRun := 0

    lines.each |line|
    {
      // splitLines strips line terminators, but on some Fantom builds a
      // trailing \r may remain inside the line for CRLF content.
      // Strip it so brace-counting and trim logic see clean content.
      trimmed := stripCr(line).trim

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
      opens        := bc[0]
      closes       := bc[1]
      leadingClose := countLeadingClose(trimmed)

      // Decrease indent before printing lines that open with '}'
      indent = (indent - leadingClose).max(0)

      // Build output line (content is already \r-free after stripCr above)
      content := opts.trimTrailingWhitespace ? trimmed : stripLeading(stripCr(line))
      out.add(makeIndent(opts, indent) + content)

      // Adjust indent for subsequent lines:
      //   net = opens - closes + leadingClose
      // (leadingClose was already subtracted from indent above; we add it back
      //  here to keep the accounting symmetric with how closes are counted.)
      indent = (indent + opens - closes + leadingClose).max(0)
    }

    return out.join(le)
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
      bc           := braceCounts(trimmed)
      opens        := bc[0]
      closes       := bc[1]
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
    opens   := 0
    closes  := 0
    inStr   := false
    escaped := false
    n       := line.size

    for (i := 0; i < n; i++)
    {
      ch := line[i]

      if (escaped) { escaped = false; continue }

      if (inStr)
      {
        if (ch == '\\') escaped = true
        else if (ch == '"') inStr = false
        continue
      }

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
  ** e.g. "} else {" -> 1,  "}}" -> 2,  "foo {" -> 0
  **
  private Int countLeadingClose(Str line)
  {
    count := 0
    for (i := 0; i < line.size; i++)
    {
      ch := line[i]
      if (ch == '}') count++
      else if (ch == ' ' || ch == '\t') {}  // whitespace between braces is OK
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
  ** Build a TextEdit that replaces the whole document with 'formatted'.
  **
  ** The end position is computed by walking the original text and counting
  ** logical line separators (\n, \r\n treated as one, \r alone as one).
  ** This correctly handles LF, CRLF and CR-only files:
  **
  **   LF trailing    "a\nb\n"    → endLine=2, endChar=0
  **   CRLF trailing  "a\r\nb\r\n"→ endLine=2, endChar=0
  **   CR trailing    "a\rb\r"    → endLine=2, endChar=0
  **   LF no trailing "a\nb"      → endLine=1, endChar=1
  **   CRLF no trail  "a\r\nb"    → endLine=1, endChar=1
  **
  private Str:Obj? wholeDocEdit(Str original, Str formatted)
  {
    lineSeps  := 0  // number of logical line separators seen
    lastSepEnd := -1  // index in 'original' right after the last separator

    i := 0
    while (i < original.size)
    {
      ch := original[i]
      if (ch == '\r')
      {
        lineSeps++
        i++
        if (i < original.size && original[i] == '\n') i++  // consume \n of \r\n
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

    // If the string ends exactly at a separator boundary, the end position
    // is {lineSeps, 0} — the virtual empty line VS Code places after the
    // final line terminator.  Otherwise it is {lineSeps, lastLineLen}.
    trailingNl := (lastSepEnd == original.size)
    endLine := lineSeps
    endChar := trailingNl ? 0 : (original.size - lastSepEnd.max(0))

    return Str:Obj?[
      "range": Str:Obj?[
        "start": Str:Obj?["line": 0,       "character": 0],
        "end":   Str:Obj?["line": endLine, "character": endChar]
      ],
      "newText": formatted
    ]
  }
}
