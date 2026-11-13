**
** ItBlockTracker — tells, column by column, whether code is inside an it-block
** such as `Foo { name = n }`, where bare names refer to the fields of the object
** being built and not to the enclosing class.
**
** Feed it masked source lines (see SourceMask) one at a time, in order; it
** keeps brace and parenthesis state across lines. A `{` opens an it-block when
** it follows a call `Foo(args)` or a type name `Foo`. It opens a normal block
** after a method declaration, a control keyword (`if`, `while`, ...), a
** lower-case word, a closure header `|x|` or at the start of the input.
**
class ItBlockTracker
{
  private static const Str[] controlKeywords :=
    ["if", "else", "for", "while", "switch", "catch", "try", "finally"]

  private static const Str[] nonTypeKeywords :=
    ["return", "throw", "else", "case", "default", "in", "is", "isnot", "as", "const", "static"]

  ** Open braces; true marks an it-block.
  private Bool[] braces := Bool[,]

  ** Open parentheses; each entry is "<headWord>" or "<decl>" for declarations.
  private Str[] parens := Str[,]

  private Str lastKind := "none"
  private Str lastText := ""
  private Str prevKind := "none"
  private Str prevText := ""

  **
  ** Scan one masked line. Returns one flag per column: true when that
  ** column is inside an it-block.
  **
  Bool[] scan(Str line)
  {
    flags := Bool[,]
    line.size.times { flags.add(false) }
    i := 0
    while (i < line.size)
    {
      ch := line[i]
      if (ch.isSpace) { i++; continue }

      inIt := braces.contains(true)
      if (ch.isAlpha || ch == '_')
      {
        start := i
        while (i < line.size && (line[i].isAlphaNum || line[i] == '_')) i++
        (start ..< i).each |c| { flags[c] = inIt }
        shift("ident", line[start ..< i])
        continue
      }

      flags[i] = inIt
      handlePunct(ch)
      i++
    }
    return flags
  }

  private Void handlePunct(Int ch)
  {
    if (ch == '(') { openParen; return }
    if (ch == ')') { closeParen; return }
    if (ch == '{') { braces.add(opensItBlock); shift("punct", "{"); return }
    if (ch == '}') { if (!braces.isEmpty) braces.removeAt(-1); shift("punct", "}"); return }
    shift("punct", ch.toChar)
  }

  private Void openParen()
  {
    head := lastKind == "ident" ? lastText : ""
    isDecl := head != "" && ((prevKind == "ident" && !nonTypeKeywords.contains(prevText)) ||
                             (prevKind == "punct" && (prevText == "?" || prevText == "]")))
    parens.add(isDecl ? "<decl>" : head)
    shift("punct", "(")
  }

  private Void closeParen()
  {
    head := parens.isEmpty ? "" : parens.removeAt(-1)
    shift("close", head)
  }

  ** True if the `{` being read opens an it-block.
  private Bool opensItBlock()
  {
    if (lastKind == "close")
      return lastText != "<decl>" && lastText != "" && !controlKeywords.contains(lastText)
    if (lastKind == "ident")
      return !controlKeywords.contains(lastText) && lastText[0].isUpper
    return false
  }

  private Void shift(Str kind, Str text)
  {
    prevKind = lastKind
    prevText = lastText
    lastKind = kind
    lastText = text
  }
}
