**
** FantomLexerTest — unit tests for FantomScanner, SourceWalker, and FantomLexer.
**
class FantomLexerTest : Test
{

//////////////////////////////////////////////////////////////////////////
// FantomScanner — basic advancement
//////////////////////////////////////////////////////////////////////////

  Void testScannerAdvanceReturnsChars()
  {
    s := FantomScanner("abc")
    verifyEq(s.advance, 'a')
    verifyEq(s.advance, 'b')
    verifyEq(s.advance, 'c')
    verifyNull(s.advance)
    verify(s.isDone)
  }

  Void testScannerCurrentAndPeek()
  {
    s := FantomScanner("xyz")
    verifyEq(s.current, 'x')
    verifyEq(s.peek, 'y')
    verifyEq(s.peek(2), 'z')
    verifyNull(s.peek(3))
  }

  Void testScannerEmptyLine()
  {
    s := FantomScanner("")
    verify(s.isDone)
    verifyNull(s.advance)
    verifyNull(s.current)
  }

//////////////////////////////////////////////////////////////////////////
// FantomScanner — double-quoted string context
//////////////////////////////////////////////////////////////////////////

  Void testScannerInsideDoubleQuotedString()
  {
    // x "hello" y  — chars inside quotes are inStr
    s := FantomScanner("x \"hello\" y")
    verifyEq(s.advance, 'x')
    verify(!s.isInLiteral)
    s.advance // space
    s.advance // opening "
    verify(s.inStr)
    verify(s.isInLiteral)
    s.advance // h
    verify(s.inStr)
    // Skip to end of literal
    s.skipToEndOfLiteral
    verify(!s.isInLiteral)
    verifyEq(s.current, ' ')
  }

  Void testScannerEscapeInsideString()
  {
    // "a\"b" — escaped quote does not close string
    s := FantomScanner("\"a\\\"b\"")
    s.advance // opening "
    verify(s.inStr)
    s.advance // a
    s.advance // backslash
    verify(s.escaped)
    s.advance // escaped " — should NOT close string
    verify(s.inStr)
    s.advance // b
    s.advance // closing "
    verify(!s.inStr)
    verify(s.isDone)
  }

//////////////////////////////////////////////////////////////////////////
// FantomScanner — triple-quoted string
//////////////////////////////////////////////////////////////////////////

  Void testScannerTripleQuotedStringOpens()
  {
    // """hello""" — first advance opens triple; pos skips atomically past """
    s := FantomScanner("\"\"\"hello\"\"\"")
    s.advance
    verify(s.inTriple)
    verify(!s.inStr)
  }

  Void testScannerTripleQuotedStringSkip()
  {
    // After opening, skipToEndOfLiteral exits triple context and exhausts line
    s := FantomScanner("\"\"\"hello\"\"\"")
    s.advance // open triple
    s.skipToEndOfLiteral
    verify(!s.inTriple)
    verify(s.isDone)
  }

//////////////////////////////////////////////////////////////////////////
// FantomScanner — single-quoted char literal
//////////////////////////////////////////////////////////////////////////

  Void testScannerCharLiteral()
  {
    s := FantomScanner("','")
    s.advance // opening '
    verify(s.inChar)
    s.advance // ,
    verify(s.inChar)
    s.advance // closing '
    verify(!s.inChar)
    verify(s.isDone)
  }

  Void testScannerEscapedCharLiteral()
  {
    s := FantomScanner("'\\n'")
    s.advance // opening '
    verify(s.inChar)
    s.advance // backslash
    verify(s.escaped)
    s.advance // n — escape target, should NOT close char literal
    verify(s.inChar)
    s.advance // closing '
    verify(!s.inChar)
    verify(s.isDone)
  }

  Void testScannerPipeInCharLiteralIsNotClosureMarker()
  {
    // '|' — pipe inside char literal must not be treated as closure
    s := FantomScanner("'|'")
    s.advance // opening '
    verify(s.inChar)
    s.advance // |
    verify(s.inChar) // still inside char literal
    s.advance // closing '
    verify(!s.inChar)
    verify(s.isDone)
  }

//////////////////////////////////////////////////////////////////////////
// FantomScanner — backtick DSL
//////////////////////////////////////////////////////////////////////////

  Void testScannerDslString()
  {
    s := FantomScanner("`/foo/bar`")
    s.advance // `
    verify(s.inDsl)
    s.skipToEndOfLiteral
    verify(!s.inDsl)
    verify(s.isDone)
  }

//////////////////////////////////////////////////////////////////////////
// FantomScanner — line comment
//////////////////////////////////////////////////////////////////////////

  Void testScannerLineComment()
  {
    s := FantomScanner("x // comment")
    s.advance // x
    verify(!s.isInLiteral)
    s.advance // space
    s.advance // first /  — triggers comment, jumps to end
    verify(s.isDone)
  }

  Void testScannerLineCommentAfterCode()
  {
    // Collect only bare-code chars (not in any literal)
    s := FantomScanner("a+b // ignore")
    code := StrBuf()
    while (!s.isDone)
    {
      col := s.pos
      ch := s.advance
      if (ch != null && !s.isInLiteral) code.addChar(ch)
    }
    // "a+b " then comment consumed to end; the space before // is bare code
    verify(code.toStr.startsWith("a+b"))
  }

//////////////////////////////////////////////////////////////////////////
// FantomScanner — block comment (single line)
//////////////////////////////////////////////////////////////////////////

  Void testScannerBlockCommentSingleLine()
  {
    s := FantomScanner("a /* mid */ b")
    s.advance // a
    verify(!s.isInLiteral)
    s.advance // space
    s.advance // / — opens block comment
    verify(s.inBlock)
    s.skipToEndOfLiteral
    verify(!s.inBlock)
    // remaining: " b"
    verifyEq(s.current, ' ')
  }

  Void testScannerBlockCommentWithCommaInside()
  {
    // /* trim */ should be entirely opaque — the comma inside does not count as arg sep
    s := FantomScanner("f(a, /* skip, this */ b)")
    code := StrBuf()
    while (!s.isDone)
    {
      col := s.pos
      ch := s.advance
      if (ch != null && !s.isInLiteral) code.addChar(ch)
    }
    // Only real commas are 'a,' and 'b'  — inside block comment is hidden
    verify(!code.toStr.contains("skip"))
  }

//////////////////////////////////////////////////////////////////////////
// FantomScanner — cross-line block comment via makeWithState
//////////////////////////////////////////////////////////////////////////

  Void testScannerCrossLineBlockCommentSeeded()
  {
    // Line 2 starts inside a block comment from line 1
    s := FantomScanner.makeWithState("still in comment */ x", true)
    verify(s.inBlock)
    s.skipToEndOfLiteral
    verify(!s.inBlock)
    verifyEq(s.current, ' ')
    s.advance // space
    verifyEq(s.current, 'x')
  }

//////////////////////////////////////////////////////////////////////////
// FantomScanner — skipUntil
//////////////////////////////////////////////////////////////////////////

  Void testScannerSkipUntilComma()
  {
    s := FantomScanner("foo,bar")
    s.skipUntil |ch| { ch == ',' }
    verifyEq(s.current, ',')
    verifyEq(s.pos, 3)
  }

  Void testScannerSkipUntilIgnoresCommaInString()
  {
    s := FantomScanner("\"a,b\",c")
    // Skip until bare comma — must not stop inside the string
    s.skipUntil |ch| { ch == ',' && !s.isInLiteral }
    verifyEq(s.current, ',')
    verifyEq(s.pos, 5) // position of the comma after the closing "
  }

//////////////////////////////////////////////////////////////////////////
// SourceWalker — manual iteration
//////////////////////////////////////////////////////////////////////////

  Void testSourceWalkerNextLine()
  {
    w := SourceWalker("line0\nline1\nline2")
    verify(!w.isDone)
    s0 := w.nextLine
    verifyNotNull(s0)
    verifyEq(s0.line, "line0")
    verifyEq(w.lineIdx, 1)
    s1 := w.nextLine
    verifyEq(s1.line, "line1")
    s2 := w.nextLine
    verifyEq(s2.line, "line2")
    verify(w.isDone)
    verifyNull(w.nextLine)
  }

  Void testSourceWalkerCrlfLines()
  {
    // CRLF line endings — Fantom splitLines handles \r\n as one separator
    w := SourceWalker("line0\r\nline1\r\nline2")
    lines := Str[,]
    while (!w.isDone)
    {
      s := w.nextLine
      if (s != null) lines.add(s.line)
    }
    verifyEq(lines.size, 3)
    verifyEq(lines[0], "line0")
    verifyEq(lines[1], "line1")
    verifyEq(lines[2], "line2")
  }

  Void testSourceWalkerBlockCommentCarriedAcrossLines()
  {
    src := "x /* open\nstill inside\nclosed */ y"
    w := SourceWalker(src)

    // Line 0: scanner should open block comment partway through
    s0 := w.nextLine
    verifyNotNull(s0)
    while (!s0.isDone) s0.advance
    verify(s0.inBlock) // ended still inside block comment

    // Line 1: seeded with inBlock = true
    s1 := w.nextLine
    verifyNotNull(s1)
    verify(s1.inBlock)
    while (!s1.isDone) s1.advance
    verify(s1.inBlock) // still not closed

    // Line 2: block comment closes mid-line
    s2 := w.nextLine
    verifyNotNull(s2)
    verify(s2.inBlock)
    s2.skipToEndOfLiteral
    verify(!s2.inBlock)
  }

//////////////////////////////////////////////////////////////////////////
// SourceWalker — callback style
//////////////////////////////////////////////////////////////////////////

  Void testSourceWalkerWalkLines()
  {
    src := "aa\nbb\ncc"
    w := SourceWalker(src)
    visited := Int[,]
    w.walkLines |li, s| { visited.add(li) }
    verifyEq(visited, [0, 1, 2])
  }

  Void testSourceWalkerWalkCharsCollectsCodeOnly()
  {
    src := "a \"str\" b"
    w := SourceWalker(src)
    code := StrBuf()
    w.walkChars |li, col, ch, s|
    {
      if (!s.isInLiteral) code.addChar(ch)
    }
    // 'a', ' ', '"' (opening quote advances into inStr), ' ', 'b'
    // After advance(), state reflects consuming that char.
    // Opening " sets inStr=true, so the " itself is reported as NOT in literal
    // (state updates after the char is returned). We only care that string
    // interior chars ('s','t','r') are hidden.
    verify(!code.toStr.contains("str"))
    verify(code.toStr.contains("a"))
    verify(code.toStr.contains("b"))
  }

//////////////////////////////////////////////////////////////////////////
// FantomLexer — basic tokenization
//////////////////////////////////////////////////////////////////////////

  Void testLexerEmptySource()
  {
    tokens := FantomLexer.tokenize("")
    verifyEq(tokens.size, 0)
  }

  Void testLexerIdentifier()
  {
    tokens := FantomLexer.tokenize("hello")
    verifyEq(tokens.size, 1)
    verifyEq(tokens[0].kind, TokenKind.identifier)
    verifyEq(tokens[0].text, "hello")
    verifyEq(tokens[0].line, 0)
    verifyEq(tokens[0].col, 0)
  }

  Void testLexerIdentifierWithUnderscore()
  {
    tokens := FantomLexer.tokenize("_myVar42")
    verifyEq(tokens.size, 1)
    verifyEq(tokens[0].kind, TokenKind.identifier)
    verifyEq(tokens[0].text, "_myVar42")
  }

  Void testLexerPunct()
  {
    tokens := FantomLexer.tokenize("()")
    verifyEq(tokens.size, 2)
    verifyEq(tokens[0].kind, TokenKind.punct)
    verifyEq(tokens[0].text, "(")
    verifyEq(tokens[1].kind, TokenKind.punct)
    verifyEq(tokens[1].text, ")")
  }

  Void testLexerWhitespace()
  {
    tokens := FantomLexer.tokenize("a b")
    verifyEq(tokens.size, 3)
    verifyEq(tokens[1].kind, TokenKind.whitespace)
    verifyEq(tokens[1].text, " ")
  }

//////////////////////////////////////////////////////////////////////////
// FantomLexer — string literals
//////////////////////////////////////////////////////////////////////////

  Void testLexerDoubleQuotedString()
  {
    tokens := FantomLexer.tokenize("\"hello\"")
    verifyEq(tokens.size, 1)
    verifyEq(tokens[0].kind, TokenKind.strLit)
    verifyEq(tokens[0].text, "\"hello\"")
  }

  Void testLexerDoubleQuotedStringWithEscape()
  {
    tokens := FantomLexer.tokenize("\"a\\\"b\"")
    verifyEq(tokens.size, 1)
    verifyEq(tokens[0].kind, TokenKind.strLit)
    verifyEq(tokens[0].text, "\"a\\\"b\"")
  }

  Void testLexerTripleQuotedString()
  {
    tokens := FantomLexer.tokenize("\"\"\"hi\"\"\"")
    verifyEq(tokens.size, 1)
    verifyEq(tokens[0].kind, TokenKind.strLit)
    verifyEq(tokens[0].text, "\"\"\"hi\"\"\"")
  }

  Void testLexerCharLiteral()
  {
    tokens := FantomLexer.tokenize("','")
    verifyEq(tokens.size, 1)
    verifyEq(tokens[0].kind, TokenKind.charLit)
    verifyEq(tokens[0].text, "','")
  }

  Void testLexerEscapedCharLiteral()
  {
    tokens := FantomLexer.tokenize("'\\n'")
    verifyEq(tokens.size, 1)
    verifyEq(tokens[0].kind, TokenKind.charLit)
    verifyEq(tokens[0].text, "'\\n'")
  }

  Void testLexerPipeCharLiteralIsSingleToken()
  {
    // '|' must be a charLit, not split into punct tokens
    tokens := FantomLexer.tokenize("'|'")
    verifyEq(tokens.size, 1)
    verifyEq(tokens[0].kind, TokenKind.charLit)
    verifyEq(tokens[0].text, "'|'")
  }

  Void testLexerDslString()
  {
    tokens := FantomLexer.tokenize("`/path/to`")
    verifyEq(tokens.size, 1)
    verifyEq(tokens[0].kind, TokenKind.dslLit)
    verifyEq(tokens[0].text, "`/path/to`")
  }

//////////////////////////////////////////////////////////////////////////
// FantomLexer — comments
//////////////////////////////////////////////////////////////////////////

  Void testLexerLineComment()
  {
    tokens := FantomLexer.tokenize("x // note")
    kinds := tokens.map |t| { t.kind }
    verify(kinds.contains(TokenKind.lineComment))
    lc := tokens.find |t| { t.kind == TokenKind.lineComment }
    verifyEq(lc.text, "// note")
  }

  Void testLexerBlockCommentSingleLine()
  {
    tokens := FantomLexer.tokenize("a /* mid */ b")
    bc := tokens.find |t| { t.kind == TokenKind.blockComment }
    verifyNotNull(bc)
    verifyEq(bc.text, "/* mid */")
  }

  Void testLexerBlockCommentWithCommaIsOneToken()
  {
    tokens := FantomLexer.tokenize("f(a, /* skip, this */ b)")
    bc := tokens.find |t| { t.kind == TokenKind.blockComment }
    verifyNotNull(bc)
    verifyEq(bc.text, "/* skip, this */")
  }

//////////////////////////////////////////////////////////////////////////
// FantomLexer — line / column tracking
//////////////////////////////////////////////////////////////////////////

  Void testLexerLineColumnTracking()
  {
    tokens := FantomLexer.tokenize("ab\ncd")
    // "ab" at line 0 col 0
    ab := tokens.find |t| { t.text == "ab" }
    verifyNotNull(ab)
    verifyEq(ab.line, 0)
    verifyEq(ab.col, 0)
    // "cd" at line 1 col 0
    cd := tokens.find |t| { t.text == "cd" }
    verifyNotNull(cd)
    verifyEq(cd.line, 1)
    verifyEq(cd.col, 0)
  }

  Void testLexerColumnOffsetOnLine()
  {
    tokens := FantomLexer.tokenize("  foo")
    ws := tokens[0]
    verifyEq(ws.kind, TokenKind.whitespace)
    verifyEq(ws.col, 0)
    id := tokens[1]
    verifyEq(id.kind, TokenKind.identifier)
    verifyEq(id.col, 2)
  }

  Void testLexerCrlfLineEnding()
  {
    // CRLF should advance line counter once and reset col
    tokens := FantomLexer.tokenize("a\r\nb")
    a := tokens.find |t| { t.text == "a" }
    b := tokens.find |t| { t.text == "b" }
    verifyNotNull(a); verifyNotNull(b)
    verifyEq(a.line, 0)
    verifyEq(b.line, 1)
    verifyEq(b.col, 0)
  }

  Void testLexerCrOnlyLineEnding()
  {
    // Bare \r (classic Mac) should also advance line counter
    tokens := FantomLexer.tokenize("a\rb")
    a := tokens.find |t| { t.text == "a" }
    b := tokens.find |t| { t.text == "b" }
    verifyNotNull(a); verifyNotNull(b)
    verifyEq(a.line, 0)
    verifyEq(b.line, 1)
    verifyEq(b.col, 0)
  }

  Void testLexerBlockCommentSpanningLines()
  {
    src := "a\n/* open\nclose */ b"
    tokens := FantomLexer.tokenize(src)
    bc := tokens.find |t| { t.kind == TokenKind.blockComment }
    verifyNotNull(bc)
    // Block comment starts on line 1
    verifyEq(bc.line, 1)
    verifyEq(bc.col, 0)
    // "b" should be on line 2
    b := tokens.findAll |t| { t.kind == TokenKind.identifier }.find |t| { t.text == "b" }
    verifyNotNull(b)
    verifyEq(b.line, 2)
  }

  Void testLexerTripleQuotedSpanningLines()
  {
    src := "\"\"\"line0\nline1\"\"\""
    tokens := FantomLexer.tokenize(src)
    verifyEq(tokens.size, 1)
    verifyEq(tokens[0].kind, TokenKind.strLit)
    verify(tokens[0].text.contains("line0"))
    verify(tokens[0].text.contains("line1"))
  }

//////////////////////////////////////////////////////////////////////////
// FantomLexer — coverage completeness (no gaps)
//////////////////////////////////////////////////////////////////////////

  Void testLexerCoversAllChars()
  {
    src := "class Foo { Str x := \"hi\" }"
    tokens := FantomLexer.tokenize(src)
    // Reconstruct source from tokens — must equal original
    rebuilt := tokens.reduce("") |Str acc, Token t -> Str| { acc + t.text }
    verifyEq(rebuilt, src)
  }

  Void testLexerCoversAllCharsMultiLine()
  {
    src := "a := 1\nb := \"x\"\n// comment\nc := 'd'"
    tokens := FantomLexer.tokenize(src)
    rebuilt := tokens.reduce("") |Str acc, Token t -> Str| { acc + t.text }
    verifyEq(rebuilt, src)
  }

  Void testLexerCrlfSourceReconstructed()
  {
    // Tokenize CRLF source and rebuild — must match exactly
    src := "x := 1\r\ny := 2\r\n"
    tokens := FantomLexer.tokenize(src)
    rebuilt := tokens.reduce("") |Str acc, Token t -> Str| { acc + t.text }
    verifyEq(rebuilt, src)
  }

//////////////////////////////////////////////////////////////////////////
// FantomLexer — mixed real-world snippet
//////////////////////////////////////////////////////////////////////////

  Void testLexerRealWorldSnippet()
  {
    src := "appAccess.split(',', /* trim */ true)"
    tokens := FantomLexer.tokenize(src)
    kinds := tokens.map |t| { t.kind }

    // Must contain identifier, charLit, blockComment, identifier
    verify(kinds.contains(TokenKind.identifier))
    verify(kinds.contains(TokenKind.charLit))
    verify(kinds.contains(TokenKind.blockComment))

    // The ',' must be charLit, not two punct tokens
    charToks := tokens.findAll |t| { t.kind == TokenKind.charLit }
    verifyEq(charToks.size, 1)
    verifyEq(charToks[0].text, "','")

    // The block comment must be a single token
    bcToks := tokens.findAll |t| { t.kind == TokenKind.blockComment }
    verifyEq(bcToks.size, 1)
    verifyEq(bcToks[0].text, "/* trim */")

    // Reconstruct must equal source
    rebuilt := tokens.reduce("") |Str acc, Token t -> Str| { acc + t.text }
    verifyEq(rebuilt, src)
  }
}
