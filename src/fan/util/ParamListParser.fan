
**
** ParamListParser - Splits a parameter-list string into top-level parameter
** names, respecting nested (), [], and closure |...| delimiters so a closure
** parameter like "|V a, V b->Int|? c" isn't mis-split on its internal comma.
**
class ParamListParser
{
  **
  ** Parse a raw parameter-list string (the text between the outer parens,
  ** not including them) into ordered parameter names.
  ** Handles: "Type name", "Type? name", "Type name := default",
  ** and closure params "|...| name" / "|...|? name".
  ** Returns an empty list for an empty or unparsable string.
  **
  static Str[] paramNames(Str paramListStr)
  {
    names := Str[,]
    splitTopLevel(paramListStr).each |part|
    {
      name := lastParamName(part.trim)
      if (name != null) names.add(name)
    }
    return names
  }

  **
  ** Split a parameter-list string on top-level commas only — commas nested
  ** inside (), [], or |...| are preserved as part of the enclosing segment.
  **
  static Str[] splitTopLevel(Str s)
  {
    parts := Str[,]
    depth := 0
    pipeOpen := false
    start := 0
    i := 0
    while (i < s.size)
    {
      ch := s[i]
      if (ch == '|') pipeOpen = !pipeOpen
      else if (!pipeOpen && (ch == '(' || ch == '[')) depth++
      else if (!pipeOpen && (ch == ')' || ch == ']')) depth--
      else if (ch == ',' && depth == 0 && !pipeOpen)
      {
        parts.add(s[start..<i])
        start = i + 1
      }
      i++
    }
    if (start < s.size) parts.add(s[start..-1])
    else if (s.isEmpty) return Str[,]
    return parts
  }

  **
  ** Extract the parameter name from a single "Type name[ := default]" or
  ** "|closure sig| name" segment — the last bare identifier token, skipping
  ** any trailing default-value expression.
  **
  private static Str? lastParamName(Str segment)
  {
    if (segment.isEmpty) return null

    // Drop a trailing default value: "Type name := expr" -> "Type name"
    eqIdx := segment.index(":=")
    head := eqIdx != null ? segment[0..<eqIdx].trim : segment

    // For closure params ("|V a, V b->Int|? name"), only the text after the
    // closing '|' (and optional '?') is the param name itself.
    pipeEnd := head.indexr("|")
    afterPipe := pipeEnd != null ? head[pipeEnd + 1..-1].trim : head
    if (afterPipe.startsWith("?")) afterPipe = afterPipe[1..-1].trim
    tail := pipeEnd != null ? afterPipe : head

    words := tail.split(' ').findAll { !it.isEmpty }
    if (words.isEmpty) return null

    name := words.last
    if (name.isEmpty || !(name[0].isAlpha || name[0] == '_')) return null
    if (!name.all { it.isAlphaNum || it == '_' }) return null

    return name
  }
}
