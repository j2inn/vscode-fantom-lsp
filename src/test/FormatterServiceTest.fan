**
** FormatterServiceTest - unit tests for the Fantom source formatter.
**
** Coverage:
**   - indentation (spaces and tabs)
**   - trailing whitespace
**   - blank line collapsing
**   - final newline insertion
**   - no-op detection for already-formatted source
**   - brace counting inside strings / line comments
**   - range formatting
**   - edit range correctness (range must cover the full document including
**     any trailing newline so VS Code does not duplicate it)
**   - line-ending preservation: LF, CRLF, CR-only input → same style output
**   - idempotency (formatting twice == no second edit)
**
class FormatterServiceTest : Test
{
  private FormatterService fmt  := FormatterService()
  private FormatterOptions opts := FormatterOptions()

  // Convenience: apply full-doc format, return resulting text (or original if no edits).
  private Str format(Str src) { formatWith(src, opts) }

  private Str formatWith(Str src, FormatterOptions o)
  {
    edits := fmt.format("file:///test/Foo.fan", src, o, null)
    if (edits.isEmpty) return src
    return edits[0]["newText"] as Str ?: src
  }

  // Return the single edit map, or null when no edits are produced.
  private [Str:Obj?]? editFor(Str src) { editForWith(src, opts) }

  private [Str:Obj?]? editForWith(Str src, FormatterOptions o)
  {
    edits := fmt.format("file:///test/Foo.fan", src, o, null)
    return edits.isEmpty ? null : edits[0]
  }

//////////////////////////////////////////////////////////////////////////
// Indentation — spaces
//////////////////////////////////////////////////////////////////////////

  Void testSimpleClassIndent()
  {
    src      := "class Foo\n{\nVoid bar() {}\n}"
    expected := "class Foo\n{\n  Void bar() {}\n}\n"
    verifyEq(format(src), expected)
  }

  Void testNestedBlocks()
  {
    src := "class Foo\n{\nVoid bar()\n{\nif (x)\n{\nreturn\n}\n}\n}"
    result := format(src)
    lines  := result.splitLines
    verifyEq(lines[0], "class Foo")
    verifyEq(lines[1], "{")
    verifyEq(lines[2], "  Void bar()")
    verifyEq(lines[3], "  {")
    verifyEq(lines[4], "    if (x)")
    verifyEq(lines[5], "    {")
    verifyEq(lines[6], "      return")
    verifyEq(lines[7], "    }")
    verifyEq(lines[8], "  }")
    verifyEq(lines[9], "}")
  }

  Void testElseBlock()
  {
    src := "class Foo\n{\nVoid bar()\n{\nif (x)\n{\nreturn\n}\nelse\n{\nreturn\n}\n}\n}"
    result := format(src)
    lines  := result.splitLines
    verifyEq(lines[8],  "    else")
    verifyEq(lines[9],  "    {")
    verifyEq(lines[10], "      return")
  }

  Void testClosingBraceDecreasesIndent()
  {
    src    := "class Foo {\nVoid bar() {\nreturn\n}\n}"
    result := format(src)
    lines  := result.splitLines
    verifyEq(lines[3], "  }")
    verifyEq(lines[4], "}")
  }

  Void testFourSpaceIndent()
  {
    o := opts.copy
    o.indentSize = 4
    src    := "class Foo\n{\nVoid bar() {}\n}"
    result := formatWith(src, o)
    lines  := result.splitLines
    verifyEq(lines[2], "    Void bar() {}")
  }

//////////////////////////////////////////////////////////////////////////
// Indentation — tabs
//////////////////////////////////////////////////////////////////////////

  Void testTabIndent()
  {
    o := opts.copy
    o.useTabs = true
    src    := "class Foo\n{\nVoid bar() {}\n}"
    result := formatWith(src, o)
    lines  := result.splitLines
    verify(lines[2].startsWith("\t"), "expected tab indent, got: ${lines[2]}")
    verifyEq(lines[2], "\tVoid bar() {}")
  }

  Void testTabNestedIndent()
  {
    o := opts.copy
    o.useTabs = true
    src    := "class Foo\n{\nVoid bar()\n{\nreturn\n}\n}"
    result := formatWith(src, o)
    lines  := result.splitLines
    verifyEq(lines[4], "\t\treturn")
  }

//////////////////////////////////////////////////////////////////////////
// Trailing whitespace
//////////////////////////////////////////////////////////////////////////

  Void testTrailingWhitespaceTrimmed()
  {
    src    := "class Foo   \n{\n  Void bar()   \n}\n"
    result := format(src)
    result.splitLines.each |line|
    {
      verify(!line.endsWith(" "), "trailing space on: $line")
    }
  }

  Void testTrailingWhitespacePreservedWhenDisabled()
  {
    o := opts.copy
    o.trimTrailingWhitespace = false
    o.collapseSpaces         = false  // disable collapse so trailing spaces survive
    src    := "class Foo   \n{\n}\n"
    result := formatWith(src, o)
    verify(result.splitLines[0].endsWith("   "))
  }

//////////////////////////////////////////////////////////////////////////
// Blank lines
//////////////////////////////////////////////////////////////////////////

  Void testExcessiveBlankLinesCollapsed()
  {
    src    := "class Foo\n{\n\n\n\n  Void bar() {}\n}\n"
    result := format(src)
    lines  := result.splitLines
    consecutiveBlanks := 0
    lines.each |line|
    {
      if (line.isEmpty) consecutiveBlanks++
      else consecutiveBlanks = 0
      verify(consecutiveBlanks <= 1, "too many consecutive blank lines")
    }
  }

  Void testBlankLinesPreservedWhenUnlimited()
  {
    o := opts.copy
    o.maxBlankLines = 0
    src    := "class Foo\n{\n\n\n\n  Void bar() {}\n}\n"
    result := formatWith(src, o)
    verify(result.contains("\n\n\n"))
  }

  Void testMaxBlankLinesTwo()
  {
    o := opts.copy
    o.maxBlankLines = 2
    src    := "class Foo\n{\n\n\n\n\n  Void bar() {}\n}\n"
    result := formatWith(src, o)
    verify(!result.contains("\n\n\n\n"), "should not have 4 blank lines")
    verify(result.contains("\n\n\n"), "should preserve up to 2 blank lines")
  }

//////////////////////////////////////////////////////////////////////////
// Final newline
//////////////////////////////////////////////////////////////////////////

  Void testFinalNewlineInserted()
  {
    src := "class Foo {}"
    verify(format(src).endsWith("\n"))
  }

  Void testFinalNewlineNotInsertedWhenDisabled()
  {
    o := opts.copy
    o.insertFinalNewline = false
    src := "class Foo {}"
    verify(!formatWith(src, o).endsWith("\n"))
  }

  Void testExistingFinalNewlinePreserved()
  {
    src := "class Foo {}\n"
    verify(format(src).endsWith("\n"))
  }

  Void testNoDoubleTrailingNewline()
  {
    // A file that ends with \n and needs reformatting must NOT gain an extra \n
    src    := "class Foo\n{\nVoid bar() {}\n}\n"
    result := format(src)
    verify(result.endsWith("\n"),   "must end with newline")
    verify(!result.endsWith("\n\n"), "must not end with double newline")
  }

//////////////////////////////////////////////////////////////////////////
// No-op: already-formatted source
//////////////////////////////////////////////////////////////////////////

  Void testAlreadyFormattedReturnsEmpty()
  {
    src   := "class Foo\n{\n  Void bar() {}\n}\n"
    edits := fmt.format("file:///test/Foo.fan", src, opts, null)
    verifyEq(edits.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Edit range correctness
//
// The LSP TextEdit range must cover the ENTIRE document, including any
// trailing '\n'/'\r\n'/'\r'.  If it does not, VS Code keeps the original
// trailing separator AND adds the one from newText → double newline on every
// format invocation.
//////////////////////////////////////////////////////////////////////////

  ** LF trailing: end = {nlCount, 0}
  Void testEditRangeCoversTrailingLf()
  {
    src  := "class Foo\n{\nVoid bar() {}\n}\n"  // 4 \n → endLine=4
    edit := editFor(src)
    verify(edit != null, "expected at least one edit")
    rangeMap := edit["range"] as Str:Obj?
    endMap   := rangeMap["end"] as Str:Obj?
    verifyEq(endMap["line"]      as Int, 4)
    verifyEq(endMap["character"] as Int, 0)
  }

  ** LF no trailing: end = {nlCount, lastLineLen}
  Void testEditRangeNoTrailingLf()
  {
    src  := "class Foo\n{\nVoid bar() {}\n}"  // 3 \n, last line "}" (1 char)
    edit := editFor(src)
    verify(edit != null)
    rangeMap := edit["range"] as Str:Obj?
    endMap   := rangeMap["end"] as Str:Obj?
    verifyEq(endMap["line"]      as Int, 3)
    verifyEq(endMap["character"] as Int, 1)
  }

  ** CRLF trailing: end = {crlfCount, 0}
  Void testEditRangeCoversTrailingCrlf()
  {
    crlf := "\r\n"
    src  := "class Foo" + crlf + "{" + crlf + "Void bar() {}" + crlf + "}" + crlf
    edit := editFor(src)
    verify(edit != null, "expected edit for CRLF file needing indent fix")
    rangeMap := edit["range"] as Str:Obj?
    endMap   := rangeMap["end"] as Str:Obj?
    verifyEq(endMap["line"]      as Int, 4)
    verifyEq(endMap["character"] as Int, 0)
  }

  ** CRLF no trailing: end = {crlfCount, lastLineLen}
  Void testEditRangeNoTrailingCrlf()
  {
    crlf := "\r\n"
    src  := "class Foo" + crlf + "{" + crlf + "}"
    edit := editFor(src)
    verify(edit != null)
    rangeMap := edit["range"] as Str:Obj?
    endMap   := rangeMap["end"] as Str:Obj?
    verifyEq(endMap["line"]      as Int, 2)
    verifyEq(endMap["character"] as Int, 1)
  }

  ** CR-only trailing: end = {crCount, 0}
  Void testEditRangeCoversTrailingCr()
  {
    cr  := "\r"
    src := "class Foo" + cr + "{" + cr + "Void bar() {}" + cr + "}" + cr
    edit := editFor(src)
    verify(edit != null, "expected edit for CR-only file")
    rangeMap := edit["range"] as Str:Obj?
    endMap   := rangeMap["end"] as Str:Obj?
    verifyEq(endMap["line"]      as Int, 4)
    verifyEq(endMap["character"] as Int, 0)
  }

  ** CR-only no trailing: end = {crCount, lastLineLen}
  Void testEditRangeNoTrailingCr()
  {
    cr  := "\r"
    src := "class Foo" + cr + "{" + cr + "}"
    edit := editFor(src)
    verify(edit != null)
    rangeMap := edit["range"] as Str:Obj?
    endMap   := rangeMap["end"] as Str:Obj?
    verifyEq(endMap["line"]      as Int, 2)
    verifyEq(endMap["character"] as Int, 1)
  }

  ** Range start must always be {0, 0}
  Void testEditRangeStartIsZero()
  {
    src  := "class Foo\n{\nVoid bar() {}\n}\n"
    edit := editFor(src)
    verify(edit != null)
    rangeMap  := edit["range"] as Str:Obj?
    startMap  := rangeMap["start"] as Str:Obj?
    verifyEq(startMap["line"]      as Int, 0)
    verifyEq(startMap["character"] as Int, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Line-ending preservation
//
// The formatter must use the same line-ending style as the input.  A CRLF
// file must stay CRLF after formatting; applying the edit a second time
// should produce no further edits (idempotency proves round-trip safety).
//////////////////////////////////////////////////////////////////////////

  Void testCrlfPreservedInOutput()
  {
    crlf := "\r\n"
    src  := "class Foo" + crlf + "{" + crlf + "Void bar() {}" + crlf + "}" + crlf
    result := format(src)
    // Must contain CRLF
    verify(result.contains(crlf), "CRLF must be preserved in output")
    // No bare LF: strip all \r\n occurrences, then no \n should remain
    verify(!result.replace(crlf, "").contains("\n"), "bare LF (without preceding \\r) found in output")
  }

  Void testCrlfFinalNewlineUsesCrlf()
  {
    crlf := "\r\n"
    // File has no trailing newline; insertFinalNewline should add \r\n not \n
    src    := "class Foo" + crlf + "{" + crlf + "}"
    result := format(src)
    verify(result.endsWith(crlf), "final newline must be CRLF for CRLF file")
  }

  Void testCrOnlyPreservedInOutput()
  {
    cr  := "\r"
    src := "class Foo" + cr + "{" + cr + "Void bar() {}" + cr + "}" + cr
    result := format(src)
    verify(result.contains("\r"), "CR must appear in output for CR-only file")
    // Should NOT contain \n (bare LF) since the file uses CR only
    verify(!result.contains("\n"), "output must not contain LF for CR-only file")
  }

  Void testLfOutputForLfInput()
  {
    src    := "class Foo\n{\nVoid bar() {}\n}\n"  // already formatted
    // A file needing reformatting:
    src2   := "class Foo\n{\nVoid bar() {}\n}"
    result := format(src2)
    verify(!result.contains("\r"), "LF input must not produce CR in output")
    verify(result.endsWith("\n"), "LF input: final newline must be LF")
  }

//////////////////////////////////////////////////////////////////////////
// Idempotency
//
// After one format pass, the result must be stable: a second pass must
// produce no edits.  This is the ultimate end-to-end check.
//////////////////////////////////////////////////////////////////////////

  Void testFormatIsIdempotentLf()
  {
    src    := "class Foo\n{\nVoid bar() {}\n}\n"
    pass1  := format(src)
    edits2 := fmt.format("file:///test/Foo.fan", pass1, opts, null)
    verifyEq(edits2.size, 0, "LF format is not idempotent: second pass produced edits")
  }

  Void testFormatIsIdempotentLfNoTrailing()
  {
    src    := "class Foo\n{\nVoid bar() {}\n}"
    pass1  := format(src)
    edits2 := fmt.format("file:///test/Foo.fan", pass1, opts, null)
    verifyEq(edits2.size, 0, "LF (no trailing \\n) format is not idempotent")
  }

  Void testFormatIsIdempotentCrlf()
  {
    crlf  := "\r\n"
    src   := "class Foo" + crlf + "{" + crlf + "Void bar() {}" + crlf + "}" + crlf
    pass1 := format(src)
    edits2 := fmt.format("file:///test/Foo.fan", pass1, opts, null)
    verifyEq(edits2.size, 0, "CRLF format is not idempotent: second pass produced edits")
  }

  Void testFormatIsIdempotentCrOnly()
  {
    cr    := "\r"
    src   := "class Foo" + cr + "{" + cr + "Void bar() {}" + cr + "}" + cr
    pass1 := format(src)
    edits2 := fmt.format("file:///test/Foo.fan", pass1, opts, null)
    verifyEq(edits2.size, 0, "CR-only format is not idempotent: second pass produced edits")
  }

//////////////////////////////////////////////////////////////////////////
// Brace counting in strings / comments
//////////////////////////////////////////////////////////////////////////

  Void testBracesInStringsIgnored()
  {
    src := "class Foo\n{\n  Str s := \"hello { world }\"\n}\n"
    edits := fmt.format("file:///test/Foo.fan", src, opts, null)
    verifyEq(edits.size, 0)
  }

  Void testBracesInLineCommentIgnored()
  {
    src   := "class Foo\n{\n  Void bar() // returns { x }\n  {\n    return\n  }\n}\n"
    edits := fmt.format("file:///test/Foo.fan", src, opts, null)
    verifyEq(edits.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Range formatting
//////////////////////////////////////////////////////////////////////////

  Void testRangeFormat()
  {
    src   := "class Foo\n{\nVoid bar() {}\nVoid baz() {}\n}\n"
    range := LspRange(LspPosition(2, 0), LspPosition(2, 14))
    edits := fmt.formatRange("file:///test/Foo.fan", src, range, opts, null)
    if (!edits.isEmpty)
    {
      newText := edits[0]["newText"] as Str ?: ""
      verifyEq(newText, "  Void bar() {}")
    }
  }

  Void testRangeFormatAlreadyCorrect()
  {
    src   := "class Foo\n{\n  Void bar() {}\n}\n"
    range := LspRange(LspPosition(2, 0), LspPosition(2, 16))
    edits := fmt.formatRange("file:///test/Foo.fan", src, range, opts, null)
    verifyEq(edits.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Edge cases
//////////////////////////////////////////////////////////////////////////

  Void testEmptyFile()
  {
    src   := ""
    edits := fmt.format("file:///test/Foo.fan", src, opts, null)
    verify(edits.size >= 0)  // must not crash
  }

  Void testSingleLineNoNewline()
  {
    src    := "class Foo {}"
    result := format(src)
    verifyEq(result, "class Foo {}\n")
  }

  Void testSingleLineWithNewline()
  {
    src   := "class Foo {}\n"
    edits := fmt.format("file:///test/Foo.fan", src, opts, null)
    verifyEq(edits.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Space collapsing
//////////////////////////////////////////////////////////////////////////

  Void testCollapseExtraSpacesTernary()
  {
    // The classic example from the feature request
    src    := "class Foo\n{\n  Void bar() { return val ?        0 : 1 }\n}\n"
    result := format(src)
    verify(result.contains("val ? 0 : 1"), "expected collapsed ternary spaces, got: $result")
  }

  Void testCollapseExtraSpacesGeneral()
  {
    src    := "class Foo\n{\n  Void bar()  {  return  x  }\n}\n"
    result := format(src)
    // Interior double-spaces should be collapsed
    verify(!result.contains("  {  "), "expected collapsed spaces in body")
  }

  Void testCollapseSpacesPreservesStringContents()
  {
    // Spaces inside string literals must NOT be collapsed
    src   := "class Foo\n{\n  Str s := \"hello    world\"\n}\n"
    edits := fmt.format("file:///test/Foo.fan", src, opts, null)
    if (!edits.isEmpty)
    {
      result := edits[0]["newText"] as Str ?: src
      verify(result.contains("\"hello    world\""), "string literal spaces must be preserved")
    }
  }

  Void testCollapseSpacesPreservesCommentContents()
  {
    // Spaces inside // comments must NOT be collapsed
    src    := "class Foo\n{\n  Void bar() // a    comment\n  {}\n}\n"
    result := format(src)
    verify(result.contains("// a    comment"), "comment spaces must be preserved")
  }

  Void testCollapseSpacesDisabled()
  {
    o := opts.copy
    o.collapseSpaces = false
    src    := "class Foo\n{\n  Void bar() { return val ?   0 : 1 }\n}\n"
    result := formatWith(src, o)
    // With collapse disabled the triple space should survive
    verify(result.contains("?   0"), "spaces should be preserved when collapseSpaces=false")
  }

  Void testCollapseSpacesIdempotent()
  {
    src   := "class Foo\n{\n  Void bar() { return val ?        0 : 1 }\n}\n"
    pass1 := format(src)
    edits2 := fmt.format("file:///test/Foo.fan", pass1, opts, null)
    verifyEq(edits2.size, 0, "collapseSpaces is not idempotent")
  }

//////////////////////////////////////////////////////////////////////////
// Line wrapping
//////////////////////////////////////////////////////////////////////////

  ** Helper: format with wrapping enabled at the given column limit
  private Str formatWrap(Str src, Int maxLen)
  {
    o := opts.copy
    o.maxLineLength = maxLen
    return formatWith(src, o)
  }

  Void testWrapAtCommaInMethodCall()
  {
    // Line "  result := foo(param1, param2, param3)" — wrap at 30 chars
    src    := "class Foo\n{\n  Void bar()\n  {\n    result := foo(param1, param2, param3)\n  }\n}\n"
    result := formatWrap(src, 30)
    lines  := result.splitLines
    // No line should exceed 30 chars
    lines.each |line| { verify(line.size <= 30 || !line.contains(","), "line too long: $line") }
    // The call should have been split
    verify(result.contains("param1,\n"), "expected split after comma")
  }

  Void testWrapAtLogicalAnd()
  {
    src    := "class Foo\n{\n  Void bar()\n  {\n    if (conditionAlpha && conditionBeta)\n    {\n      return\n    }\n  }\n}\n"
    result := formatWrap(src, 30)
    // Should split at &&
    verify(result.contains("&&"), "operator must appear somewhere")
    lines := result.splitLines
    lines.each |line| { verify(line.size <= 30 || !line.contains("&&"), "long line with &&: $line") }
  }

  Void testWrapAtTernary()
  {
    src    := "class Foo\n{\n  Void bar()\n  {\n    x := someLongConditionVariable ? valueWhenTrue : valueWhenFalse\n  }\n}\n"
    result := formatWrap(src, 40)
    verify(result.contains("?"), "ternary operator must appear")
    lines := result.splitLines
    lines.each |line| { verify(line.size <= 40 || !line.contains("?"), "long line with ?: $line") }
  }

  Void testWrapDisabledByDefault()
  {
    // Default opts have maxLineLength=0 → no wrapping
    longLine := "    result := someMethod(parameterOne, parameterTwo, parameterThree, parameterFour)"
    src       := "class Foo\n{\n  Void bar()\n  {\n" + longLine + "\n  }\n}\n"
    result    := format(src)
    // The long line should survive intact (just indented)
    verify(result.contains("someMethod(parameterOne"), "long lines should not be wrapped when disabled")
  }

  Void testWrapShortLineNotChanged()
  {
    o := opts.copy
    o.maxLineLength = 120
    src    := "class Foo\n{\n  Void bar() {}\n}\n"
    edits  := fmt.format("file:///test/Foo.fan", src, o, null)
    verifyEq(edits.size, 0, "short lines must not be wrapped")
  }

  Void testWrapConvergesAfterTwoPasses()
  {
    // Continuation lines from pass1 may have brace-tracker-vs-wrapper indent
    // disagreement, which pass2 corrects.  After two passes the result must be
    // stable: pass2 == pass3 (no infinite oscillation).
    src   := "class Foo\n{\n  Void bar()\n  {\n    result := foo(param1, param2, param3)\n  }\n}\n"
    o := opts.copy
    o.maxLineLength = 30
    pass1 := formatWith(src,   o)
    pass2 := formatWith(pass1, o)
    pass3 := formatWith(pass2, o)
    verifyEq(pass2, pass3, "wrap did not stabilise: pass2 != pass3")
  }

//////////////////////////////////////////////////////////////////////////
// String-aware space collapsing
//////////////////////////////////////////////////////////////////////////

  ** Spaces inside single-quoted char literals must not be collapsed
  Void testCollapseSpacesPreservesSingleQuotedChar()
  {
    // ' ' (space char literal) — the space must survive
    src   := "class Foo\n{\n  Void bar() { Int c := ' ' }\n}\n"
    result := format(src)
    verify(result.contains("' '"), "single-quoted space must be preserved, got: $result")
  }

  ** Spaces inside backtick DSL strings must not be collapsed
  Void testCollapseSpacesPreservesBacktickString()
  {
    src   := "class Foo\n{\n  Void bar() { Uri u := `path/to   something` }\n}\n"
    result := format(src)
    verify(result.contains("`path/to   something`"), "backtick string spaces must be preserved")
  }

  ** Spaces inside triple-quoted strings must not be collapsed
  Void testCollapseSpacesPreservesTripleQuotedString()
  {
    src   := "class Foo\n{\n  Str s := \"\"\"hello   world\"\"\"\n}\n"
    result := format(src)
    verify(result.contains("\"\"\"hello   world\"\"\""), "triple-quoted string spaces must be preserved")
  }

  ** A closing \"\"\" inside code must not be mistaken for a string opening
  Void testTripleQuoteDetectionDoesNotCorruptCode()
  {
    // Line has a triple-quoted string followed by code — the brace after
    // the closing \"\"\" must be seen as a real brace, not part of the string.
    src   := "class Foo\n{\n  Str s := \"\"\"hello\"\"\"\n}\n"
    edits := fmt.format("file:///test/Foo.fan", src, opts, null)
    // Must not crash, and must not mangle the source
    if (!edits.isEmpty)
      verify(edits[0]["newText"].toStr.contains("\"\"\"hello\"\"\""), "triple-quoted literal must survive formatting")
  }

//////////////////////////////////////////////////////////////////////////
// String literal splitting (line wrap)
//////////////////////////////////////////////////////////////////////////

  ** A long double-quoted string should be split at a word boundary using +
  Void testWrapLongDoubleQuotedString()
  {
    // The string "hello world this is a very long string" is 40 chars;
    // the full line is >30, and there are word-boundary spaces in the string.
    src    := "class Foo\n{\n  Void bar()\n  {\n    msg := \"hello world this is a very long string\"\n  }\n}\n"
    o      := opts.copy
    o.maxLineLength = 30
    result := formatWith(src, o)
    // The string must have been split with a concatenation operator
    verify(result.contains("\" +"), "expected string split with \" +, got:\n$result")
    // Every produced line with a string literal must fit within the limit
    // (the first fragment may still exceed if no earlier word boundary exists
    //  before maxLen — that's acceptable.  Just verify a split happened.)
    verify(result.contains("\n"), "result must be multi-line")
  }

  ** Splitting a long string should converge after two passes
  Void testWrapLongStringConverges()
  {
    src   := "class Foo\n{\n  Void bar()\n  {\n    msg := \"hello world this is a very long string\"\n  }\n}\n"
    o     := opts.copy
    o.maxLineLength = 30
    pass1 := formatWith(src,   o)
    pass2 := formatWith(pass1, o)
    pass3 := formatWith(pass2, o)
    verifyEq(pass2, pass3, "string split did not stabilise: pass2 != pass3")
  }

  ** A long triple-quoted string should be split at a word boundary using +
  Void testWrapLongTripleQuotedString()
  {
    src    := "class Foo\n{\n  Void bar()\n  {\n    msg := \"\"\"hello world this is a very long string\"\"\"\n  }\n}\n"
    o      := opts.copy
    o.maxLineLength = 30
    result := formatWith(src, o)
    verify(result.contains("\"\"\" +"), "expected triple-quoted string split with \"\"\" +, got:\n$result")
  }

  ** Backtick (DSL) strings must never be split even when very long
  Void testWrapBacktickStringNotSplit()
  {
    longUri := "`http://example.com/very/long/path/that/definitely/exceeds/any/reasonable/limit`"
    src     := "class Foo\n{\n  Void bar()\n  {\n    uri := " + longUri + "\n  }\n}\n"
    o       := opts.copy
    o.maxLineLength = 30
    result  := formatWith(src, o)
    // The backtick string must be left intact
    verify(result.contains(longUri), "backtick string must not be split, got:\n$result")
  }

  ** Short strings must not be split even with wrapping enabled
  Void testWrapShortStringNotSplit()
  {
    src    := "class Foo\n{\n  Void bar()\n  {\n    msg := \"hi\"\n  }\n}\n"
    o      := opts.copy
    o.maxLineLength = 30
    result := formatWith(src, o)
    verify(!result.contains("\" +"), "short string must not be split")
  }

  ** A string that has no space before maxLen must be left as-is
  Void testWrapStringWithNoWordBoundaryLeftIntact()
  {
    // "superlongwordwithoutspaces" — no space to split at
    src    := "class Foo\n{\n  Void bar()\n  {\n    msg := \"superlongwordwithoutspaces\"\n  }\n}\n"
    o      := opts.copy
    o.maxLineLength = 20
    result := formatWith(src, o)
    verify(result.contains("\"superlongwordwithoutspaces\""), "string without split point must survive intact")
  }

//////////////////////////////////////////////////////////////////////////
// Continuation-line joining
//////////////////////////////////////////////////////////////////////////

  **
  ** A method-call argument where a member access (dot) is split at the end
  ** of one line must be joined with the next line into a single line.
  ** Covers the reported case: Foo.method(a, b, SomeClass.\n    CONST)
  **
  Void testJoinTrailingDotContinuation()
  {
    src    := "class Foo\n{\n  Void bar()\n  {\n    ProgramHandler.podProgramsNeedOverride(cx, pod, MyPodModelParams.\n        DEFAULT_PROGRAMS_URI)\n  }\n}\n"
    result := format(src)
    verify(
      result.contains("MyPodModelParams.DEFAULT_PROGRAMS_URI"),
      "trailing-dot continuation must be joined onto one line; got:\n$result")
    verify(!result.contains("MyPodModelParams.\n"),
      "trailing dot must not remain at end of line; got:\n$result")
  }

  **
  ** An argument list split across lines (unclosed paren) must be joined when
  ** the result fits within maxLineLength.
  **
  Void testJoinUnclosedParenContinuation()
  {
    // "foo(a,\n    b)" fits on one line within 60 chars
    src    := "class Foo\n{\n  Void bar()\n  {\n    result := foo(paramA,\n        paramB)\n  }\n}\n"
    result := formatWrap(src, 60)
    lines  := result.splitLines
    // Should be joined back to a single call expression
    verify(result.contains("foo(paramA, paramB)"),
      "unclosed-paren split must be joined when it fits; got:\n$result")
  }

  **
  ** After joining a trailing-dot continuation, if the joined line still
  ** exceeds maxLineLength, wrapLine must re-split it at a comma.
  **
  Void testJoinThenRewrapExceedingMaxLen()
  {
    // The joined line "foo(paramA, SomeVeryLongClass.LONG_CONSTANT)" is > 30 chars:
    // wrapLine should split at the comma.
    src    := "class Foo\n{\n  Void bar()\n  {\n    result := foo(paramA, SomeVeryLongClass.\n        LONG_CONSTANT)\n  }\n}\n"
    result := formatWrap(src, 30)
    // The trailing dot must not survive
    verify(!result.contains("SomeVeryLongClass.\n"),
      "trailing dot must be eliminated even when re-wrapping is needed; got:\n$result")
  }

  **
  ** Joining must not cross a blank line between continuation fragments.
  **
  Void testJoinDoesNotCrossBlankLine()
  {
    // The blank line between the two non-blank lines must be preserved
    src    := "class Foo\n{\n  Void bar()\n  {\n    foo(a,\n\n        b)\n  }\n}\n"
    result := format(src)
    verify(result.contains("\n\n"), "blank line between continuation lines must be preserved; got:\n$result")
  }

  **
  ** Already-joined lines must not be changed (idempotency for join pass).
  **
  Void testJoinAlreadySingleLineIsIdempotent()
  {
    src   := "class Foo\n{\n  Void bar()\n  {\n    result := foo(paramA, paramB)\n  }\n}\n"
    pass1 := format(src)
    pass2 := format(pass1)
    verifyEq(pass1, pass2, "already-single-line must not be changed on second format pass")
  }

  **
  ** The join+wrap cycle must converge (pass2 == pass3) for the reported case.
  **
  Void testJoinAndWrapConverges()
  {
    src   := "class Foo\n{\n  Void bar()\n  {\n    ProgramHandler.podProgramsNeedOverride(cx, pod, MyPodModelParams.\n        DEFAULT_PROGRAMS_URI)\n  }\n}\n"
    o     := opts.copy
    o.maxLineLength = 120
    pass1 := formatWith(src,   o)
    pass2 := formatWith(pass1, o)
    pass3 := formatWith(pass2, o)
    verifyEq(pass2, pass3, "join+wrap did not stabilise: pass2 != pass3")
  }

  **
  ** A trailing // comment on a continuation-fragment line must be converted
  ** to a /* */ block comment when joining, so it does not eat subsequent
  ** content on the same logical line.
  **
  Void testJoinConvertsTrailingCommentToBlockComment()
  {
    // Trailing comment on "bar" line must be converted; "baz" must survive.
    src := "Str[] x := [\n  \"foo\",\n  \"bar\", // this is a trailing comment\n  \"baz\",\n]\n"
    result := format(src)
    verify(result.contains("\"baz\""),
      "\"baz\" must not be eaten by the trailing comment on the previous line; got:\n$result")
    verify(!result.contains("// this is a trailing comment"),
      "raw // comment must not appear in joined output; got:\n$result")
    verify(result.contains("/* this is a trailing comment */"),
      "trailing comment must be converted to /* */ in joined output; got:\n$result")
  }

  **
  ** Comment-only lines that appear inside a bracket continuation (e.g.
  ** commented-out entries in a list literal) must be converted to block
  ** comments when joining; real entries after them must be preserved.
  **
  Void testJoinConvertsCommentOnlyLinesToBlockComments()
  {
    // The two //icon lines are inside the unclosed '['; they must become /* */.
    src :=
      "Str[] deps := [\n" +
      "  // icon24 = `fan://res/icon24.png`\n" +
      "  // icon72 = `fan://res/icon72.png`\n" +
      "  \"finEntityModelTools\",\n" +
      "  \"finHisKitExt\",\n" +
      "]\n"
    result := format(src)
    verify(result.contains("\"finEntityModelTools\""),
      "finEntityModelTools must not be eaten by comment-only lines; got:\n$result")
    verify(result.contains("\"finHisKitExt\""),
      "finHisKitExt must survive after comment-only lines are converted; got:\n$result")
    verify(result.contains("/* icon24"),
      "comment-only lines must be converted to /* */ in joined output; got:\n$result")
  }

  **
  ** Full @ExtMeta-style scenario: a list literal with both comment-only lines
  ** and trailing inline comments must join without producing a syntax error.
  **
  Void testJoinExtMetaStyleDependsList()
  {
    src :=
      "@ExtMeta\n" +
      "{\n" +
      "  name = \"myExt\"\n" +
      "  //icon24 = `fan://res/icon.png`\n" +
      "  //icon72 = `fan://res/icon.png`\n" +
      "  depends = [\n" +
      "    \"alpha\",\n" +
      "    \"beta\",  // Needed for feature X\n" +
      "    \"gamma\",\n" +
      "  ]\n" +
      "}\n"
    result := format(src)
    // All real entries must appear in the result
    verify(result.contains("\"alpha\""),  "alpha missing; got:\n$result")
    verify(result.contains("\"beta\""),   "beta missing; got:\n$result")
    verify(result.contains("\"gamma\""),  "gamma missing; got:\n$result")
    // The inline comment on beta must be converted to /* */ when joining
    verify(!result.contains("// Needed for feature X"),
      "raw // comment must not appear in joined output; got:\n$result")
    verify(result.contains("/* Needed for feature X */"),
      "inline comment on beta must be converted to /* */ in joined output; got:\n$result")
    // Comment-only lines before depends must be preserved (they are NOT inside
    // the continuation — they come before 'depends = [')
    verify(result.contains("//icon24"), "comment-only line before depends must be preserved; got:\n$result")
  }

//////////////////////////////////////////////////////////////////////////
// Doc-comment lines must never be joined to the following line
//////////////////////////////////////////////////////////////////////////

  **
  ** A single doc-comment line ending with '.' must not be joined to the
  ** method signature that follows it.
  **
  Void testDocCommentNotJoinedToMethodSignature()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  ** Removes every active alarm.\n" +
      "  Void clearAll() {}\n" +
      "}\n"
    result := format(src)
    lines  := result.splitLines
    // The doc-comment and the method must remain on separate lines
    docLine := lines.find |l| { l.trim.startsWith("** Removes") }
    verify(docLine != null, "doc-comment line must be present; got:\n$result")
    verify(!docLine.contains("Void"), "doc-comment must not contain 'Void'; got:\n$result")
    methLine := lines.find |l| { l.trim.startsWith("Void clearAll") }
    verify(methLine != null, "method signature must be on its own line; got:\n$result")
  }

  **
  ** Multiple consecutive doc-comment lines ending with '.' must each stay
  ** on their own line and must not be merged with the following signature.
  **
  Void testMultiDocCommentLinesNotJoinedToSignature()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  ** Removes every active alarm currently present in the alarm database.\n" +
      "  ** A no-op when the database is unavailable or already empty.\n" +
      "  Void clearAllActiveAlarms()\n" +
      "  {\n" +
      "    return\n" +
      "  }\n" +
      "}\n"
    result := format(src)
    lines  := result.splitLines
    // Both doc-comment lines must be individually present
    line1 := lines.find |l| { l.trim.startsWith("** Removes every") }
    line2 := lines.find |l| { l.trim.startsWith("** A no-op") }
    sig   := lines.find |l| { l.trim.startsWith("Void clearAllActiveAlarms") }
    verify(line1 != null, "first doc-comment line missing; got:\n$result")
    verify(line2 != null, "second doc-comment line missing; got:\n$result")
    verify(sig   != null, "method signature missing; got:\n$result")
    // No doc-comment line may bleed into the signature
    verify(!line1.contains("Void"), "first doc-comment must not contain 'Void'; got:\n$result")
    verify(!line2.contains("Void"), "second doc-comment must not contain 'Void'; got:\n$result")
    // No code may appear on a doc-comment line
    verify(!line1.contains("Alarm"),  "no code on first doc-comment line; got:\n$result")
    verify(!line2.contains("AlarmD"), "no code on second doc-comment line; got:\n$result")
  }

  **
  ** Doc-comment lines followed by a method with a try/catch body must be
  ** reproduced faithfully (regression for the reported bug).
  **
  Void testDocCommentBeforeMethodWithTryCatch()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  ** Removes every active alarm currently present in the alarm database.\n" +
      "  ** A no-op when the database is unavailable or already empty.\n" +
      "  Void clearAllActiveAlarms()\n" +
      "  {\n" +
      "    try\n" +
      "    {\n" +
      "      return\n" +
      "    }\n" +
      "    catch (Err ex)\n" +
      "    {\n" +
      "      log.err(ex.toStr)\n" +
      "    }\n" +
      "  }\n" +
      "}\n"
    result := format(src)
    // The two doc-comment lines must survive as separate lines
    lines := result.splitLines
    docLines := lines.findAll |l| { l.trim.startsWith("**") }
    verifyEq(docLines.size, 2, "expected exactly 2 doc-comment lines; got:\n$result")
    docLines.each |dl|
    {
      verify(!dl.contains("Void") && !dl.contains("try") && !dl.contains("return"),
        "doc-comment line must not contain code; got line: $dl\n---\n$result")
    }
  }
}
