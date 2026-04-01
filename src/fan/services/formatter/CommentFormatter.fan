**
** CommentFormatter — comment-aware formatting helpers.
**
** Provides three main services:
**
**   isBlockCommentOpener  — detect the opening line of a multi-line /* ... */
**                           block so callers can emit those lines verbatim.
**
**   wrapCommentLine       — word-wrap a '//' or '**' comment line at
**                           maxLineLength without applying NCSS rules.
**
**   convertDocComments    — post-pass that converts '//' or '/* */' comment
**                           blocks immediately before declarations to
**                           Fantom '**' doc-comment style (when the
**                           convertFantomDocComments option is enabled).
**
internal class CommentFormatter
{
  private FormatterUtils utils := FormatterUtils()

  // ---------------------------------------------------------------------------
  // Block-comment detection
  // ---------------------------------------------------------------------------

  **
  ** Return true when 'trimmed' is the opening line of a multi-line block
  ** comment (/* ... */) that does not close on the same line.
  **
  internal Bool isBlockCommentOpener(Str trimmed)
  {
    openIdx := trimmed.index("/*")
    if (openIdx == null) return false
    closeIdx := trimmed.index("*/")
    if (closeIdx == null) return true
    return closeIdx < openIdx
  }

  // ---------------------------------------------------------------------------
  // Comment line word-wrap
  // ---------------------------------------------------------------------------

  **
  ** Word-wrap a comment line (// or **) at 'maxLen' using simple whitespace
  ** breaks.  No NCSS rules (comma/operator splits) are applied.
  **
  ** Continuation lines use the same comment prefix as the original:
  **   "  // text"   → continuation "  // more text"
  **   "  ** text"   → continuation "  ** more text"
  **
  internal Str[] wrapCommentLine(Str fullLine, Int maxLen, FormatterOptions opts, Int indentLevel)
  {
    if (fullLine.size <= maxLen) return [fullLine]

    // Determine the continuation prefix (indent + comment marker + space)
    trimmed  := fullLine.trim
    indentStr := utils.makeIndent(opts, indentLevel)
    Str prefix := ""
    if (trimmed.startsWith("// "))      prefix = indentStr + "// "
    else if (trimmed.startsWith("//"))  prefix = indentStr + "// "
    else if (trimmed.startsWith("** ")) prefix = indentStr + "** "
    else if (trimmed.startsWith("**"))  prefix = indentStr + "** "
    else                                return [fullLine] // unknown style, leave as-is

    // Find the last space before maxLen — that's where we break
    breakAt := -1
    for (i := maxLen - 1; i > prefix.size; i--)
    {
      if (i < fullLine.size && fullLine[i] == ' ') { breakAt = i; break }
    }
    if (breakAt < 0) return [fullLine] // no break point, leave as-is

    part1 := fullLine[0..<breakAt]
    rest  := prefix + fullLine[breakAt+1..-1].trim

    Str[] result := [part1]
    wrapCommentLine(rest, maxLen, opts, indentLevel).each |l| { result.add(l) }
    return result
  }

  // ---------------------------------------------------------------------------
  // Doc-comment conversion post-pass
  // ---------------------------------------------------------------------------

  **
  ** Post-pass: when convertFantomDocComments is enabled, scan the output
  ** lines and convert '//' or '/* */' comment blocks that appear immediately
  ** before a method/field/class declaration into Fantom '**' doc comments.
  **
  ** Conversion rules:
  **   "// text"     → "** text"
  **   "/*"          → removed (bare opener line)
  **   " * text"     → "** text"
  **   " */"         → removed (closer line)
  **   "/* text */"  → "** text"  (single-line block comment before decl)
  **
  ** Only comment blocks IMMEDIATELY followed (no intervening blank lines)
  ** by a non-blank, non-comment, non-brace Fantom declaration line are
  ** converted.
  **
  internal Str[] convertDocComments(Str[] lines, FormatterOptions opts)
  {
    Str[] result := lines.dup
    n := result.size

    // Walk forward; whenever we find a convertible comment block, look ahead
    // to see if a declaration follows immediately (no blank lines between).
    i := 0
    while (i < n)
    {
      t := result[i].trim
      if (!isConvertibleCommentLine(t)) { i++; continue }

      // Collect the consecutive comment lines
      Int blockStart := i
      while (i < n && isConvertibleCommentLine(result[i].trim)) i++

      // i now points to the first non-comment line after the block
      if (i >= n) break // end of file — no declaration follows

      nextTrimmed := result[i].trim
      // Must be a non-blank, non-comment, non-brace declaration line
      if (nextTrimmed.isEmpty || isCommentLike(nextTrimmed)
          || nextTrimmed.startsWith("{") || nextTrimmed.startsWith("}")
          || nextTrimmed.startsWith("]") || nextTrimmed.startsWith("[")
          || nextTrimmed.startsWith("using "))
      {
        continue // don't convert this block
      }

      // Convert the block in-place
      Str[] converted := [,]
      for (j := blockStart; j < i; j++)
        converted.add(convertOneCommentLine(result[j]))

      for (j := blockStart; j < i; j++)
        result[j] = converted[j - blockStart]
    }
    return result
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  ** Return true when a trimmed line is a // or /* */ style comment
  ** (i.e. potentially convertible to Fantom ** style).
  private Bool isConvertibleCommentLine(Str t)
  {
    return t.startsWith("//") ||
           t.startsWith("/*") || t.startsWith("*/") ||
           (t.startsWith("*") && !t.startsWith("**"))
  }

  ** Return true when a trimmed line is any kind of comment.
  private Bool isCommentLike(Str t)
  {
    return t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
  }

  ** Convert a single comment line to ** style, preserving the leading indent.
  private Str convertOneCommentLine(Str line)
  {
    wsEnd := 0
    while (wsEnd < line.size && (line[wsEnd] == ' ' || line[wsEnd] == '\t')) wsEnd++
    indentStr := wsEnd > 0 ? line[0..<wsEnd] : ""
    t := line.trim

    // Drop bare openers/closers
    if (t == "/**" || t == "/*" || t == "*/") return ""

    // Single-line block comment: /* text */
    if (t.startsWith("/*") && t.endsWith("*/"))
    {
      inner := t[2..<t.size-2].trim
      if (inner.isEmpty) return ""
      return indentStr + "** " + inner
    }

    // Interior * line: "* text" or "** text" (already Fantom style)
    if (t.startsWith("* ") || t == "*")
    {
      inner := t.size > 2 ? t[2..-1] : ""
      return inner.isEmpty ? indentStr + "**" : indentStr + "** " + inner
    }

    // // line
    if (t.startsWith("// ")) return indentStr + "** " + t[3..-1]
    if (t.startsWith("//"))  return indentStr + "**"

    return line
  }
}
