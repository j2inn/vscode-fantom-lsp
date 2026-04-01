**
** Two-pass bracket literal handler:
**
** 1. normalize(lines) — pre-pass that rebuilds every multi-line bracket
**    literal block into canonical one-element-per-line form before the rest
**    of the formatter runs.
**
** 2. tryExpand(fullLine, opts, indentLevel) — per-line pass that expands a
**    single-line list/map literal '[...]' into one-element-per-line form.
**    Nested bracket literals inside elements are expanded recursively.
**
internal class BracketNormalizer
{
  private FormatterUtils utils := FormatterUtils()

  // ---------------------------------------------------------------------------
  // Pass 1: multi-line block normalizer
  // ---------------------------------------------------------------------------

  **
  ** Pre-pass: rebuild every multi-line bracket literal block into canonical
  ** form so the rest of the formatter can treat every element as a single
  ** source line.
  **
  ** A "block" is any sequence of source lines that begins with a line
  ** containing a qualifying '[' whose matching ']' does not appear on the
  ** same source line.  The pass collects all source text from the '[' to the
  ** matching ']' (across as many lines as needed), then emits:
  **
  **   prefix [            — everything before and including the opener '['
  **   element1,           — each element, one per line, trimmed
  **   // comment          — // comment-only lines preserved verbatim
  **   element2,
  **   ]suffix             — the closer ']' plus any suffix (e.g. a semicolon)
  **
  ** Block-comment openers (/* ... */) before the first real element on the
  ** opener line are discarded (they were typically spacing artefacts like
  ** "/* Fantom */" used for visual alignment in hand-written files).
  **
  ** Lines that contain no qualifying '[' (or only single-element complete
  ** literals "[ x ]") are passed through unchanged.
  **
  internal Str[] normalize(Str[] lines)
  {
    Str[] result := [,]
    i := 0
    while (i < lines.size)
    {
      raw := utils.stripCr(lines[i])
      trimmed := raw.trim

      // Find a qualifying '[' on this line that has no matching ']' on the
      // same line — that signals the start of a multi-line bracket block.
      bracketPos := findListBracket(trimmed)

      // If no qualifying '[' at all, pass through unchanged.
      if (bracketPos < 0) { result.add(raw); i++; continue }

      // If there IS a matching ']' on the same line, let the normal expansion
      // path handle it (single-line literal).  Pass through unchanged here.
      closeOnSameLine := findMatchingBracket(trimmed, bracketPos)
      if (closeOnSameLine >= 0) { result.add(raw); i++; continue }

      // Multi-line block: collect all source text from '[' to matching ']'.
      // Everything up to and including '[' is the prefix; we discard any
      // block-comment text between '[' and the first real token on the opener
      // line (e.g. "/* Fantom */").
      prefix := trimmed[0..bracketPos]  // includes '['

      // We assemble "logical elements" — each element is a list of source lines
      // (trimmed) that belong together (e.g. a nested bracket block).
      // depthOneElems accumulates [Str[]] — one entry per depth-1 element.
      Str[][] depthOneElems := [,]
      Str[] currentElem := [,]  // lines of the current depth-1 element
      Int blockDepth := 1       // we are inside the opening '['
      closerSuffix := ""        // text after the closing ']' on its line

      // Consume remainder of opener line (after '[')
      afterOpen := bracketPos + 1 < trimmed.size
        ? trimmed[bracketPos+1..-1].trim
        : ""
      // Strip a single leading block-comment from the opener remainder
      afterOpen = stripLeadingBlockComment(afterOpen)

      // Process the opener remainder as depth-1 content
      if (!afterOpen.isEmpty)
        processDepthOneLine(afterOpen, depthOneElems, currentElem, blockDepth)
      blockDepth = 1 + countBracketDelta(afterOpen)

      i++
      // Walk subsequent lines until blockDepth reaches 0
      while (i < lines.size && blockDepth > 0)
      {
        nextRaw := utils.stripCr(lines[i]).trim
        if (nextRaw.isEmpty)
        {
          // Blank separator: flush current element if any, emit blank marker
          if (!currentElem.isEmpty) { depthOneElems.add(currentElem); currentElem = [,] }
          depthOneElems.add([""])  // blank separator
          i++
          continue
        }

        delta := countBracketDelta(nextRaw)

        if (blockDepth == 1 && delta == 0)
        {
          // Simple depth-1 line — may contain comma-separated elements
          processDepthOneLine(nextRaw, depthOneElems, currentElem, blockDepth)
        }
        else if (blockDepth + delta <= 0)
        {
          // This line contains the closing ']'
          closerResult := splitAtCloser(nextRaw)
          beforeClose := closerResult[0].trim
          if (!beforeClose.isEmpty)
            processDepthOneLine(beforeClose, depthOneElems, currentElem, blockDepth)
          // Flush current element
          if (!currentElem.isEmpty) { depthOneElems.add(currentElem); currentElem = [,] }
          closerSuffix = closerResult[1].trim
          blockDepth = 0
        }
        else
        {
          // Line at depth > 1 (inside a nested bracket) or starts a nested block
          currentElem.add(nextRaw)
          blockDepth += delta
          // If depth returned to 1 AND line ends with ',': that comma closes the
          // element.  Close it now so subsequent lines start a fresh element.
          if (blockDepth == 1 && endsDepthOneComma(nextRaw))
          {
            depthOneElems.add(currentElem)
            currentElem = [,]
          }
        }
        i++
      }
      // Flush any trailing partial element
      if (!currentElem.isEmpty) depthOneElems.add(currentElem)

      // Emit normalised block
      result.add(prefix)
      depthOneElems.each |elem|
      {
        if (elem.size == 1 && elem[0].isEmpty) { result.add(""); return }
        if (elem.size == 1)
        {
          t := elem[0].trim
          if (t.isEmpty) return
          // Comment-only lines — emit verbatim, no trailing comma manipulation
          if (t.startsWith("//") || t.startsWith("**")) { result.add(t); return }
          // Ensure exactly one trailing comma, placed BEFORE any trailing // comment
          result.add(ensureTrailingComma(t))
        }
        else
        {
          // Multi-line element (nested bracket block) — emit lines as-is
          // but ensure the final non-empty line ends with a trailing comma.
          Str[] subLines := elem.dup
          // Find the last non-empty line and make it end with ','
          Int lastNonEmpty := subLines.size - 1
          while (lastNonEmpty >= 0 && subLines[lastNonEmpty].trim.isEmpty) lastNonEmpty--
          if (lastNonEmpty >= 0)
          {
            last := subLines[lastNonEmpty].trim
            if (!last.endsWith(",")) last = last + ","
            subLines[lastNonEmpty] = last
          }
          subLines.each |sl| { result.add(sl.trim) }
        }
      }
      result.add("]" + (closerSuffix.isEmpty ? "" : closerSuffix))
    }
    return result
  }

  // ---------------------------------------------------------------------------
  // Pass 2: single-line bracket literal expander
  // ---------------------------------------------------------------------------

  **
  ** Expand a list or map literal '[...]' to one-element-per-line form.
  ** Returns the expanded lines, or null when expansion is not applicable
  ** (no qualifying '[' found, the literal is empty, or the '[' looks like
  ** an index-access expression).
  **
  ** Every element is placed on its own line, indented one level deeper than
  ** 'indentLevel'.  A trailing comma is added to every element.  The closing
  ** ']' is placed at 'indentLevel'.  Nested bracket literals inside any
  ** element are expanded recursively, so maps-of-maps and lists-of-lists are
  ** fully expanded in a single pass.
  **
  ** Single-element lists and maps are expanded just like multi-element ones —
  ** the formatter never leaves a list or map on a single line.
  **
  ** After 'normalize' has run, lines with unclosed '[' will have no elements
  ** after the opener — the closePos<0 path just passes them through.
  **
  internal Str[]? tryExpand(Str fullLine, FormatterOptions opts, Int indentLevel)
  {
    bracketPos := findListBracket(fullLine)
    if (bracketPos < 0) return null

    closePos := findMatchingBracket(fullLine, bracketPos)

    // No closing ']' on this line (after normalize, this means the line is
    // simply "prefix [" with nothing after the opener).
    // Pass through unchanged — the rest of the block is on subsequent lines.
    if (closePos < 0) return null

    inner := closePos > bracketPos + 1 ? fullLine[bracketPos+1..<closePos] : ""
    elements := splitAtDepthZero(inner).findAll |e| { !e.trim.isEmpty }
    // An empty literal '[]' — nothing to expand.
    if (elements.isEmpty) return null

    prefix := fullLine[0..bracketPos]  // everything up to and including '['
    suffix := closePos + 1 < fullLine.size
      ? fullLine[closePos+1..-1].trim
      : ""
    childIndent := utils.makeIndent(opts, indentLevel + 1)
    closingIndent := utils.makeIndent(opts, indentLevel)

    Str[] result := [,]
    result.add(prefix)
    elements.each |elem|
    {
      e := elem.trim
      // Strip a leading block comment (e.g. "/* Fantom */ \"sys\"") — these
      // are layout artefacts sometimes written inline in the opener.
      e = stripLeadingBlockComment(e)
      if (e.isEmpty) return
      if (e.endsWith(",")) e = e[0..<e.size-1].trim
      // Recursively expand any nested bracket literal inside this element
      // (e.g. a map-of-maps: "key": ["inner": val], or a nested list).
      elemLine := childIndent + e + ","
      nested := tryExpand(elemLine, opts, indentLevel + 1)
      if (nested != null)
        nested.each |l| { result.add(l) }
      else
        result.add(elemLine)
    }
    result.add(closingIndent + "]" + (suffix.isEmpty ? "" : suffix))
    return result
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  **
  ** Process a single trimmed line at depth 1 inside a bracket block.
  ** Splits top-level comma-separated elements and accumulates them into
  ** 'currentElem' and 'depthOneElems'.  An inline trailing // comment on
  ** the last token is kept with that token.
  **
  private Void processDepthOneLine(Str line, Str[][] depthOneElems, Str[] currentElem, Int blockDepth)
  {
    t := line.trim
    if (t.isEmpty) return
    // Comment-only line
    if (t.startsWith("//") || t.startsWith("**"))
    {
      if (!currentElem.isEmpty) { depthOneElems.add(currentElem.dup); currentElem.clear }
      depthOneElems.add([t])
      return
    }
    // Split at top-level commas, keeping // tail comments with their element
    Str[] parts := splitAtDepthZeroKeepTailComment(t)
    parts.each |part|
    {
      p := part.trim
      if (p.isEmpty) return
      // Check if this part opens a nested bracket without closing it
      nestBracket := findListBracket(p)
      if (nestBracket >= 0 && findMatchingBracket(p, nestBracket) < 0)
      {
        // Starts a nested block — add to current; caller handles depth tracking
        currentElem.add(p)
      }
      else
      {
        // Complete element: flush currentElem, emit this element
        if (!currentElem.isEmpty) { depthOneElems.add(currentElem.dup); currentElem.clear }
        depthOneElems.add([p])
      }
    }
  }

  **
  ** Return true when 'line' ends with '],' or '}' at depth 0, meaning a
  ** nested block just closed and its element ended.
  **
  private Bool endsDepthOneComma(Str line)
  {
    t := line.trim
    return t.endsWith("],") || t.endsWith("},")
  }

  **
  ** Like splitAtDepthZero but keeps the trailing // comment attached to
  ** the last element rather than as a separate empty-ish segment.
  **
  private Str[] splitAtDepthZeroKeepTailComment(Str s)
  {
    // Find trailing // comment position (outside strings/brackets)
    commentPos := findTrailingCommentPos(s)
    Str tail := ""
    Str code  := s
    if (commentPos >= 0)
    {
      code = s[0..<commentPos].trimEnd
      tail = s[commentPos..-1]  // "// ..."
    }
    parts := splitAtDepthZero(code)
    if (tail.isEmpty) return parts
    // Attach tail comment to the last non-empty part
    Int lastIdx := parts.size - 1
    while (lastIdx >= 0 && parts[lastIdx].trim.isEmpty) lastIdx--
    if (lastIdx >= 0)
      parts[lastIdx] = parts[lastIdx] + " " + tail
    else
      parts.add(tail)
    return parts
  }

  **
  ** Find the start position of a trailing // comment in 'line' (outside
  ** string literals).  Returns -1 when none found.
  **
  private Int findTrailingCommentPos(Str line)
  {
    inStr    := false
    inTriple := false
    inChar   := false
    inDsl    := false
    inBlock  := false
    escaped  := false
    n        := line.size

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
      if (ch == '/' && i+1 < n && line[i+1] == '/') return i

      if (ch == '"' && i+2 < n && line[i+1] == '"' && line[i+2] == '"')
      { inTriple = true; i += 2; continue }
      if (ch == '"')  { inStr  = true; continue }
      if (ch == '\'') { inChar = true; continue }
      if (ch == '`')  { inDsl  = true; continue }
    }
    return -1
  }

  **
  ** Split 'line' at the first ']' whose bracket depth (relative to caller's
  ** context) returns to 0 — i.e. the first unmatched ']'.
  ** Returns [beforeCloser, afterCloser] (both may be empty strings).
  **
  private Str[] splitAtCloser(Str line)
  {
    inStr    := false
    inTriple := false
    inChar   := false
    inDsl    := false
    inBlock  := false
    escaped  := false
    depth    := 0
    n        := line.size

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
      if (ch == '"')  { inStr  = true; continue }
      if (ch == '\'') { inChar = true; continue }
      if (ch == '`')  { inDsl  = true; continue }

      if      (ch == '[') depth++
      else if (ch == ']')
      {
        if (depth == 0)
          return [line[0..<i], i + 1 < n ? line[i+1..-1] : ""]
        depth--
      }
    }
    return [line, ""]
  }

  **
  ** Count the net bracket delta ([ opens minus ] closes) on a single
  ** trimmed line, ignoring content inside string literals, block comments,
  ** and single-line comments.
  **
  private Int countBracketDelta(Str line)
  {
    inStr    := false
    inTriple := false
    inChar   := false
    inDsl    := false
    inBlock  := false
    escaped  := false
    delta    := 0
    n        := line.size

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
      if (ch == '"')  { inStr  = true; continue }
      if (ch == '\'') { inChar = true; continue }
      if (ch == '`')  { inDsl  = true; continue }

      if      (ch == '[') delta++
      else if (ch == ']') delta--
    }
    return delta
  }

  **
  ** Strip a leading block comment (/* ... */) from a fragment, returning
  ** the rest.  Only one leading comment is removed; further text is kept.
  **
  private Str stripLeadingBlockComment(Str s)
  {
    t := s.trim
    if (!t.startsWith("/*")) return t
    end := t.index("*/")
    if (end == null) return ""
    return t[end+2..-1].trim
  }

  **
  ** Ensure 'elem' (a trimmed element text, possibly with a trailing //
  ** comment) ends with exactly one comma placed in the code part — before
  ** any trailing // comment.  Does not touch comment-only strings.
  **
  private Str ensureTrailingComma(Str elem)
  {
    if (elem.isEmpty) return elem
    commentPos := findTrailingCommentPos(elem)
    if (commentPos < 0)
    {
      // No trailing comment — work on the whole string
      t := elem.trimEnd
      if (t.endsWith(",")) return t
      return t + ","
    }
    // Split into code part and comment tail
    code    := elem[0..<commentPos].trimEnd
    comment := elem[commentPos..-1]
    if (code.endsWith(",")) return code + " " + comment
    return code + ", " + comment
  }

  **
  ** Find the first '[' in 'line' that looks like a list/map literal rather
  ** than an index-access or array-type expression.
  **
  ** Returns the index of '[', or -1 when none qualifies.
  **
  ** A '[' qualifies when it is:
  **   - outside string literals and single-line comments
  **   - not inside parentheses (parenDepth == 0)
  **   - not immediately preceded by an identifier character, '_', ')', or ']'
  **     (which would indicate an index-access or type-annotation context)
  **
  private Int findListBracket(Str line)
  {
    inStr := false
    inTriple := false
    inChar := false
    inDsl := false
    inBlock := false
    escaped := false
    parenDepth := 0
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

      if (inDsl)
      {
        if (ch == '`') inDsl = false
        continue
      }

      if (ch == '/' && i+1 < n && line[i+1] == '*') { inBlock = true; i++; continue }
      if (ch == '/' && i+1 < n && line[i+1] == '/') break

      if (ch == '"' && i+2 < n && line[i+1] == '"' && line[i+2] == '"')
      { inTriple = true; i += 2; continue }

      if (ch == '"') { inStr = true; continue }
      if (ch == '\'') { inChar = true; continue }
      if (ch == '`') { inDsl = true; continue }

      if (ch == '(') { parenDepth++; continue }
      if (ch == ')') { parenDepth = (parenDepth - 1).max(0); continue }

      if (ch == '[' && parenDepth == 0)
      {
        prevCh := i > 0 ? line[i-1] : ' '
        if (!prevCh.isAlphaNum && prevCh != '_' && prevCh != ')' && prevCh != ']')
          return i
      }
    }
    return -1
  }

  **
  ** Find the ']' that closes the '[' at 'openPos'. Returns the index of
  ** the matching ']', or -1 when no match is found (unclosed bracket).
  ** String literals and single-line comments are tracked so delimiters
  ** inside them do not produce false matches.
  **
  private Int findMatchingBracket(Str line, Int openPos)
  {
    inStr := false
    inTriple := false
    inChar := false
    inDsl := false
    inBlock := false
    escaped := false
    depth := 0
    n := line.size

    for (i := openPos; i < n; i++)
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

      if (inDsl)
      {
        if (ch == '`') inDsl = false
        continue
      }

      if (ch == '/' && i+1 < n && line[i+1] == '*') { inBlock = true; i++; continue }
      if (ch == '/' && i+1 < n && line[i+1] == '/') break

      if (ch == '"' && i+2 < n && line[i+1] == '"' && line[i+2] == '"')
      { inTriple = true; i += 2; continue }

      if (ch == '"') { inStr = true; continue }
      if (ch == '\'') { inChar = true; continue }
      if (ch == '`') { inDsl = true; continue }

      if (ch == '[') depth++
      else if (ch == ']')
      {
        depth--
        if (depth == 0) return i
      }
    }
    return -1
  }

  **
  ** Split 's' by commas at parse depth 0, tracking string literals, block
  ** comments, and nested brackets/parentheses so only top-level commas are
  ** treated as separators.
  **
  ** Returns a list of the comma-separated segments; the list may contain
  ** empty strings when there are leading, trailing, or consecutive commas.
  **
  private Str[] splitAtDepthZero(Str s)
  {
    Str[] result := [,]
    buf := StrBuf()
    inStr := false
    inTriple := false
    inChar := false
    inDsl := false
    inBlock := false
    escaped := false
    depth := 0
    n := s.size

    for (i := 0; i < n; i++)
    {
      ch := s[i]
      if (escaped) { escaped = false; buf.addChar(ch); continue }

      if (inBlock)
      {
        if (ch == '*' && i+1 < n && s[i+1] == '/')
        { inBlock = false; buf.addChar(ch); buf.addChar(s[i+1]); i++ }
        else buf.addChar(ch)
        continue
      }

      if (inTriple)
      {
        if (ch == '\\') { escaped = true; buf.addChar(ch); continue }
        if (ch == '"' && i+2 < n && s[i+1] == '"' && s[i+2] == '"')
        {
          buf.addChar(ch); buf.addChar(s[i+1]); buf.addChar(s[i+2])
          i += 2; inTriple = false; continue
        }
        buf.addChar(ch); continue
      }

      if (inStr)
      {
        if (ch == '\\') { escaped = true; buf.addChar(ch); continue }
        if (ch == '"') inStr = false
        buf.addChar(ch); continue
      }

      if (inChar)
      {
        if (ch == '\\') { escaped = true; buf.addChar(ch); continue }
        if (ch == '\'') inChar = false
        buf.addChar(ch); continue
      }

      if (inDsl)
      {
        if (ch == '`') inDsl = false
        buf.addChar(ch); continue
      }

      // Single-line comment: copy rest verbatim as part of current element
      if (ch == '/' && i+1 < n && s[i+1] == '/')
      {
        for (j := i; j < n; j++) buf.addChar(s[j])
        break
      }

      // Block comment open
      if (ch == '/' && i+1 < n && s[i+1] == '*')
      { inBlock = true; buf.addChar(ch); buf.addChar(s[i+1]); i++; continue }

      if (ch == '"' && i+2 < n && s[i+1] == '"' && s[i+2] == '"')
      { inTriple = true; buf.addChar(ch); buf.addChar(s[i+1]); buf.addChar(s[i+2]); i += 2; continue }

      if (ch == '"') { inStr = true; buf.addChar(ch); continue }
      if (ch == '\'') { inChar = true; buf.addChar(ch); continue }
      if (ch == '`') { inDsl = true; buf.addChar(ch); continue }

      if (ch == '(' || ch == '[' || ch == '{') { depth++; buf.addChar(ch); continue }
      if (ch == ')' || ch == ']' || ch == '}') { depth = (depth - 1).max(0); buf.addChar(ch); continue }

      if (depth == 0 && ch == ',')
      {
        result.add(buf.toStr)
        buf = StrBuf()
        continue
      }

      buf.addChar(ch)
    }
    result.add(buf.toStr)
    return result
  }
}
