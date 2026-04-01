**
** FormatterService - LSP formatting support for Fantom source files.
**
** Implements textDocument/formatting and textDocument/rangeFormatting.
** The formatter normalises indentation (brace-tracking), trims trailing
** whitespace, collapses excessive blank lines, and inserts a final newline.
** Settings come from initializationOptions (via FormatterOptions) and may
** be overridden per-file by .editorconfig.
**
** The heavy lifting is split across focused helper classes in the
** formatter/ sub-package:
**
**   FormatterUtils       — indent building, stripCr, stripLeading
**   SpaceCollapser       — collapse runs of spaces in code regions
**   LineJoiner           — join continuation lines (trailing . / open paren)
**   LineWrapper          — wrap long lines at the best split point
**   BracketNormalizer    — normalise and expand list/map bracket literals
**   MapAligner           — align map-entry values to the same column
**   CommentFormatter     — block-comment detection, comment word-wrap,
**                          and doc-comment conversion
**
class FormatterService
{
  private EditorConfigReader editorCfg        := EditorConfigReader()
  private FormatterUtils     utils            := FormatterUtils()
  private SpaceCollapser     spaceCollapser   := SpaceCollapser()
  private LineJoiner         lineJoiner       := LineJoiner()
  private LineWrapper        lineWrapper      := LineWrapper()
  private BracketNormalizer  bracketNorm      := BracketNormalizer()
  private MapAligner         mapAligner       := MapAligner()
  private CommentFormatter   commentFormatter := CommentFormatter()

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
    inBlockComment := false  // true while inside a /* ... */ spanning multiple lines

    // Pre-pre-pass: normalize multi-line bracket literal blocks.
    // Any list or map literal that spans multiple source lines (including ones
    // where elements appear on the same line as the opener) is rebuilt into
    // canonical form: the opener '[' alone on the last-token of its line,
    // one element per line, and the closer ']' on its own line.  Block-comment
    // prefixes (/* Fantom */) and inline // comments are preserved.
    // This pass runs before joinContinuationLines so that the join pass never
    // sees a multi-line list and never needs to join-or-not-join its elements.
    normalizedLines := bracketNorm.normalize(lines)

    // Pre-pass: join continuation lines (trailing-dot or unclosed-paren splits)
    // back into single logical lines so wrapLine can re-split optimally.
    processedLines := lineJoiner.join(normalizedLines)

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

      // -----------------------------------------------------------------------
      // Multi-line block comment (/* ... */) — emit lines verbatim.
      // These span multiple source lines; their interior may contain tables,
      // diagrams, or carefully formatted text that must not be re-indented,
      // space-collapsed, or bracket-expanded.
      // -----------------------------------------------------------------------
      if (!inBlockComment && commentFormatter.isBlockCommentOpener(trimmed))
      {
        inBlockComment = true
        out.add(line)
        return
      }
      if (inBlockComment)
      {
        if (trimmed.contains("*/")) inBlockComment = false
        out.add(line)
        return
      }

      // -----------------------------------------------------------------------
      // Single-line comment (//) and Fantom doc comment (**) lines.
      // These are re-indented to the current brace-based indent level, but:
      //   • spaces inside the comment text are NOT collapsed
      //   • bracket literals inside the text are NOT expanded
      //   • NCSS wrapping rules (comma/operator splits) are NOT applied
      //   • when maxLineLength > 0 and the line is too long, a simple
      //     word-wrap (break at the last space before the limit) is used
      // -----------------------------------------------------------------------
      isCommentLine := trimmed.startsWith("//") || trimmed.startsWith("**")
      if (isCommentLine)
      {
        fullLine := utils.makeIndent(opts, indent) + trimmed
        if (opts.maxLineLength > 0 && fullLine.size > opts.maxLineLength)
          commentFormatter.wrapCommentLine(fullLine, opts.maxLineLength, opts, indent).each |l| { out.add(l) }
        else
          out.add(fullLine)
        return
      }

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
      ? (opts.collapseSpaces ? spaceCollapser.collapse(trimmed) : trimmed)
      : (opts.collapseSpaces ? spaceCollapser.collapse(rawContent) : rawContent)

      // Reconstruct full line (indent + content), then expand or wrap as needed
      fullLine := utils.makeIndent(opts, indent) + content
      // Unconditionally expand multi-element list/map literals to one-per-line
      // form.  This runs before the maxLineLength check so that a literal that
      // was collapsed by the continuation-join pre-pass is always re-expanded,
      // regardless of whether a line-length limit is configured.
      expandedLines := bracketNorm.tryExpand(fullLine, opts, indent)
      if (expandedLines != null)
        expandedLines.each |l| { out.add(l) }
      else
      {
        // Try expanding method call/declaration arguments one-per-line
        // unconditionally (same policy as list/map literal expansion).
        methodExpanded := bracketNorm.tryExpandMethodCall(fullLine, opts, indent)
        if (methodExpanded != null)
          methodExpanded.each |l| { out.add(l) }
        else if (opts.maxLineLength > 0 && fullLine.size > opts.maxLineLength)
          lineWrapper.wrap(fullLine, opts.maxLineLength, opts, indent).each |l| { out.add(l) }
        else
          out.add(fullLine)
      }

      indent = (indent + opens - closes + leadingClose).max(0)
    }

    // Post-pass: align map literal values so all values in a block start
    // at the same column (determined by the longest key in that block).
    out = mapAligner.align(out, opts)

    // Post-pass: convert // and /* */ doc-comment blocks above declarations
    // to Fantom-style ** doc comments (when the option is enabled).
    if (opts.convertFantomDocComments)
      out = commentFormatter.convertDocComments(out, opts)

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
      trimmed := utils.stripCr(lines[i]).trim
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
  ** Count '{', '}', '[', and ']' in a line, ignoring characters inside string
  ** literals and comments.  Returns [opens, closes] where opens counts '{' and
  ** '[', and closes counts '}' and ']'.
  **
  ** Tracking both brace and bracket depth lets formatLines re-indent the
  ** one-element-per-line output of normalizeBracketBlocks correctly, so list
  ** and map literal elements are always indented one level deeper than their
  ** opening '[' line.
  **
  private Int[] braceCounts(Str line)
  {
    opens    := 0
    closes   := 0
    inStr    := false   // inside "..."
    inTriple := false   // inside """..."""
    inChar   := false   // inside '...'
    inDsl    := false   // inside `...`
    inBlock  := false   // inside /* ... */
    escaped  := false
    n        := line.size

    for (i := 0; i < n; i++)
    {
      ch := line[i]

      if (escaped) { escaped = false; continue }

      // Block comments: skip entirely
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

      if (inDsl) { if (ch == '`') inDsl = false; continue }

      // Block comment opener (must check before single-line comment)
      if (ch == '/' && i+1 < n && line[i+1] == '*') { inBlock = true; i++; continue }

      // Single-line comment: stop scanning
      if (ch == '/' && i+1 < n && line[i+1] == '/') break

      // Triple-quoted string start (check before single '"')
      if (ch == '"' && i+2 < n && line[i+1] == '"' && line[i+2] == '"')
      { inTriple = true; i += 2; continue }

      if (ch == '"')  { inStr  = true; continue }
      if (ch == '\'') { inChar = true; continue }
      if (ch == '`')  { inDsl  = true; continue }

      if (ch == '{' || ch == '[') opens++
        else if (ch == '}' || ch == ']') closes++
    }

    return [opens, closes]
  }

  **
  ** Count how many '}' or ']' appear before the first non-close, non-whitespace
  ** character on the trimmed line.
  ** e.g. "} else {" -> 1, "}}" -> 2, "]," -> 1, "foo {" -> 0
  **
  private Int countLeadingClose(Str line)
  {
    count := 0
    for (i := 0; i < line.size; i++)
    {
      ch := line[i]
      if (ch == '}' || ch == ']') count++
      else if (ch == ' ' || ch == '\t') {} // whitespace between closers is OK
      else break
    }
    return count
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
