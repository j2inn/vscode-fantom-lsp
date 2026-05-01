**
** FantomScanner — character-by-character walker for a single line of Fantom source.
**
** Tracks all string-literal and comment context so callers never need to
** re-implement the state machine.  Create one instance per line; use
** SourceWalker to carry cross-line state across multiple lines.
**
** Supported literal types:
**   "..."     — double-quoted string with escape sequences
**   """...""" — triple-quoted string with escape sequences
**   '.'       — single-quoted character literal (with escapes)
**   `...`     — backtick DSL / raw string (no escapes)
**   //        — single-line comment (rest of line is opaque)
**   /* ... */ — block comment (may span lines; cross-line state via SourceWalker)
**
class FantomScanner
{
  ** The line being scanned.
  const Str line

  ** Current character position (0-based).
  Int pos := 0

  // ---- string / comment context ----
  ** True while inside a double-quoted string.
  Bool inStr := false

  ** True while inside a triple-quoted string.
  Bool inTriple := false

  ** True while inside a single-quoted char literal.
  Bool inChar := false

  ** True while inside a backtick DSL string.
  Bool inDsl := false

  ** True while inside a block comment (/* ... */).
  Bool inBlock := false

  ** True when the previous character was a backslash escape inside a literal.
  Bool escaped := false

  new make(Str line) { this.line = line }

  ** Construct and seed cross-line block-comment state from a prior line.
  new makeWithState(Str line, Bool inBlock) { this.line = line; this.inBlock = inBlock }

  // -------------------------------------------------------------------------
  // Query helpers
  // -------------------------------------------------------------------------

  ** True when the current position is inside any literal or comment context.
  Bool isInLiteral() { inStr || inTriple || inChar || inDsl || inBlock }

  ** True when the scanner has consumed all characters.
  Bool isDone() { pos >= line.size }

  ** The character at the current position, or null when done.
  Int? current() { pos < line.size ? line[pos] : null }

  ** Peek at the character at pos+offset without advancing.
  Int? peek(Int offset := 1) { (pos + offset) < line.size ? line[pos + offset] : null }

  // -------------------------------------------------------------------------
  // Advancement
  // -------------------------------------------------------------------------

  **
  ** Advance one character and update internal context state.
  ** Returns the character that was consumed, or null when already done.
  **
  ** Call this in your outer while loop; check isInLiteral() after each step
  ** if you only want to act on "bare code" characters.
  **
  Int? advance()
  {
    if (pos >= line.size) return null
    ch := line[pos]
    pos++
    _updateState(ch)
    return ch
  }

  **
  ** Skip forward until the predicate returns true (position lands ON the
  ** matching character, without consuming it) or the line ends.
  ** Context state is updated for every skipped character.
  **
  Void skipUntil(|Int ch -> Bool| pred)
  {
    while (pos < line.size)
    {
      ch := line[pos]
      if (pred(ch)) return
      pos++
      _updateState(ch)
    }
  }

  **
  ** Skip forward past the end of the current literal/comment context.
  ** Has no effect when not in a literal.
  **
  Void skipToEndOfLiteral()
  {
    while (pos < line.size && isInLiteral)
      advance
  }

  // -------------------------------------------------------------------------
  // Internal state machine
  // -------------------------------------------------------------------------

  private Void _updateState(Int ch)
  {
    // Handle escape flag from previous character
    if (escaped) { escaped = false; return }

    // Inside block comment — look for closing */
    if (inBlock)
    {
      if (ch == '*' && pos < line.size && line[pos] == '/')
        { inBlock = false; pos++ }
      return
    }

    // Inside triple-quoted string
    if (inTriple)
    {
      if (ch == '\\') { escaped = true; return }
      if (ch == '"' && pos + 1 < line.size && line[pos] == '"' && line[pos + 1] == '"')
        { inTriple = false; pos += 2 }
      return
    }

    // Inside double-quoted string
    if (inStr)
    {
      if (ch == '\\') { escaped = true; return }
      if (ch == '"') inStr = false
      return
    }

    // Inside single-quoted char literal
    if (inChar)
    {
      if (ch == '\\') { escaped = true; return }
      if (ch == '\'') inChar = false
      return
    }

    // Inside backtick DSL (no escapes)
    if (inDsl)
    {
      if (ch == '`') inDsl = false
      return
    }

    // Not inside any literal — detect new contexts

    // Single-line comment: rest of line is opaque — jump to end
    if (ch == '/' && pos < line.size && line[pos] == '/')
      { pos = line.size; return }

    // Block comment open
    if (ch == '/' && pos < line.size && line[pos] == '*')
      { inBlock = true; pos++; return }

    // Triple-quoted string (check before single double-quote)
    if (ch == '"' && pos + 1 < line.size && line[pos] == '"' && line[pos + 1] == '"')
      { inTriple = true; pos += 2; return }

    if (ch == '"') { inStr = true; return }
    if (ch == '\'') { inChar = true; return }
    if (ch == '`') { inDsl = true; return }
  }
}
