**
** Shared low-level utilities used by FormatterService and its helper classes.
**
internal class FormatterUtils
{
  // ---------------------------------------------------------------------------
  // Indent building
  // ---------------------------------------------------------------------------

  ** Build an indent string for the given nesting level.
  internal Str makeIndent(FormatterOptions opts, Int level)
  {
    if (level <= 0) return ""
    if (opts.useTabs) return "\t".mult(level)
    n := level * opts.indentSize
    buf := StrBuf(n)
    n.times { buf.addChar(' ') }
    return buf.toStr
  }

  // ---------------------------------------------------------------------------
  // Line-level string helpers
  // ---------------------------------------------------------------------------

  **
  ** Strip a trailing '\r' if present.
  ** Fantom's splitLines strips '\n' and '\r\n' cleanly, but on some builds a
  ** lone '\r' at the end of a line element may survive for CRLF input.
  **
  internal Str stripCr(Str s)
  {
    if (s.size > 0 && s[-1] == '\r') return s[0..<s.size-1]
    return s
  }

  ** Strip leading whitespace only (preserve trailing whitespace).
  internal Str stripLeading(Str s)
  {
    i := 0
    while (i < s.size && (s[i] == ' ' || s[i] == '\t')) i++
    return i == 0 ? s : s[i..-1]
  }
}
