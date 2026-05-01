**
** Token kinds produced by FantomLexer.
**
enum class TokenKind
{
  strLit,       // "..." or """..."""
  charLit,      // '.'
  dslLit,       // `...`
  lineComment,  // // ...
  blockComment, // /* ... */ (may span multiple lines)
  identifier,   // [A-Za-z_][A-Za-z0-9_]*
  punct,        // any single non-whitespace, non-identifier character
  whitespace    // spaces / tabs / newlines
}

**
** A single token produced by FantomLexer.
**
class Token
{
  const TokenKind kind
  const Str text
  ** Line index (0-based) where the token starts.
  const Int line
  ** Column index (0-based) where the token starts.
  const Int col

  new make(TokenKind kind, Str text, Int line, Int col)
  {
    this.kind = kind
    this.text = text
    this.line = line
    this.col  = col
  }

  override Str toStr() { "${kind}@${line}:${col} ${text.toCode}" }
}

**
** FantomLexer — tokenizes a complete Fantom source string into a Token[].
**
** Tokens cover the full source without gaps: every character belongs to
** exactly one token.  Use TokenKind to filter; skip strLit / charLit /
** dslLit / lineComment / blockComment to work only with code tokens.
**
class FantomLexer
{
  **
  ** Tokenize source and return the flat token list.
  **
  static Token[] tokenize(Str source)
  {
    FantomLexer(source)._run
  }

  // -------------------------------------------------------------------------

  private Str src
  private Int pos     := 0
  private Int lineIdx := 0
  private Int colIdx  := 0
  private Token[] tokens := Token[,]

  private new make(Str src) { this.src = src }

  private Token[] _run()
  {
    while (pos < src.size)
    {
      startLine := lineIdx
      startCol  := colIdx
      ch := src[pos]

      // ---- newline ----
      if (ch == '\n')
      {
        tokens.add(Token(TokenKind.whitespace, "\n", startLine, startCol))
        pos++; lineIdx++; colIdx = 0
        continue
      }
      if (ch == '\r')
      {
        text := (pos + 1 < src.size && src[pos + 1] == '\n') ? "\r\n" : "\r"
        tokens.add(Token(TokenKind.whitespace, text, startLine, startCol))
        pos += text.size; lineIdx++; colIdx = 0
        continue
      }

      // ---- block comment /* ... */ ----
      if (ch == '/' && _peek(1) == '*')
      {
        buf := StrBuf()
        buf.addChar(ch); pos++; colIdx++
        buf.addChar(src[pos]); pos++; colIdx++
        while (pos < src.size)
        {
          c := src[pos]
          if (c == '\n')
          {
            buf.addChar(c); pos++; lineIdx++; colIdx = 0
          }
          else if (c == '\r')
          {
            buf.addChar(c); pos++
            if (pos < src.size && src[pos] == '\n') { buf.addChar(src[pos]); pos++ }
            lineIdx++; colIdx = 0
          }
          else if (c == '*' && _peek(1) == '/')
          {
            buf.addChar(c); pos++; colIdx++
            buf.addChar(src[pos]); pos++; colIdx++
            break
          }
          else { buf.addChar(c); pos++; colIdx++ }
        }
        tokens.add(Token(TokenKind.blockComment, buf.toStr, startLine, startCol))
        continue
      }

      // ---- line comment // ... ----
      if (ch == '/' && _peek(1) == '/')
      {
        buf := StrBuf()
        while (pos < src.size && src[pos] != '\n' && src[pos] != '\r')
          { buf.addChar(src[pos]); pos++; colIdx++ }
        tokens.add(Token(TokenKind.lineComment, buf.toStr, startLine, startCol))
        continue
      }

      // ---- triple-quoted string """...""" ----
      if (ch == '"' && _peek(1) == '"' && _peek(2) == '"')
      {
        buf := StrBuf()
        3.times { buf.addChar(src[pos]); pos++; colIdx++ }
        while (pos < src.size)
        {
          c := src[pos]
          if (c == '\\' && pos + 1 < src.size)
            { buf.addChar(c); buf.addChar(src[pos+1]); pos += 2; colIdx += 2 }
          else if (c == '"' && _peek(1) == '"' && _peek(2) == '"')
          {
            3.times { buf.addChar(src[pos]); pos++; colIdx++ }
            break
          }
          else if (c == '\n')
            { buf.addChar(c); pos++; lineIdx++; colIdx = 0 }
          else if (c == '\r')
          {
            buf.addChar(c); pos++
            if (pos < src.size && src[pos] == '\n') { buf.addChar(src[pos]); pos++ }
            lineIdx++; colIdx = 0
          }
          else { buf.addChar(c); pos++; colIdx++ }
        }
        tokens.add(Token(TokenKind.strLit, buf.toStr, startLine, startCol))
        continue
      }

      // ---- double-quoted string "..." ----
      if (ch == '"')
      {
        buf := StrBuf()
        buf.addChar(ch); pos++; colIdx++
        while (pos < src.size)
        {
          c := src[pos]
          if (c == '\\' && pos + 1 < src.size)
            { buf.addChar(c); buf.addChar(src[pos+1]); pos += 2; colIdx += 2 }
          else
          {
            buf.addChar(c); pos++; colIdx++
            if (c == '"') break
          }
        }
        tokens.add(Token(TokenKind.strLit, buf.toStr, startLine, startCol))
        continue
      }

      // ---- single-quoted char literal '.' ----
      if (ch == '\'')
      {
        buf := StrBuf()
        buf.addChar(ch); pos++; colIdx++
        while (pos < src.size)
        {
          c := src[pos]
          if (c == '\\' && pos + 1 < src.size)
            { buf.addChar(c); buf.addChar(src[pos+1]); pos += 2; colIdx += 2 }
          else
          {
            buf.addChar(c); pos++; colIdx++
            if (c == '\'') break
          }
        }
        tokens.add(Token(TokenKind.charLit, buf.toStr, startLine, startCol))
        continue
      }

      // ---- backtick DSL string `...` ----
      if (ch == '`')
      {
        buf := StrBuf()
        buf.addChar(ch); pos++; colIdx++
        while (pos < src.size)
        {
          c := src[pos]
          buf.addChar(c); pos++; colIdx++
          if (c == '`') break
        }
        tokens.add(Token(TokenKind.dslLit, buf.toStr, startLine, startCol))
        continue
      }

      // ---- whitespace (spaces / tabs) ----
      if (ch == ' ' || ch == '\t')
      {
        buf := StrBuf()
        while (pos < src.size && (src[pos] == ' ' || src[pos] == '\t'))
          { buf.addChar(src[pos]); pos++; colIdx++ }
        tokens.add(Token(TokenKind.whitespace, buf.toStr, startLine, startCol))
        continue
      }

      // ---- identifier ----
      if (ch.isAlpha || ch == '_')
      {
        buf := StrBuf()
        while (pos < src.size && (src[pos].isAlphaNum || src[pos] == '_'))
          { buf.addChar(src[pos]); pos++; colIdx++ }
        tokens.add(Token(TokenKind.identifier, buf.toStr, startLine, startCol))
        continue
      }

      // ---- punctuation / everything else ----
      tokens.add(Token(TokenKind.punct, ch.toChar.toStr, startLine, startCol))
      pos++; colIdx++
    }

    return tokens
  }

  private Int? _peek(Int offset) { (pos + offset) < src.size ? src[pos + offset] : null }
}
