**
** Wraps long lines by finding the best split point and breaking the line
** into multiple continuation lines.
**
internal class LineWrapper
{
  private FormatterUtils utils := FormatterUtils()

  // ---------------------------------------------------------------------------
  // Public entry point
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
  **    e.g. "hello world" becomes "hello" + \n"world"
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
  internal Str[] wrap(Str fullLine, Int maxLen, FormatterOptions opts, Int indentLevel)
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

    contLine := utils.makeIndent(opts, indentLevel + 1) + rest

    result := Str[,]
    result.add(part1)
    wrap(contLine, maxLen, opts, indentLevel + 1).each |l| { result.add(l) }
    return result
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

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
    strMode := -1 // 2 or 3 (matches wrap mode)
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
}
