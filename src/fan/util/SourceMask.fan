**
** SourceMask — produces a same-size copy of Fantom source in which the
** contents of string, char and backtick literals and all comments are
** replaced by spaces.
**
** Line breaks are kept and string delimiters are kept, so line and column
** positions match the original and argument counts still see one value
** per literal (`f("a,b")` becomes `f("   ")`). Validators that look for
** identifiers or `Type.member` patterns scan the masked text so that text
** inside literals and comments is never mistaken for code.
**
class SourceMask
{
  **
  ** Return `source` with literal contents and comments blanked out.
  ** The result always has the same size as `source`.
  **
  static Str mask(Str source)
  {
    buf := StrBuf(source.size)
    FantomLexer.tokenize(source).each |tok|
    {
      switch (tok.kind)
      {
        case TokenKind.strLit:
          buf.add(blankLiteral(tok.text, tok.text.startsWith("\"\"\"") ? 3 : 1))
        case TokenKind.charLit:
        case TokenKind.dslLit:
          buf.add(blankLiteral(tok.text, 1))
        case TokenKind.lineComment:
        case TokenKind.blockComment:
          buf.add(blank(tok.text))
        default:
          buf.add(tok.text)
      }
    }
    return buf.toStr
  }

  ** Blank the inside of a literal, keeping `delim` opening and closing chars.
  private static Str blankLiteral(Str text, Int delim)
  {
    opener := text[0 ..< delim]
    closed := text.size >= delim * 2 && text.endsWith(opener)
    innerEnd := closed ? text.size - delim : text.size
    return opener + blank(text[delim ..< innerEnd]) + (closed ? opener : "")
  }

  ** Replace every character except line breaks with a space.
  private static Str blank(Str text)
  {
    buf := StrBuf(text.size)
    text.each |ch| { buf.addChar(ch == '\n' || ch == '\r' ? ch : ' ') }
    return buf.toStr
  }
}
