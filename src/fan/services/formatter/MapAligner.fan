**
** Post-processing pass that aligns map literal values so all values in a
** block start at the same column (determined by the longest key in that block).
**
** Detects map literal blocks (a line ending in '[' with a matching ']' line)
** where ALL direct-child elements are map entries (key: value).  Pads the
** space after each ':' so values start at a consistent column.
**
** maxLineLength is respected: if the aligned line would exceed the limit a
** single space is used instead.
**
internal class MapAligner
{
  // ---------------------------------------------------------------------------
  // Public entry point
  // ---------------------------------------------------------------------------

  **
  ** Post-processing pass over the formatted output lines.
  ** Detects map literal blocks (a line ending in '[' with a matching ']'
  ** line) where ALL direct-child elements are map entries (key: value).
  ** Pads the space after each ':' so all values in the block start at
  ** the same column, determined by the longest key in that block.
  **
  ** Works for both freshly-expanded single-line maps and maps already
  ** written in multi-line form.  maxLineLength is respected: if the
  ** aligned line would exceed the limit a single space is used instead.
  **
  internal Str[] align(Str[] lines, FormatterOptions opts)
  {
    Str[] result := lines.dup
    n := result.size
    for (i := 0; i < n; i++)
    {
      trimmed := result[i].trim
      if (trimmed.isEmpty) continue
      if (trimmed[-1] != '[') continue

      closerIdx := findClosingBracketLine(result, i)
      if (closerIdx <= i + 1) continue

      // Collect direct-child element line indices (lines at relative depth 1
      // going into the line — not inside a nested bracket).
      Int[] directIdxs := [,]
      depth := 1  // we are inside the '[' on line i
      for (j := i + 1; j < closerIdx; j++)
      {
        jTrimmed := result[j].trim
        if (depth == 1 && !jTrimmed.isEmpty
            && !jTrimmed.startsWith("//") && !jTrimmed.startsWith("**"))
          directIdxs.add(j)
        depth += countLineBrackets(result[j])
      }

      // Only align when every direct child is a map entry (has key: value)
      if (directIdxs.isEmpty) continue
      if (!directIdxs.all |idx| { isMapEntry(result[idx].trim) }) continue

      // Max key length (colonIdx) across all direct children
      Int maxKLen := 0
      directIdxs.each |idx|
      {
        kl := mapKeyLen(result[idx].trim)
        if (kl > maxKLen) maxKLen = kl
      }
      if (maxKLen <= 0) continue

      // Re-pad each element so its value starts at column maxKLen + 2
      directIdxs.each |idx|
      {
        result[idx] = padMapEntry(result[idx], maxKLen, opts)
      }
    }
    return result
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  **
  ** Find the index of the line that closes the '[' opened on 'openerIdx'.
  ** Tracks bracket depth across lines (outside strings/comments).
  ** Returns -1 when no matching ']' is found.
  **
  private Int findClosingBracketLine(Str[] lines, Int openerIdx)
  {
    depth := 0
    for (i := openerIdx; i < lines.size; i++)
    {
      depth += countLineBrackets(lines[i])
      if (i > openerIdx && depth <= 0) return i
    }
    return -1
  }

  **
  ** Count the net '[' minus ']' on 'line', ignoring characters inside
  ** string literals and single-line comments.
  **
  private Int countLineBrackets(Str line)
  {
    inStr    := false
    inTriple := false
    inChar   := false
    inDsl    := false
    escaped  := false
    delta    := 0
    n        := line.size

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

      if (inDsl) { if (ch == '`') inDsl = false; continue }

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
  ** Return true when 'trimmed' looks like a map entry, i.e. it has a
  ** key ':' value separator at code level (outside strings, not '::').
  **
  private Bool isMapEntry(Str trimmed)
  {
    if (trimmed.isEmpty) return false
    return findMapColon(trimmed) >= 0
  }

  **
  ** Return the column index of the key-value ':' separator in a trimmed
  ** map-entry string, ignoring ':' inside string literals and '::'.
  ** Returns -1 when not found.
  **
  private Int findMapColon(Str elem)
  {
    inStr    := false
    inTriple := false
    inChar   := false
    inDsl    := false
    escaped  := false
    n        := elem.size

    for (i := 0; i < n; i++)
    {
      ch := elem[i]
      if (escaped) { escaped = false; continue }

      if (inTriple)
      {
        if (ch == '\\') { escaped = true; continue }
        if (ch == '"' && i+2 < n && elem[i+1] == '"' && elem[i+2] == '"')
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

      if (ch == '/' && i+1 < n && elem[i+1] == '/') break

      if (ch == '"' && i+2 < n && elem[i+1] == '"' && elem[i+2] == '"')
      { inTriple = true; i += 2; continue }

      if (ch == '"')  { inStr  = true; continue }
      if (ch == '\'') { inChar = true; continue }
      if (ch == '`')  { inDsl  = true; continue }

      if (ch == ':')
      {
        if (i+1 < n && elem[i+1] == ':') { i++; continue }  // skip '::'
        if (i > 0  && elem[i-1] == ':')  continue           // second ':' of '::'
        return i
      }
    }

    return -1
  }

  **
  ** Return the key length (colonIdx — the position of ':') for a trimmed
  ** map entry, or -1 when the element is not a map entry.
  **
  private Int mapKeyLen(Str trimmed)
  {
    return findMapColon(trimmed)
  }

  **
  ** Re-pad 'line' (a full line including leading indent) so that its map
  ** value starts at column: indentLen + maxKLen + 2  (key + ':' + 1 space
  ** minimum).  If the result would exceed maxLineLength a single space is
  ** used instead of the calculated padding.
  **
  private Str padMapEntry(Str line, Int maxKLen, FormatterOptions opts)
  {
    // Isolate leading whitespace
    wsEnd := 0
    while (wsEnd < line.size && (line[wsEnd] == ' ' || line[wsEnd] == '\t')) wsEnd++
    indent  := wsEnd > 0 ? line[0..<wsEnd] : ""
    trimmed := line.trim

    colonIdx := findMapColon(trimmed)
    if (colonIdx < 0) return line

    // trimmed[0..colonIdx] is inclusive in Fantom — gives "key:" (with colon)
    keyWithColon := trimmed[0..colonIdx]
    rest         := colonIdx + 1 < trimmed.size
      ? trimmed[colonIdx+1..-1].trim
      : ""
    if (rest.isEmpty) return line

    spaces  := (maxKLen - colonIdx + 1).max(1)
    newLine := indent + keyWithColon + " ".mult(spaces) + rest

    // Fall back to a single space when alignment would overflow the line limit
    if (opts.maxLineLength > 0 && newLine.size > opts.maxLineLength)
      newLine = indent + keyWithColon + " " + rest

    return newLine
  }
}
