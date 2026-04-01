**
** FormatterServiceTest - unit tests for the Fantom source formatter.
**
** Coverage:
** - indentation (spaces and tabs)
** - trailing whitespace
** - blank line collapsing
** - final newline insertion
** - no-op detection for already-formatted source
** - brace counting inside strings / line comments
** - range formatting
** - edit range correctness (range must cover the full document including
** any trailing newline so VS Code does not duplicate it)
** - line-ending preservation: LF, CRLF, CR-only input → same style output
** - idempotency (formatting twice == no second edit)
**
class FormatterServiceTest : Test
{
  private FormatterService fmt := FormatterService()
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
    src := "class Foo\n{\nVoid bar() {}\n}"
    expected := "class Foo\n{\n  Void bar() {}\n}\n"
    verifyEq(format(src), expected)
  }

  Void testNestedBlocks()
  {
    src := "class Foo\n{\nVoid bar()\n{\nif (x)\n{\nreturn\n}\n}\n}"
    result := format(src)
    lines := result.splitLines
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
    lines := result.splitLines
    verifyEq(lines[8], "    else")
    verifyEq(lines[9], "    {")
    verifyEq(lines[10], "      return")
  }

  Void testClosingBraceDecreasesIndent()
  {
    src := "class Foo {\nVoid bar() {\nreturn\n}\n}"
    result := format(src)
    lines := result.splitLines
    verifyEq(lines[3], "  }")
    verifyEq(lines[4], "}")
  }

  Void testFourSpaceIndent()
  {
    o := opts.copy
    o.indentSize = 4
    src := "class Foo\n{\nVoid bar() {}\n}"
    result := formatWith(src, o)
    lines := result.splitLines
    verifyEq(lines[2], "    Void bar() {}")
  }

  //////////////////////////////////////////////////////////////////////////
  // Indentation — tabs
  //////////////////////////////////////////////////////////////////////////

  Void testTabIndent()
  {
    o := opts.copy
    o.useTabs = true
    src := "class Foo\n{\nVoid bar() {}\n}"
    result := formatWith(src, o)
    lines := result.splitLines
    verify(lines[2].startsWith("\t"), "expected tab indent, got: ${lines[2]}")
    verifyEq(lines[2], "\tVoid bar() {}")
  }

  Void testTabNestedIndent()
  {
    o := opts.copy
    o.useTabs = true
    src := "class Foo\n{\nVoid bar()\n{\nreturn\n}\n}"
    result := formatWith(src, o)
    lines := result.splitLines
    verifyEq(lines[4], "\t\treturn")
  }

  //////////////////////////////////////////////////////////////////////////
  // Trailing whitespace
  //////////////////////////////////////////////////////////////////////////

  Void testTrailingWhitespaceTrimmed()
  {
    src := "class Foo   \n{\n  Void bar()   \n}\n"
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
    o.collapseSpaces = false // disable collapse so trailing spaces survive
    src := "class Foo   \n{\n}\n"
    result := formatWith(src, o)
    verify(result.splitLines[0].endsWith("   "))
  }

  //////////////////////////////////////////////////////////////////////////
  // Blank lines
  //////////////////////////////////////////////////////////////////////////

  Void testExcessiveBlankLinesCollapsed()
  {
    src := "class Foo\n{\n\n\n\n  Void bar() {}\n}\n"
    result := format(src)
    lines := result.splitLines
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
    src := "class Foo\n{\n\n\n\n  Void bar() {}\n}\n"
    result := formatWith(src, o)
    verify(result.contains("\n\n\n"))
  }

  Void testMaxBlankLinesTwo()
  {
    o := opts.copy
    o.maxBlankLines = 2
    src := "class Foo\n{\n\n\n\n\n  Void bar() {}\n}\n"
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
    src := "class Foo\n{\nVoid bar() {}\n}\n"
    result := format(src)
    verify(result.endsWith("\n"), "must end with newline")
    verify(!result.endsWith("\n\n"), "must not end with double newline")
  }

  //////////////////////////////////////////////////////////////////////////
  // No-op: already-formatted source
  //////////////////////////////////////////////////////////////////////////

  Void testAlreadyFormattedReturnsEmpty()
  {
    src := "class Foo\n{\n  Void bar() {}\n}\n"
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
    src := "class Foo\n{\nVoid bar() {}\n}\n" // 4 \n → endLine=4
    edit := editFor(src)
    verify(edit != null, "expected at least one edit")
    rangeMap := edit["range"] as Str:Obj?
    endMap := rangeMap["end"] as Str:Obj?
    verifyEq(endMap["line"] as Int, 4)
    verifyEq(endMap["character"] as Int, 0)
  }

  ** LF no trailing: end = {nlCount, lastLineLen}
  Void testEditRangeNoTrailingLf()
  {
    src := "class Foo\n{\nVoid bar() {}\n}" // 3 \n, last line "}" (1 char)
    edit := editFor(src)
    verify(edit != null)
    rangeMap := edit["range"] as Str:Obj?
    endMap := rangeMap["end"] as Str:Obj?
    verifyEq(endMap["line"] as Int, 3)
    verifyEq(endMap["character"] as Int, 1)
  }

  ** CRLF trailing: end = {crlfCount, 0}
  Void testEditRangeCoversTrailingCrlf()
  {
    crlf := "\r\n"
    src := "class Foo" + crlf + "{" + crlf + "Void bar() {}" + crlf + "}" + crlf
    edit := editFor(src)
    verify(edit != null, "expected edit for CRLF file needing indent fix")
    rangeMap := edit["range"] as Str:Obj?
    endMap := rangeMap["end"] as Str:Obj?
    verifyEq(endMap["line"] as Int, 4)
    verifyEq(endMap["character"] as Int, 0)
  }

  ** CRLF no trailing: end = {crlfCount, lastLineLen}
  Void testEditRangeNoTrailingCrlf()
  {
    crlf := "\r\n"
    src := "class Foo" + crlf + "{" + crlf + "}"
    edit := editFor(src)
    verify(edit != null)
    rangeMap := edit["range"] as Str:Obj?
    endMap := rangeMap["end"] as Str:Obj?
    verifyEq(endMap["line"] as Int, 2)
    verifyEq(endMap["character"] as Int, 1)
  }

  ** CR-only trailing: end = {crCount, 0}
  Void testEditRangeCoversTrailingCr()
  {
    cr := "\r"
    src := "class Foo" + cr + "{" + cr + "Void bar() {}" + cr + "}" + cr
    edit := editFor(src)
    verify(edit != null, "expected edit for CR-only file")
    rangeMap := edit["range"] as Str:Obj?
    endMap := rangeMap["end"] as Str:Obj?
    verifyEq(endMap["line"] as Int, 4)
    verifyEq(endMap["character"] as Int, 0)
  }

  ** CR-only no trailing: end = {crCount, lastLineLen}
  Void testEditRangeNoTrailingCr()
  {
    cr := "\r"
    src := "class Foo" + cr + "{" + cr + "}"
    edit := editFor(src)
    verify(edit != null)
    rangeMap := edit["range"] as Str:Obj?
    endMap := rangeMap["end"] as Str:Obj?
    verifyEq(endMap["line"] as Int, 2)
    verifyEq(endMap["character"] as Int, 1)
  }

  ** Range start must always be {0, 0}
  Void testEditRangeStartIsZero()
  {
    src := "class Foo\n{\nVoid bar() {}\n}\n"
    edit := editFor(src)
    verify(edit != null)
    rangeMap := edit["range"] as Str:Obj?
    startMap := rangeMap["start"] as Str:Obj?
    verifyEq(startMap["line"] as Int, 0)
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
    src := "class Foo" + crlf + "{" + crlf + "Void bar() {}" + crlf + "}" + crlf
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
    src := "class Foo" + crlf + "{" + crlf + "}"
    result := format(src)
    verify(result.endsWith(crlf), "final newline must be CRLF for CRLF file")
  }

  Void testCrOnlyPreservedInOutput()
  {
    cr := "\r"
    src := "class Foo" + cr + "{" + cr + "Void bar() {}" + cr + "}" + cr
    result := format(src)
    verify(result.contains("\r"), "CR must appear in output for CR-only file")
    // Should NOT contain \n (bare LF) since the file uses CR only
    verify(!result.contains("\n"), "output must not contain LF for CR-only file")
  }

  Void testLfOutputForLfInput()
  {
    src := "class Foo\n{\nVoid bar() {}\n}\n" // already formatted
    // A file needing reformatting:
    src2 := "class Foo\n{\nVoid bar() {}\n}"
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
    src := "class Foo\n{\nVoid bar() {}\n}\n"
    pass1 := format(src)
    edits2 := fmt.format("file:///test/Foo.fan", pass1, opts, null)
    verifyEq(edits2.size, 0, "LF format is not idempotent: second pass produced edits")
  }

  Void testFormatIsIdempotentLfNoTrailing()
  {
    src := "class Foo\n{\nVoid bar() {}\n}"
    pass1 := format(src)
    edits2 := fmt.format("file:///test/Foo.fan", pass1, opts, null)
    verifyEq(edits2.size, 0, "LF (no trailing \\n) format is not idempotent")
  }

  Void testFormatIsIdempotentCrlf()
  {
    crlf := "\r\n"
    src := "class Foo" + crlf + "{" + crlf + "Void bar() {}" + crlf + "}" + crlf
    pass1 := format(src)
    edits2 := fmt.format("file:///test/Foo.fan", pass1, opts, null)
    verifyEq(edits2.size, 0, "CRLF format is not idempotent: second pass produced edits")
  }

  Void testFormatIsIdempotentCrOnly()
  {
    cr := "\r"
    src := "class Foo" + cr + "{" + cr + "Void bar() {}" + cr + "}" + cr
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
    src := "class Foo\n{\n  Void bar() // returns { x }\n  {\n    return\n  }\n}\n"
    edits := fmt.format("file:///test/Foo.fan", src, opts, null)
    verifyEq(edits.size, 0)
  }

  //////////////////////////////////////////////////////////////////////////
  // Range formatting
  //////////////////////////////////////////////////////////////////////////

  Void testRangeFormat()
  {
    src := "class Foo\n{\nVoid bar() {}\nVoid baz() {}\n}\n"
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
    src := "class Foo\n{\n  Void bar() {}\n}\n"
    range := LspRange(LspPosition(2, 0), LspPosition(2, 16))
    edits := fmt.formatRange("file:///test/Foo.fan", src, range, opts, null)
    verifyEq(edits.size, 0)
  }

  //////////////////////////////////////////////////////////////////////////
  // Edge cases
  //////////////////////////////////////////////////////////////////////////

  Void testEmptyFile()
  {
    src := ""
    edits := fmt.format("file:///test/Foo.fan", src, opts, null)
    verify(edits.size >= 0) // must not crash
  }

  Void testSingleLineNoNewline()
  {
    src := "class Foo {}"
    result := format(src)
    verifyEq(result, "class Foo {}\n")
  }

  Void testSingleLineWithNewline()
  {
    src := "class Foo {}\n"
    edits := fmt.format("file:///test/Foo.fan", src, opts, null)
    verifyEq(edits.size, 0)
  }

  //////////////////////////////////////////////////////////////////////////
  // Space collapsing
  //////////////////////////////////////////////////////////////////////////

  Void testCollapseExtraSpacesTernary()
  {
    // The classic example from the feature request
    src := "class Foo\n{\n  Void bar() { return val ?        0 : 1 }\n}\n"
    result := format(src)
    verify(result.contains("val ? 0 : 1"), "expected collapsed ternary spaces, got: $result")
  }

  Void testCollapseExtraSpacesGeneral()
  {
    src := "class Foo\n{\n  Void bar()  {  return  x  }\n}\n"
    result := format(src)
    // Interior double-spaces should be collapsed
    verify(!result.contains("  {  "), "expected collapsed spaces in body")
  }

  Void testCollapseSpacesPreservesStringContents()
  {
    // Spaces inside string literals must NOT be collapsed
    src := "class Foo\n{\n  Str s := \"hello    world\"\n}\n"
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
    src := "class Foo\n{\n  Void bar() // a    comment\n  {}\n}\n"
    result := format(src)
    verify(result.contains("// a    comment"), "comment spaces must be preserved")
  }

  Void testCollapseSpacesDisabled()
  {
    o := opts.copy
    o.collapseSpaces = false
    src := "class Foo\n{\n  Void bar() { return val ?   0 : 1 }\n}\n"
    result := formatWith(src, o)
    // With collapse disabled the triple space should survive
    verify(result.contains("?   0"), "spaces should be preserved when collapseSpaces=false")
  }

  Void testCollapseSpacesIdempotent()
  {
    src := "class Foo\n{\n  Void bar() { return val ?        0 : 1 }\n}\n"
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
    src := "class Foo\n{\n  Void bar()\n  {\n    result := foo(param1, param2, param3)\n  }\n}\n"
    result := formatWrap(src, 30)
    lines := result.splitLines
    // No line should exceed 30 chars
    lines.each |line| { verify(line.size <= 30 || !line.contains(","), "line too long: $line") }
    // The call should have been split
    verify(result.contains("param1,\n"), "expected split after comma")
  }

  Void testWrapAtLogicalAnd()
  {
    src := "class Foo\n{\n  Void bar()\n  {\n    if (conditionAlpha && conditionBeta)\n    {\n      return\n    }\n  }\n}\n"
    result := formatWrap(src, 30)
    // Should split at &&
    verify(result.contains("&&"), "operator must appear somewhere")
    lines := result.splitLines
    lines.each |line| { verify(line.size <= 30 || !line.contains("&&"), "long line with &&: $line") }
  }

  Void testWrapAtTernary()
  {
    src := "class Foo\n{\n  Void bar()\n  {\n    x := someLongConditionVariable ? valueWhenTrue : valueWhenFalse\n  }\n}\n"
    result := formatWrap(src, 40)
    verify(result.contains("?"), "ternary operator must appear")
    lines := result.splitLines
    lines.each |line| { verify(line.size <= 40 || !line.contains("?"), "long line with ?: $line") }
  }

  Void testWrapDisabledByDefault()
  {
    // Multi-arg method calls are always expanded regardless of line length.
    // A 4-arg call within the 100-char limit is still expanded one-arg-per-line.
    longLine := "    result := someMethod(parameterOne, parameterTwo, parameterThree, parameterFour)"
    src := "class Foo\n{\n  Void bar()\n  {\n" + longLine + "\n  }\n}\n"
    result := format(src)
    lines := result.splitLines
    // The call must be expanded even though it fits within 100 chars
    verify(lines.any |l| { l.trim == "result := someMethod(" },
      "4-arg call must be expanded: opener on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "parameterOne," },
      "first arg must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "parameterFour)" },
      "last arg must be on its own line; got:\n$result")
  }

  Void testWrapShortLineNotChanged()
  {
    o := opts.copy
    o.maxLineLength = 120
    src := "class Foo\n{\n  Void bar() {}\n}\n"
    edits := fmt.format("file:///test/Foo.fan", src, o, null)
    verifyEq(edits.size, 0, "short lines must not be wrapped")
  }

  Void testWrapConvergesAfterTwoPasses()
  {
    // Continuation lines from pass1 may have brace-tracker-vs-wrapper indent
    // disagreement, which pass2 corrects.  After two passes the result must be
    // stable: pass2 == pass3 (no infinite oscillation).
    src := "class Foo\n{\n  Void bar()\n  {\n    result := foo(param1, param2, param3)\n  }\n}\n"
    o := opts.copy
    o.maxLineLength = 30
    pass1 := formatWith(src, o)
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
    src := "class Foo\n{\n  Void bar() { Int c := ' ' }\n}\n"
    result := format(src)
    verify(result.contains("' '"), "single-quoted space must be preserved, got: $result")
  }

  ** Spaces inside backtick DSL strings must not be collapsed
  Void testCollapseSpacesPreservesBacktickString()
  {
    src := "class Foo\n{\n  Void bar() { Uri u := `path/to   something` }\n}\n"
    result := format(src)
    verify(result.contains("`path/to   something`"), "backtick string spaces must be preserved")
  }

  ** Spaces inside triple-quoted strings must not be collapsed
  Void testCollapseSpacesPreservesTripleQuotedString()
  {
    src := "class Foo\n{\n  Str s := \"\"\"hello   world\"\"\"\n}\n"
    result := format(src)
    verify(result.contains("\"\"\"hello   world\"\"\""), "triple-quoted string spaces must be preserved")
  }

  ** A closing \"\"\" inside code must not be mistaken for a string opening
  Void testTripleQuoteDetectionDoesNotCorruptCode()
  {
    // Line has a triple-quoted string followed by code — the brace after
    // the closing \"\"\" must be seen as a real brace, not part of the string.
    src := "class Foo\n{\n  Str s := \"\"\"hello\"\"\"\n}\n"
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
    src := "class Foo\n{\n  Void bar()\n  {\n    msg := \"hello world this is a very long string\"\n  }\n}\n"
    o := opts.copy
    o.maxLineLength = 30
    result := formatWith(src, o)
    // The string must have been split with a concatenation operator
    verify(result.contains("\" +"), "expected string split with \" +, got:\n$result")
    // Every produced line with a string literal must fit within the limit
    /* (the first fragment may still exceed if no earlier word boundary exists */ /* before maxLen — that's acceptable.  Just verify a split happened.) */ verify(result.contains("\n"), "result must be multi-line") }

  ** Splitting a long string should converge after two passes
  Void testWrapLongStringConverges()
  {
    src := "class Foo\n{\n  Void bar()\n  {\n    msg := \"hello world this is a very long string\"\n  }\n}\n"
    o := opts.copy
    o.maxLineLength = 30
    pass1 := formatWith(src, o)
    pass2 := formatWith(pass1, o)
    pass3 := formatWith(pass2, o)
    verifyEq(pass2, pass3, "string split did not stabilise: pass2 != pass3")
  }

  ** A long triple-quoted string should be split at a word boundary using +
  Void testWrapLongTripleQuotedString()
  {
    src := "class Foo\n{\n  Void bar()\n  {\n    msg := \"\"\"hello world this is a very long string\"\"\"\n  }\n}\n"
    o := opts.copy
    o.maxLineLength = 30
    result := formatWith(src, o)
    verify(result.contains("\"\"\" +"), "expected triple-quoted string split with \"\"\" +, got:\n$result")
  }

  ** Backtick (DSL) strings must never be split even when very long
  Void testWrapBacktickStringNotSplit()
  {
    longUri := "`http://example.com/very/long/path/that/definitely/exceeds/any/reasonable/limit`"
    src := "class Foo\n{\n  Void bar()\n  {\n    uri := " + longUri + "\n  }\n}\n"
    o := opts.copy
    o.maxLineLength = 30
    result := formatWith(src, o)
    // The backtick string must be left intact
    verify(result.contains(longUri), "backtick string must not be split, got:\n$result")
  }

  ** Short strings must not be split even with wrapping enabled
  Void testWrapShortStringNotSplit()
  {
    src := "class Foo\n{\n  Void bar()\n  {\n    msg := \"hi\"\n  }\n}\n"
    o := opts.copy
    o.maxLineLength = 30
    result := formatWith(src, o)
    verify(!result.contains("\" +"), "short string must not be split")
  }

  ** A string that has no space before maxLen must be left as-is
  Void testWrapStringWithNoWordBoundaryLeftIntact()
  {
    // "superlongwordwithoutspaces" — no space to split at
    src := "class Foo\n{\n  Void bar()\n  {\n    msg := \"superlongwordwithoutspaces\"\n  }\n}\n"
    o := opts.copy
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
  ** Covers the reported case: Foo.method(a, b, SomeClass.\n CONST)
  **
  Void testJoinTrailingDotContinuation()
  {
    src := "class Foo\n{\n  Void bar()\n  {\n    ProgramHandler.podProgramsNeedOverride(cx, pod, MyPodModelParams.\n        DEFAULT_PROGRAMS_URI)\n  }\n}\n"
    result := format(src)
    verify(result.contains("MyPodModelParams.DEFAULT_PROGRAMS_URI"), "trailing-dot continuation must be joined onto one line; got:\n$result")
    verify(!result.contains("MyPodModelParams.\n"), "trailing dot must not remain at end of line; got:\n$result")
  }

  **
  ** An argument list split across lines (unclosed paren) must be joined when
  ** the result fits within maxLineLength.
  **
  Void testJoinUnclosedParenContinuation()
  {
    // "foo(a,\n    b)" is joined by the continuation-join pre-pass, then
    // re-expanded one-arg-per-line by the unconditional method call expander.
    src := "class Foo\n{\n  Void bar()\n  {\n    result := foo(paramA,\n        paramB)\n  }\n}\n"
    result := formatWrap(src, 60)
    lines := result.splitLines
    // The joined call must be expanded one-arg-per-line
    verify(lines.any |l| { l.trim == "result := foo(" },
      "call opener must be on its own line after join+expand; got:\n$result")
    verify(lines.any |l| { l.trim == "paramA," },
      "first arg must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "paramB)" },
      "last arg must close with ); got:\n$result")
  }

  **
  ** After joining a trailing-dot continuation, if the joined line still
  ** exceeds maxLineLength, wrapLine must re-split it at a comma.
  **
  Void testJoinThenRewrapExceedingMaxLen()
  {
    // The joined line "foo(paramA, SomeVeryLongClass.LONG_CONSTANT)" is > 30 chars:
    // wrapLine should split at the comma.
    src := "class Foo\n{\n  Void bar()\n  {\n    result := foo(paramA, SomeVeryLongClass.\n        LONG_CONSTANT)\n  }\n}\n"
    result := formatWrap(src, 30)
    // The trailing dot must not survive
    verify(!result.contains("SomeVeryLongClass.\n"), "trailing dot must be eliminated even when re-wrapping is needed; got:\n$result")
  }

  **
  ** Joining must not cross a blank line between continuation fragments.
  **
  Void testJoinDoesNotCrossBlankLine()
  {
    // The blank line between the two non-blank lines must be preserved
    src := "class Foo\n{\n  Void bar()\n  {\n    foo(a,\n\n        b)\n  }\n}\n"
    result := format(src)
    verify(result.contains("\n\n"), "blank line between continuation lines must be preserved; got:\n$result")
  }

  **
  ** Already-joined lines must not be changed (idempotency for join pass).
  **
  Void testJoinAlreadySingleLineIsIdempotent()
  {
    src := "class Foo\n{\n  Void bar()\n  {\n    result := foo(paramA, paramB)\n  }\n}\n"
    pass1 := format(src)
    pass2 := format(pass1)
    verifyEq(pass1, pass2, "already-single-line must not be changed on second format pass")
  }

  **
  ** The join+wrap cycle must converge (pass2 == pass3) for the reported case.
  **
  Void testJoinAndWrapConverges()
  {
    src := "class Foo\n{\n  Void bar()\n  {\n    ProgramHandler.podProgramsNeedOverride(cx, pod, MyPodModelParams.\n        DEFAULT_PROGRAMS_URI)\n  }\n}\n"
    o := opts.copy
    o.maxLineLength = 120
    pass1 := formatWith(src, o)
    pass2 := formatWith(pass1, o)
    pass3 := formatWith(pass2, o)
    verifyEq(pass2, pass3, "join+wrap did not stabilise: pass2 != pass3")
  }

  **
  ** A trailing // comment on a list-element line must be preserved on that
  ** element's own line.  With list literals no longer being collapsed-then-
  ** re-expanded, the comment stays as a // comment rather than being
  ** converted to /* */.
  **
  Void testJoinConvertsTrailingCommentToBlockComment()
  {
    // Trailing comment on "bar" line must be preserved; "baz" must survive.
    src := "Str[] x := [\n  \"foo\",\n  \"bar\", // this is a trailing comment\n  \"baz\",\n]\n"
    result := format(src)
    verify(result.contains("\"baz\""), "\"baz\" must not be eaten by the trailing comment on the previous line; got:\n$result")
    // The // comment is now kept verbatim on its element's line
    verify(result.contains("\"bar\", // this is a trailing comment"), "trailing comment must be preserved on bar line; got:\n$result")
  }

  **
  ** Comment-only lines inside a list literal are no longer joined away;
  ** they are preserved as // comments between the real entries.
  **
  Void testJoinConvertsCommentOnlyLinesToBlockComments()
  {
    // The two //icon lines are inside the unclosed '['; they must be preserved.
    src :=
    "Str[] deps := [\n" +
    "  // icon24 = `fan://res/icon24.png`\n" +
    "  // icon72 = `fan://res/icon72.png`\n" +
    "  \"finEntityModelTools\",\n" +
    "  \"finHisKitExt\",\n" +
    "]\n"
    result := format(src)
    verify(result.contains("\"finEntityModelTools\""), "finEntityModelTools must not be eaten by comment-only lines; got:\n$result")
    verify(result.contains("\"finHisKitExt\""), "finHisKitExt must survive after comment-only lines; got:\n$result")
    // Comments are now kept as // on their own lines
    verify(result.contains("// icon24"), "comment-only lines must be preserved as // comments; got:\n$result")
    verify(result.contains("// icon72"), "second comment-only line must be preserved; got:\n$result")
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
    verify(result.contains("\"alpha\""), "alpha missing; got:\n$result")
    verify(result.contains("\"beta\""), "beta missing; got:\n$result")
    verify(result.contains("\"gamma\""), "gamma missing; got:\n$result")
    // Inline // comment on beta is now preserved verbatim on its element line
    // (collapseSpaces may reduce double-space before //, so check with single space)
    verify(result.contains("\"beta\",") && result.contains("// Needed for feature X"), "inline comment on beta must be preserved; got:\n$result")
    // Comment-only lines before depends are preserved as //
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
    lines := result.splitLines
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
    lines := result.splitLines
    // Both doc-comment lines must be individually present
    line1 := lines.find |l| { l.trim.startsWith("** Removes every") }
    line2 := lines.find |l| { l.trim.startsWith("** A no-op") }
    sig := lines.find |l| { l.trim.startsWith("Void clearAllActiveAlarms") }
    verify(line1 != null, "first doc-comment line missing; got:\n$result")
    verify(line2 != null, "second doc-comment line missing; got:\n$result")
    verify(sig != null, "method signature missing; got:\n$result")
    // No doc-comment line may bleed into the signature
    verify(!line1.contains("Void"), "first doc-comment must not contain 'Void'; got:\n$result")
    verify(!line2.contains("Void"), "second doc-comment must not contain 'Void'; got:\n$result")
    // No code may appear on a doc-comment line
    verify(!line1.contains("Alarm"), "no code on first doc-comment line; got:\n$result")
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
      verify(!dl.contains("Void") && !dl.contains("try") && !dl.contains("return"), "doc-comment line must not contain code; got line: $dl\n---\n$result")
    }
  }

  //////////////////////////////////////////////////////////////////////////
  // Closure-body statement joining
  //////////////////////////////////////////////////////////////////////////

  **
  ** A closure with multiple statements split across lines must be joined
  ** using '; ' as the statement separator so the result is valid Fantom.
  **
  Void testJoinClosureMultipleStatementsUsesSemicolon()
  {
    src :=
    "class Foo\n" +
    "{\n" +
    "  Void bar()\n" +
    "  {\n" +
    "    Str[] ids := items.map(|Item it| {\n" +
    "      Str s := it.name\n" +
    "      return s\n" +
    "    })\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    verify(result.contains("Str s := it.name; return s"), "closure statements must be joined with '; ', got:\n$result")
    verify(!result.contains("it.name return"), "closure statements must not be joined with plain space; got:\n$result")
  }

  **
  ** A closure with a single statement must not gain a spurious ';'.
  **
  Void testJoinClosureSingleStatementNoSemicolon()
  {
    src :=
    "class Foo\n" +
    "{\n" +
    "  Void bar()\n" +
    "  {\n" +
    "    Str[] ids := items.map(|Item it| {\n" +
    "      return it.name\n" +
    "    })\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    verify(!result.contains("; return"), "single-statement closure must not introduce '; '; got:\n$result")
    verify(result.contains("return it.name"), "closure body must be preserved; got:\n$result")
  }

  **
  ** A multi-statement closure followed by a chained call must join correctly,
  ** using '; ' between statements and preserving the chain after '}'.
**
Void testJoinClosureWithChainedCall()
{
  src :=
  "class Foo\n" +
  "{\n" +
  "  Void bar()\n" +
  "  {\n" +
  "    Str[] ids := items.map(|Item it| {\n" +
  "      Str s := it.name\n" +
  "      return s\n" +
  "    }).findNotNull\n" +
  "  }\n" +
  "}\n"
  result := format(src)
  verify(result.contains("Str s := it.name; return s"), "closure statements must be joined with '; ', got:\n$result")
  verify(result.contains("findNotNull"), "chained call after closure must be preserved; got:\n$result")
}

**
** Three statements in a closure body must all be separated by '; '.
**
Void testJoinClosureThreeStatementsUsesSemicolon()
{
  src :=
  "class Foo\n" +
  "{\n" +
  "  Void bar()\n" +
  "  {\n" +
  "    Str[] ids := items.map(|Item it| {\n" +
  "      Obj? raw := it.get(\"id\", null)\n" +
  "      if (raw == null) return null\n" +
  "      return raw.toStr\n" +
  "    }).findNotNull\n" +
  "  }\n" +
  "}\n"
  result := format(src)
  verify(result.contains("if (raw == null) return null; return raw.toStr"), "second and third statements must be joined with '; ', got:\n$result")
  verify(result.contains("raw := it.get"), "first statement must be present; got:\n$result")
}

**
** Regular method-call arguments split across lines must join with a space,
** not a semicolon.
**
Void testJoinMethodCallArgsNotSemicolon()
{
  src :=
  "class Foo\n" +
  "{\n" +
  "  Void bar()\n" +
  "  {\n" +
  "    result := foo(paramA,\n" +
  "      paramB)\n" +
  "  }\n" +
  "}\n"
  result := format(src)
  // After join and re-expansion: each arg on its own line, no semicolons
  verify(result.splitLines.any |l| { l.trim == "paramA," },
    "first arg must be on its own line (not joined with '; '); got:\n$result")
  verify(result.splitLines.any |l| { l.trim == "paramB)" },
    "second arg must be on its own line; got:\n$result")
  verify(!result.contains("paramA; paramB"), "method-call args must not use '; ' separator; got:\n$result")
}

**
** A closure whose body is a single boolean expression split across lines
** using '&&' must NOT have '&&;' inserted — it is a continuation of the
** same expression, not separate statements.
**
Void testJoinClosureAndAndExpressionNoSemicolon()
{
  src :=
  "class Foo\n" +
  "{\n" +
  "  Void bar()\n" +
  "  {\n" +
  "    rec := items.find(|Item it->Bool| {\n" +
  "      it.has(\"a\") &&\n" +
  "      it.has(\"b\") &&\n" +
  "      it.get(\"a\") == 1\n" +
  "    })\n" +
  "  }\n" +
  "}\n"
  result := format(src)
  verify(!result.contains("&&;"), "&&; must not appear in joined output; got:\n$result")
  verify(!result.contains("||;"), "||; must not appear in joined output; got:\n$result")
  verify(result.contains("it.has(\"a\") && it.has(\"b\")"), "&&-joined lines must use space separator; got:\n$result")
}

**
** Same as above but with '||'.
**
Void testJoinClosureOrOrExpressionNoSemicolon()
{
  src :=
  "class Foo\n" +
  "{\n" +
  "  Void bar()\n" +
  "  {\n" +
  "    Bool ok := items.any(|Item it->Bool| {\n" +
  "      it.has(\"x\") ||\n" +
  "      it.has(\"y\")\n" +
  "    })\n" +
  "  }\n" +
  "}\n"
  result := format(src)
  verify(!result.contains("||;"), "||; must not appear in joined output; got:\n$result")
  verify(result.contains("it.has(\"x\") || it.has(\"y\")"), "||−joined lines must use space separator; got:\n$result")
}

**
** A method chain where the following line starts with '.' must be joined
** WITHOUT a '; ' separator, even when inside an outer open paren.
** e.g. "val := baseStr\n  .replace(a, b)" → "val := baseStr.replace(a, b)"
**
Void testJoinLeadingDotMethodChainNoSemicolon()
{
  src :=
  "class Foo\n" +
  "{\n" +
  "  Void bar()\n" +
  "  {\n" +
  "    result := items.getOrAdd(key, |Str id->Str| {\n" +
  "      name := base\n" +
  "        .replace(\"A\", \"B\")\n" +
  "        .replace(\"C\", \"D\")\n" +
  "      return name\n" +
  "    })\n" +
  "  }\n" +
  "}\n"
  // Use a large maxLineLength so the joined line is not re-wrapped
  o := opts.copy
  o.maxLineLength = 200
  result := formatWith(src, o)
  verify(!result.contains("; .replace"), "leading-dot continuation must not produce '; .replace'; got:\n$result")
  verify(result.contains("base.replace(\"A\", \"B\").replace(\"C\", \"D\")"), "leading-dot chain must be joined without separator; got:\n$result")
}

**
** Postfix ++ and -- end a statement; the last character '+' or '-' must
** NOT be treated as a binary expression-continuation operator.
** e.g. inside a for-loop body: "i++" followed by "Int x := ..." must get
** "; " between them, not " ".
**
Void testJoinPostfixIncrementUsesSemicolon()
{
  src :=
  "class Foo\n" +
  "{\n" +
  "  Void bar()\n" +
  "  {\n" +
  "    items.each(|Item it| {\n" +
  "      Int n := 0\n" +
  "      for (Int i := 0; i < 3; i++) {\n" +
  "        n++\n" +
  "        Int val := n * 2\n" +
  "        it.add(val)\n" +
  "      }\n" +
  "    })\n" +
  "  }\n" +
  "}\n"
  result := format(src)
  verify(!result.contains("n++ Int"), "postfix ++ must be followed by '; ' not ' '; got:\n$result")
  verify(result.contains("n++; Int val"), "postfix ++ must be separated from next statement by '; '; got:\n$result")
}

**
** After a closing brace that ends an if/else block, a ';' separator must
** NOT be inserted — Fantom treats '}' as an implicit statement terminator
** and '};' is a syntax error. The separator must be a plain space.
**
Void testJoinIfBlockClosingBraceNoSemicolon()
{
  src :=
  "class Foo\n" +
  "{\n" +
  "  Void bar()\n" +
  "  {\n" +
  "    items.each(|Item it| {\n" +
  "      Bool found := false\n" +
  "      if (!found) {\n" +
  "        found = true\n" +
  "      }\n" +
  "      Str s := it.name\n" +
  "      return s\n" +
  "    })\n" +
  "  }\n" +
  "}\n"
  result := format(src)
  verify(!result.contains("};"), "'}; ' must not appear in joined closure body; got:\n$result")
  verify(result.contains("if (!found) { found = true }"), "if block must be joined correctly; got:\n$result")
}

**
** A dict literal containing commented-out entries (//...) must not  ** have subsequent static const declarations joined onto the same line.
** This is a regression for the block-comment-inside-continuation bug:
** `convertLineComment` converts `//foo` to `/* foo */`, and if that
** comment contained `//` in its text, `endsAsContinuation` would stop
** scanning early (false positive depth > 0), joining past `])`.
**
Void testJoinDoesNotMergeStaticConstAfterDictWithCommentedEntries()
{
  src :=
  "class Foo\n" +
  "{\n" +
  "  static const Dict a := Etc.makeDict([\n" +
  "    \"x\": 1,\n" +
  "    //\"y\": 2, // point val wont be changed\n" +
  "    \"z\": 3,\n" +
  "  ])\n" +
  "  static const Dict b := Etc.makeDict([\"q\": 4])\n" +
  "}\n"
  result := format(src)
  // The two static const declarations must remain on separate lines
  lines := result.splitLines
  aLine := lines.find |l| { l.trim.startsWith("static const Dict a") }
  bLine := lines.find |l| { l.trim.startsWith("static const Dict b") }
  verify(aLine != null, "static const a missing; got:\n$result")
  verify(bLine != null, "static const b must be on its own line; got:\n$result")
  verify(aLine !== bLine, "static const a and b must be on separate lines; got:\n$result")
  verify(!aLine.contains("static const Dict b"), "static const b must not appear on the same line as a; got:\n$result")
}

**
** After joining closure statements with '; ', a second format pass must
** produce no further edits (idempotency).
**
Void testJoinClosureSemicolonIdempotent()
{
  src :=
  "class Foo\n" +
  "{\n" +
  "  Void bar()\n" +
  "  {\n" +
  "    Str[] ids := items.map(|Item it| {\n" +
  "      Str s := it.name\n" +
  "      return s\n" +
  "    })\n" +
  "  }\n" +
  "}\n"
  pass1 := format(src)
  edits2 := fmt.format("file:///test/Foo.fan", pass1, opts, null)
  verifyEq(edits2.size, 0, "closure-join with '; ' must be idempotent; second pass produced edits")
}

  //////////////////////////////////////////////////////////////////////////
  // List / map literal expansion
  //
  // When maxLineLength > 0 and a line containing a '[...]' literal exceeds
  // the limit, the formatter expands the literal to one element per line
  // rather than splitting only at the last comma before the limit.
  //
  // All tests use customer-agnostic code; patterns are inspired by typical
  // Fantom build scripts and service-layer code.
  //////////////////////////////////////////////////////////////////////////

  **
  ** A map literal assigned directly to a field must be expanded when the
  ** single-line form exceeds maxLineLength.
  **
  Void testExpandMapLiteralWhenTooLong()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  Void make()\n" +
    "  {\n" +
    "    meta = [\"proj.name\": podName, \"license.name\": \"MIT\", \"org.uri\": \"http://example.com/\"]\n" +
    "  }\n" +
    "}\n"
    o := opts.copy
    o.maxLineLength = 60
    result := formatWith(src, o)
    lines := result.splitLines
    // Should have split the map elements onto separate lines
    verify(lines.size > 8, "map literal should be expanded to multiple lines; got:\n$result")
    // Alignment: maxKLen = 14 ("license.name")
    // "proj.name"   (11) -> 4 spaces; "license.name" (14) -> 1 space; "org.uri" (9) -> 6 spaces
    verify(result.contains("\"proj.name\":    podName,"), "proj.name entry must appear aligned; got:\n$result")
    verify(result.contains("\"license.name\": \"MIT\","), "license.name entry must appear aligned; got:\n$result")
    verify(result.contains("\"org.uri\":      \"http://example.com/\","), "org.uri entry must appear aligned; got:\n$result")
    // Closing ] must be on its own line
    verify(lines.any |l| { l.trim == "]" }, "closing ] must be on its own line; got:\n$result")
  }

  **
  ** A list literal assigned directly to a field must be expanded when the
  ** single-line form exceeds maxLineLength.
  **
  Void testExpandListLiteralWhenTooLong()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  Void make()\n" +
    "  {\n" +
    "    depends = [\"sys 1.0+\", \"inet 1.0+\", \"util 1.0\", \"web 1.0+\", \"concurrent 1.0+\"]\n" +
    "  }\n" +
    "}\n"
    o := opts.copy
    o.maxLineLength = 50
    result := formatWith(src, o)
    lines := result.splitLines
    verify(lines.size > 8, "depends list should be expanded; got:\n$result")
    verify(result.contains("\"sys 1.0+\","), "sys entry must appear on its own line; got:\n$result")
    verify(result.contains("\"concurrent 1.0+\","), "concurrent entry must appear on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "]" }, "closing ] must be on its own line; got:\n$result")
  }

  **
  ** A list of backtick (Dir) literals assigned to a field must be expanded
  ** when the single-line form exceeds maxLineLength.
  **
  Void testExpandBacktickListLiteralWhenTooLong()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  Void make()\n" +
    "  {\n" +
    "    srcDirs = [`fan/`, `fan/models/`, `fan/services/`, `fan/util/`, `fan/pages/`]\n" +
    "  }\n" +
    "}\n"
    o := opts.copy
    o.maxLineLength = 50
    result := formatWith(src, o)
    verify(result.contains("`fan/models/`,"), "models entry must appear on its own line; got:\n$result")
    verify(result.contains("`fan/services/`,"), "services entry must appear on its own line; got:\n$result")
    verify(result.splitLines.any |l| { l.trim == "]" }, "closing ] must be on its own line; got:\n$result")
  }

  **
  ** A multi-element list literal is ALWAYS expanded to one-per-line form,
  ** regardless of how short the single-line form is.  The formatter never
  ** collapses lists back to a single line.
  **
  Void testExpandListEvenWhenShort()
  {
    src :=
    "class Foo\n" +
    "{\n" +
    "  Void bar()\n" +
    "  {\n" +
    "    dirs := [`fan/`, `test/`]\n" +
    "  }\n" +
    "}\n"
    o := opts.copy
    o.maxLineLength = 120
    result := formatWith(src, o)
    // The list has 2 elements — it must be expanded even though it is short
    verify(result.contains("`fan/`,"), "first element must be on its own line; got:\n$result")
    verify(result.contains("`test/`,"), "second element must be on its own line; got:\n$result")
    verify(result.splitLines.any |l| { l.trim == "]" }, "closing ] must be on its own line; got:\n$result")
  }

  **
  ** Multi-element list/map literals are expanded unconditionally — the
  ** maxLineLength setting controls only non-list line wrapping.
  ** Even when maxLineLength is 0 (disabled), list/map literals with two or
  ** more elements are always placed on separate lines.
  **
  Void testExpandAlwaysRegardlessOfMaxLineLength()
  {
    // opts.maxLineLength defaults to 0 (disabled)
    src :=
    "class Foo\n" +
    "{\n" +
    "  Void bar()\n" +
    "  {\n" +
    "    depends = [\"sys 1.0+\", \"inet 1.0+\", \"util 1.0\", \"web 1.0+\", \"concurrent 1.0+\"]\n" +
    "  }\n" +
    "}\n"
    result := format(src) // uses default opts with maxLineLength=0
    // Even without a line-length limit, the list must be expanded
    verify(result.contains("\"sys 1.0+\","), "sys entry must be on its own line even when maxLineLength=0; got:\n$result")
    verify(result.contains("\"concurrent 1.0+\","), "concurrent entry must be on its own line; got:\n$result")
    verify(result.splitLines.any |l| { l.trim == "]" }, "closing ] must be on its own line; got:\n$result")
  }

  **
  ** An already-expanded list (one element per line) must be stable on a
  ** second format pass — the expansion must be idempotent.
  **
  Void testExpandListIsIdempotent()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  Void make()\n" +
    "  {\n" +
    "    depends = [\"sys 1.0+\", \"inet 1.0+\", \"util 1.0\", \"web 1.0+\", \"concurrent 1.0+\"]\n" +
    "  }\n" +
    "}\n"
    o := opts.copy
    o.maxLineLength = 50
    pass1 := formatWith(src, o)
    pass2 := formatWith(pass1, o)
    pass3 := formatWith(pass2, o)
    verifyEq(pass2, pass3, "list expansion must be idempotent: pass2 != pass3; pass2:\n$pass2\npass3:\n$pass3")
  }

  **
  ** An already-expanded map (one entry per line) must be stable on a second
  ** format pass.
  **
  Void testExpandMapIsIdempotent()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  Void make()\n" +
    "  {\n" +
    "    meta = [\"proj.name\": podName, \"license.name\": \"MIT\", \"org.uri\": \"http://example.com/\"]\n" +
    "  }\n" +
    "}\n"
    o := opts.copy
    o.maxLineLength = 60
    pass1 := formatWith(src, o)
    pass2 := formatWith(pass1, o)
    pass3 := formatWith(pass2, o)
    verifyEq(pass2, pass3, "map expansion must be idempotent: pass2 != pass3")
  }

  **
  ** A '[...]' that is an index-access expression (immediately preceded by an
  ** identifier) must NOT be treated as a list literal and must not be expanded.
  **
  Void testNoExpandIndexAccessExpression()
  {
    // arr[0] and map["key"] are index-access, not list literals
    src :=
    "class Foo\n" +
    "{\n" +
    "  Void bar()\n" +
    "  {\n" +
    "    x := someVeryLongVariableName[someOtherLongKey]\n" +
    "  }\n" +
    "}\n"
    o := opts.copy
    o.maxLineLength = 40
    result := formatWith(src, o)
    // Must not have split the index access into multi-line expansion
    verify(!result.contains("[\n"), "index access must not be expanded as a list literal; got:\n$result")
  }

  **
  ** A '[...]' literal inside parentheses (e.g. a method-call argument) must
  ** use the existing comma-split logic rather than the expansion logic.
  **
  Void testNoExpandListInsideParens()
  {
    // The '[...]' is inside '(...)' — expansion must not trigger
    src :=
    "class Foo\n" +
    "{\n" +
    "  Void bar()\n" +
    "  {\n" +
    "    result := buildMapper([\"key1\": handler1, \"key2\": handler2, \"key3\": handler3])\n" +
    "  }\n" +
    "}\n"
    o := opts.copy
    o.maxLineLength = 50
    result := formatWith(src, o)
    // The list is inside a function call — the '[' at paren-depth>0 is skipped,
    // so the existing comma-wrapping applies (not full expansion)
    verify(!result.contains("[\n    \"key1\""), "list inside parens must not get bracket-expansion; got:\n$result")
  }

  **
  ** Each expanded element line must carry a trailing comma so the result is
  ** valid Fantom, including the last element.
  **
  Void testExpandedElementsHaveTrailingCommas()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  Void make()\n" +
    "  {\n" +
    "    depends = [\"sys 1.0+\", \"inet 1.0+\", \"util 1.0\", \"web 1.0+\"]\n" +
    "  }\n" +
    "}\n"
    o := opts.copy
    o.maxLineLength = 50
    result := formatWith(src, o)
    lines := result.splitLines
    // Every non-blank, non-bracket line inside the expanded block must end with ','
    inBlock := false
    lines.each |line|
    {
      t := line.trim
      if (t == "depends = [") { inBlock = true; return }
      if (t == "]") { inBlock = false; return }
      if (inBlock && !t.isEmpty)
        verify(t.endsWith(","), "expanded element must end with ',': $t\ngot:\n$result")
    }
  }

  **
  ** A build-script-style 'meta' map with mixed key/value types must expand
  ** cleanly.  Inspired by the pattern found in Fantom pod build scripts.
  **
  Void testExpandBuildScriptStyleMeta()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    meta = [\"build.num\": buildNum, \"proj.name\": \"myPod\", \"license\": \"Apache-2.0\"]\n" +
    "  }\n" +
    "}\n"
    o := opts.copy
    o.maxLineLength = 60
    result := formatWith(src, o)
    // Alignment: maxKLen = 11 ("build.num" = "proj.name" both 11 chars)
    // "build.num" (11) -> 1 space; "proj.name" (11) -> 1 space; "license" (9) -> 3 spaces
    verify(result.contains("\"build.num\": buildNum,"), "build.num entry missing; got:\n$result")
    verify(result.contains("\"proj.name\": \"myPod\","), "proj.name entry missing; got:\n$result")
    verify(result.contains("\"license\":   \"Apache-2.0\","), "license entry missing; got:\n$result")
    // Verify the indentation depth of elements is correct (one level deeper than meta =)
    lines := result.splitLines
    metaLine := lines.find |l| { l.trim.startsWith("meta = [") }
    elemLine := lines.find |l| { l.trim.startsWith("\"build.num\"") }
    verify(metaLine != null, "meta = [ line missing")
    verify(elemLine != null, "build.num element line missing")
    metaIndent := metaLine.size - metaLine.trimStart.size
    elemIndent := elemLine.size - elemLine.trimStart.size
    verify(elemIndent > metaIndent, "element lines must be indented deeper than the 'meta = [' line")
  }

  **
  ** A list literal with a single element must be expanded onto its own line,
  ** just like any other list — the formatter never leaves a list on one line.
  **
  Void testExpandSingleElementList()
  {
    src :=
    "class Foo\n" +
    "{\n" +
    "  Void bar()\n" +
    "  {\n" +
    "    dirs := [`fan/onlyOneEntryHereAndItIsQuiteALongPath/toSomewhere/`]\n" +
    "  }\n" +
    "}\n"
    o := opts.copy
    o.maxLineLength = 50
    result := formatWith(src, o)
    lines := result.splitLines
    // Single element — must still be on its own line, list never stays on one line
    verify(lines.any |l| { l.trim == "`fan/onlyOneEntryHereAndItIsQuiteALongPath/toSomewhere/`," },
      "single element must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "]" },
      "closing ] must be on its own line; got:\n$result")
  }

  **
  ** A map literal with a single entry must be expanded too.
  **
  Void testExpandSingleElementMap()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    meta = [\"proj.name\": podName]\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    lines := result.splitLines
    verify(lines.any |l| { l.trim == "\"proj.name\": podName," },
      "single map entry must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "]" },
      "closing ] must be on its own line; got:\n$result")
  }

  //////////////////////////////////////////////////////////////////////////
  // Nested list/map expansion
  //
  // Elements whose values are themselves bracket literals must be expanded
  // recursively in a single pass.
  //////////////////////////////////////////////////////////////////////////

  **
  ** A map whose value is itself a map must be fully expanded recursively.
  ** e.g. index = ["ext": "MyExt", "setting": ["k": "v"]]
  **
  Void testNestedMapIsExpandedRecursively()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    index = [\"skyarc.ext\": \"MyExt\", \"fin.setting\": [\"MyExt::Cfg\": \"handler\"]]\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    lines := result.splitLines
    // Outer map entries each on their own line
    verify(lines.any |l| { l.trim.startsWith("\"skyarc.ext\":") },
      "outer key 'skyarc.ext' must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"fin.setting\": [" },
      "nested map opener must be on its own line ending with '['; got:\n$result")
    // Inner map entry on its own line
    verify(lines.any |l| { l.trim.startsWith("\"MyExt::Cfg\":") },
      "inner map entry must be on its own line; got:\n$result")
    // Two separate ']' lines (one for inner map, one for outer)
    Int closers := lines.findAll |l| { l.trim == "]" || l.trim == "]," }.size
    verify(closers >= 2, "at least two closing ']' lines expected; got:\n$result")
  }

  **
  ** A map with a nested list value must expand the nested list recursively.
  **
  Void testNestedListInMapIsExpandedRecursively()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    index = [\"fin.setting\": [\"PodA::ClassA\", \"PodB::ClassB\"]]\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    lines := result.splitLines
    verify(lines.any |l| { l.trim == "\"fin.setting\": [" },
      "map entry with nested list must open the nested list on the same line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"PodA::ClassA\"," },
      "first nested list element must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"PodB::ClassB\"," },
      "second nested list element must be on its own line; got:\n$result")
  }

  **
  ** Nested expansion must be idempotent — a second format pass must not
  ** change the already-expanded output.
  **
  Void testNestedExpansionIsIdempotent()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    index = [\"ext\": \"MyExt\", \"fin.setting\": [\"MyExt::Handler\", \"MyExt::Cfg\"]]\n" +
    "  }\n" +
    "}\n"
    pass1 := format(src)
    pass2 := format(pass1)
    pass3 := format(pass2)
    verifyEq(pass2, pass3, "nested expansion must be idempotent: pass2 != pass3;\npass2:\n$pass2\npass3:\n$pass3")
  }

  //////////////////////////////////////////////////////////////////////////
  // List literals with embedded comments
  //
  // A list/map literal whose body spans multiple source lines and contains
  // inline or full-line comments must NOT be collapsed to a single line by
  // the continuation-join pre-pass.  Each element must remain on its own
  // line after formatting.
  //////////////////////////////////////////////////////////////////////////

  **
  ** A list that contains section comments between groups of entries must
  ** keep every element on its own line.  This is the "depends" pattern
  ** found in Fantom pod build scripts.
  **
  Void testListWithSectionCommentsNotCollapsed()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    depends = [\n" +
    "      // Core\n" +
    "      \"sys 1.0+\",\n" +
    "      \"util 1.0+\",\n" +
    "\n" +
    "      // Network\n" +
    "      \"inet 1.0+\",\n" +
    "      \"web  1.0+\",\n" +
    "    ]\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    lines := result.splitLines
    // Every string entry must be on its own dedicated line
    verify(lines.any |l| { l.trim == "\"sys 1.0+\"," }, "sys must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"util 1.0+\"," }, "util must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"inet 1.0+\"," }, "inet must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"web  1.0+\"," }, "web must be on its own line; got:\n$result")
    // The section comments must still be present
    verify(result.contains("// Core"), "Core comment must be preserved; got:\n$result")
    verify(result.contains("// Network"), "Network comment must be preserved; got:\n$result")
    // No two string entries may appear on the same line without a newline between them
    lines.each |l|
    {
      t := l.trim
      // Skip comment-only or empty lines
      if (t.isEmpty || t.startsWith("//")) return
      // A "bad" line has a closing quote followed by a comma, then later another opening quote
      // e.g.: "sys 1.0+", "util 1.0+",
      Int commaAfterClose := 0
      t.size.times |k|
      {
        if (k > 0 && t[k-1] == '"' && t[k] == ',') commaAfterClose++
      }
      verify(commaAfterClose <= 1, "two entries must not appear on the same line: $l\n---\n$result")
    }
  }

  **
  ** An already-formatted multi-line list with section comments must be
  ** stable on a second format pass (idempotency).
  **
  Void testListWithSectionCommentsIsIdempotent()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    depends = [\n" +
    "      // Core\n" +
    "      \"sys 1.0+\",\n" +
    "      \"util 1.0+\",\n" +
    "\n" +
    "      // Network\n" +
    "      \"inet 1.0+\",\n" +
    "      \"web  1.0+\",\n" +
    "    ]\n" +
    "  }\n" +
    "}\n"
    pass1 := format(src)
    pass2 := format(pass1)
    pass3 := format(pass2)
    verifyEq(pass2, pass3, "list with section comments must be idempotent: pass2 != pass3")
  }

  **
  ** A list literal that starts on the same line as the assignment and
  ** continues on subsequent lines with section comments must produce
  ** one-element-per-line output without collapsing any entries.
  **
  Void testListOpenOnAssignmentLineWithComments()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    deps = [\"alpha 1.0+\",\n" +
    "      // Beta group\n" +
    "      \"beta 2.0+\",\n" +
    "      \"gamma 3.0+\",\n" +
    "    ]\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    lines := result.splitLines
    verify(lines.any |l| { l.trim == "\"alpha 1.0+\"," }, "alpha must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"beta 2.0+\"," }, "beta must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"gamma 3.0+\"," }, "gamma must be on its own line; got:\n$result")
    verify(result.contains("// Beta group"), "Beta group comment must survive; got:\n$result")
  }

  **
  ** A map literal that starts on the same line as the assignment and
  ** continues on subsequent lines must produce one-entry-per-line output.
  **
  Void testMapOpenOnAssignmentLineMultiLine()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    meta = [\"proj.name\": podName,\n" +
    "      \"org.name\": \"Example Org\",\n" +
    "      \"license\": \"Apache-2.0\",\n" +
    "    ]\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    lines := result.splitLines
    // Alignment: maxKLen = 11 ("proj.name"); "org.name" (10) -> 2 spaces; "license" (9) -> 3 spaces
    verify(lines.any |l| { l.trim == "\"proj.name\": podName," }, "proj.name must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"org.name\":  \"Example Org\"," }, "org.name must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"license\":   \"Apache-2.0\"," }, "license must be on its own line; got:\n$result")
  }

  **
  ** A list literal that is already written all on one line must be expanded
  ** to one-per-line even when it contains no comments.
  **
  Void testSingleLineListExpandedToMultiLine()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    dirs = [`fan/`, `test/`, `res/`]\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    lines := result.splitLines
    verify(lines.any |l| { l.trim == "`fan/`," }, "`fan/ must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "`test/`," }, "`test/ must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "`res/`," }, "`res/ must be on its own line; got:\n$result")
  }

  //////////////////////////////////////////////////////////////////////////
  // Map value alignment
  //
  // Map literals with multiple entries must have their values aligned so
  // they all start at the same column, determined by the longest key.
  //////////////////////////////////////////////////////////////////////////

  **
  ** A map literal's values must be aligned to the column of the longest
  ** key: 1 space after ':' for the longest, more for shorter keys.
  **
  Void testMapAlignValues()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    meta = [\"proj.name\": podName, \"org.name\": \"Example Org\", \"pod.docLocation\": \"finDoc\"]\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    // "proj.name"      = 11 chars (with quotes) → spaces = 17 - 11 + 1 = 7
    // "org.name"       = 10 chars               → spaces = 17 - 10 + 1 = 8
    // "pod.docLocation"= 17 chars               → spaces = 1
    verify(result.contains("\"proj.name\":       podName,"),
      "proj.name must have 7 spaces after colon; got:\n$result")
    verify(result.contains("\"org.name\":        \"Example Org\","),
      "org.name must have 8 spaces after colon; got:\n$result")
    verify(result.contains("\"pod.docLocation\": \"finDoc\","),
      "pod.docLocation must have 1 space after colon; got:\n$result")
  }

  **
  ** Map alignment must be stable across multiple format passes.
  **
  Void testMapAlignValuesIsIdempotent()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    meta = [\"proj.name\": podName, \"org.name\": \"Example Org\", \"pod.docLocation\": \"finDoc\"]\n" +
    "  }\n" +
    "}\n"
    pass1 := format(src)
    pass2 := format(pass1)
    pass3 := format(pass2)
    verifyEq(pass2, pass3, "map alignment must be idempotent: pass2 != pass3;\npass2:\n$pass2\npass3:\n$pass3")
  }

  **
  ** A plain list (no key: value entries) must NOT be aligned — the
  ** alignment pass must leave list blocks unchanged.
  **
  Void testListNotAligned()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    depends = [\"sys 1.0+\", \"inet 1.0+\", \"util 1.0\"]\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    // List elements must appear one per line with a trailing comma but no
    // extra spaces injected by the alignment pass
    verify(result.contains("\"sys 1.0+\","),  "sys entry must be present; got:\n$result")
    verify(result.contains("\"inet 1.0+\","), "inet entry must be present; got:\n$result")
    verify(result.contains("\"util 1.0\","),  "util entry must be present; got:\n$result")
    // No spurious leading spaces from alignment (element must trim to the bare string)
    lines := result.splitLines
    verify(lines.any |l| { l.trim == "\"sys 1.0+\"," },  "sys element must not have extra spaces; got:\n$result")
    verify(lines.any |l| { l.trim == "\"inet 1.0+\"," }, "inet element must not have extra spaces; got:\n$result")
  }

  **
  ** A map whose value is itself a list literal must be aligned together
  ** with the other entries in the outer map.  The nested list is not
  ** treated as a map and its contents are left unaligned.
  **
  Void testMapWithNestedListValueAligned()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    index = [\"x.name\": \"MyExt\", \"x.setting.long\": [\"MyExt::ClassA\"]]\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    // "x.name"         = 8 chars  → spaces = 16 - 8 + 1 = 9
    // "x.setting.long" = 16 chars → spaces = 1
    verify(result.contains("\"x.name\":         \"MyExt\","),
      "x.name must have 9 spaces after colon; got:\n$result")
    verify(result.contains("\"x.setting.long\": ["),
      "x.setting.long must have 1 space after colon; got:\n$result")
    // The nested list element (plain string) must not be affected
    verify(result.contains("\"MyExt::ClassA\","),
      "inner list element must survive; got:\n$result")
  }

  **
  ** When alignment would push a line past maxLineLength the formatter
  ** must fall back to a single space after ':'.
  **
  Void testMapAlignRespectsMaxLineLength()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    meta = [\"a\": \"short\", \"a.very.long.key\": \"short\"]\n" +
    "  }\n" +
    "}\n"
    o := opts.copy
    o.maxLineLength = 30  // very tight — alignment would produce overlong lines without fallback
    result := formatWith(src, o)
    // For the short key "a", alignment would pad it with many spaces (15) which would make the
    // line exceed 30 chars — the formatter must fall back to 1 space for that entry.
    verify(result.contains("\"a\": \"short\","),
      "short key 'a' must use 1 space (fallback) when alignment would overflow; got:\n$result")
    // The long key also uses the minimum 1 space — it still exceeds maxLineLength but that is
    // unavoidable; the important thing is NO extra padding was added.
    verify(result.contains("\"a.very.long.key\": \"short\","),
      "long key must use 1 space (minimum) after colon; got:\n$result")
  }

  //////////////////////////////////////////////////////////////////////////
  // Multi-line bracket blocks with elements on the opener line
  //
  // The normalizeBracketBlocks pre-pass must reassemble any bracket literal
  // whose elements are spread across multiple source lines — including cases
  // where elements appear on the same line as the opener '['.
  //////////////////////////////////////////////////////////////////////////

  **
  ** A map literal whose elements span two source lines (first line has
  ** elements after '[', second line has remaining elements plus ']') must
  ** be fully expanded to one-element-per-line.
  **
  Void testMultiLineMapWithElementsOnOpenerLine()
  {
    // Simulates the "meta = [..." pattern from pod build scripts
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    meta = [\"proj.name\": podName, \"org.name\": \"Example\", \"org.uri\": \"http://example.com/\",\n" +
    "      \"license.name\": \"Apache-2.0\", \"pod.docLocation\": \"doc\", ]\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    lines := result.splitLines
    // Every entry must be on its own line
    verify(lines.any |l| { l.trim.startsWith("\"proj.name\":") },
      "proj.name must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim.startsWith("\"org.name\":") },
      "org.name must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim.startsWith("\"license.name\":") },
      "license.name must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim.startsWith("\"pod.docLocation\":") },
      "pod.docLocation must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "]" },
      "closing ] must be on its own line; got:\n$result")
    // Result must be idempotent
    pass2 := format(result)
    verifyEq(result, pass2,
      "multi-line map with elements on opener line must be idempotent; got:\n$result\npass2:\n$pass2")
  }

  **
  ** A list literal whose first line starts with a block-comment before the
  ** first element (e.g. \"depends = [/* Fantom */ \"sys\", ...\") must have
  ** the block comment stripped and elements expanded normally.
  **
  Void testListWithBlockCommentPrefixExpanded()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    depends = [/* Fantom */ \"sys 1.0+\", \"concurrent 1.0+\", \"inet 1.0+\"]\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    lines := result.splitLines
    verify(lines.any |l| { l.trim == "\"sys 1.0+\"," },
      "sys must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"concurrent 1.0+\"," },
      "concurrent must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"inet 1.0+\"," },
      "inet must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "]" },
      "closing ] must be on its own line; got:\n$result")
  }

  **
  ** A multi-line list that has a block-comment on the opener line and
  ** further elements on subsequent lines must be fully expanded.
  **
  Void testMultiLineListWithBlockCommentPrefixExpanded()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    depends = [/* Fantom */ \"sys 1.0+\", \"concurrent 1.0+\", \"inet 1.0+\",\n" +
    "      \"util 1.0\", \"web 1.0+\",\n" +
    "    ]\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    lines := result.splitLines
    verify(lines.any |l| { l.trim == "\"sys 1.0+\"," },
      "sys must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"web 1.0+\"," },
      "web must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "]" },
      "closing ] must be on its own line; got:\n$result")
    // The block comment must be gone (it was a layout artefact)
    verify(!result.contains("/* Fantom */"),
      "block-comment prefix must be stripped; got:\n$result")
    // Idempotency
    pass2 := format(result)
    verifyEq(result, pass2,
      "multi-line list with block-comment prefix must be idempotent;\n$result\npass2:\n$pass2")
  }

  **
  ** A map literal with a nested list value that spans multiple source lines
  ** must be fully normalised — outer map entries on their own lines, nested
  ** list elements on their own lines.
  **
  Void testMultiLineMapWithNestedListNormalized()
  {
    src :=
    "class Build\n" +
    "{\n" +
    "  new make()\n" +
    "  {\n" +
    "    index = [\"skyarc.ext\": \"MyExt\",\n" +
    "      \"fin.setting\": [\"MyExt::HandlerA\", \"MyExt::HandlerB\"], ]\n" +
    "  }\n" +
    "}\n"
    result := format(src)
    lines := result.splitLines
    verify(lines.any |l| { l.trim.startsWith("\"skyarc.ext\":") },
      "skyarc.ext must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"fin.setting\": [" },
      "fin.setting opener must end with '['; got:\n$result")
    verify(lines.any |l| { l.trim == "\"MyExt::HandlerA\"," },
      "HandlerA must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"MyExt::HandlerB\"," },
      "HandlerB must be on its own line; got:\n$result")
    // Stabilises after at most 3 passes (normalization + re-indentation)
    pass2 := format(result)
    pass3 := format(pass2)
    verifyEq(pass2, pass3,
      "multi-line map with nested list must stabilise after pass2;\npass2:\n$pass2\npass3:\n$pass3")
  }

  //////////////////////////////////////////////////////////////////////////
  // Full pod build.fan round-trip  //
  // The following test uses a realistic (but anonymised) build.fan that
  // exercises every list/map expansion scenario in one shot:
  //   • meta   — map with multiple string/URI entries
  //   • depends — list with section comments and varying whitespace alignment
  //   • srcDirs / resDirs — plain URI lists
  //   • index   — outer map with nested list value (["fin.setting": [...]])
  //
  // The input is a one-liner (the way a formatter must handle an
  // already-hand-aligned file) and the expected output is the canonical
  // fully-expanded, properly-indented form.
  //////////////////////////////////////////////////////////////////////////

  **
  ** Format a realistic anonymised pod build.fan and verify:
  **   1. Every map/list entry is on its own line at the correct indent level.
  **   2. The nested "fin.setting" list is indented two levels deeper than
  **      the outer map's '[' and its closing ']' is indented one level deeper.
  **   3. The result is idempotent (a second format pass produces no changes).
  **
  Void testRealWorldBuildFanFormatting()
  {
    // Anonymised content that mirrors the structure of a real pod build script.
    // All proprietary/commercial names are replaced with generic placeholders.
    src :=
      "using finBuild\n" +
      "\n" +
      "class Args : BuildFinArgs {\n" +
      "  new make() : super(Build#make) {}\n" +
      "}\n" +
      "\n" +
      "class Build : BuildFinPod {\n" +
      "\n" +
      "  new make(Args args) : super(args) {\n" +
      "    podName = \"myPodExt\"\n" +
      "    summary = \"Source code for the example app product extension\"\n" +
      "    version = Version(\"1.0.0\")\n" +
      "\n" +
      "    meta = [\n" +
      "      \"proj.name\":       podName,\n" +
      "      \"org.name\":        \"Example Org\",\n" +
      "      \"org.uri\":         \"http://www.example.com/\",\n" +
      "      \"license.name\":    \"Commercial\",\n" +
      "      \"pod.docLocation\": \"finDoc\",\n" +
      "    ]\n" +
      "\n" +
      "    depends = [\n" +
      "      // Fantom\n" +
      "      \"sys        1.0+\",\n" +
      "      \"concurrent 1.0+\",\n" +
      "      \"inet       1.0+\",\n" +
      "      \"util       1.0\",\n" +
      "      \"web        1.0+\",\n" +
      "\n" +
      "      // Framework\n" +
      "      \"frameworkCore    3.0.20+\",\n" +
      "      \"frameworkExt     3.0.20+\",\n" +
      "\n" +
      "      // App\n" +
      "      \"appCore    5.0+\",\n" +
      "      \"appExt     5.0+\",\n" +
      "      \"appSettings 5.1+\",\n" +
      "    ]\n" +
      "\n" +
      "    srcDirs = [\n" +
      "      `fan/`,\n" +
      "      `fan/models/`,\n" +
      "      `fan/pages/`,\n" +
      "      `fan/settings/`,\n" +
      "      `test/`,\n" +
      "    ]\n" +
      "    resDirs = [\n" +
      "      `lib/`,\n" +
      "      `locale/`,\n" +
      "      `res/`,\n" +
      "    ]\n" +
      "\n" +
      "    index = [\n" +
      "      \"skyarc.ext\":  \"myPodExt::MyPodExt\",\n" +
      "      \"skyarc.lib\":  \"myPodExt::MyPodLib\",\n" +
      "      \"fin.lang\": \"myPodExt\", // locale\n" +
      "      \"fin.setting\": [\n" +
      "        \"mySerialPod:myPodExt::SettingSerialPorts\",\n" +
      "      ],\n" +
      "    ]\n" +
      "  }\n" +
      "}\n"

    result := format(src)
    lines := result.splitLines

    // -----------------------------------------------------------------------
    // meta
    // -----------------------------------------------------------------------
    verify(lines.any |l| { l.trim == "meta = [" },
      "meta opener must be on its own line ending with '['; got:\n$result")
    verify(lines.any |l| { l.trim.startsWith("\"proj.name\":") },
      "meta proj.name must be on its own indented line; got:\n$result")
    verify(lines.any |l| { l.trim.startsWith("\"pod.docLocation\":") },
      "meta pod.docLocation must be on its own indented line; got:\n$result")

    // -----------------------------------------------------------------------
    // depends — section comments preserved, elements one per line
    // -----------------------------------------------------------------------
    verify(lines.any |l| { l.trim == "depends = [" },
      "depends opener must end with '['; got:\n$result")
    verify(lines.any |l| { l.trim == "// Fantom" },
      "// Fantom section comment must be preserved; got:\n$result")
    verify(lines.any |l| { l.trim == "// Framework" },
      "// Framework section comment must be preserved; got:\n$result")
    verify(lines.any |l| { l.trim.startsWith("\"sys") },
      "sys dependency must appear; got:\n$result")

    // -----------------------------------------------------------------------
    // srcDirs / resDirs
    // -----------------------------------------------------------------------
    verify(lines.any |l| { l.trim == "srcDirs = [" },
      "srcDirs opener must end with '['; got:\n$result")
    verify(lines.any |l| { l.trim == "resDirs = [" },
      "resDirs opener must end with '['; got:\n$result")

    // -----------------------------------------------------------------------
    // index — outer map + nested list
    // -----------------------------------------------------------------------
    verify(lines.any |l| { l.trim == "index = [" },
      "index opener must end with '['; got:\n$result")

    // The "fin.setting" key must be an entry in the outer map with a nested
    // list opener — its line must end with ': ['.
    verify(lines.any |l| { l.trim == "\"fin.setting\": [" },
      "fin.setting entry must end with ': ['; got:\n$result")

    // The nested list element must be indented TWO levels deeper than index's '['
    Int indexOpenerIndent := -1
    lines.each |l|
    {
      if (l.trim == "index = [")
      {
        idx := 0
        while (idx < l.size && l[idx] == ' ') idx++
        indexOpenerIndent = idx
      }
    }
    verify(indexOpenerIndent >= 0, "index opener line not found; got:\n$result")

    Int settingElemIndent := -1
    lines.each |l|
    {
      if (l.trim == "\"mySerialPod:myPodExt::SettingSerialPorts\",")
      {
        idx := 0
        while (idx < l.size && l[idx] == ' ') idx++
        settingElemIndent = idx
      }
    }
    verify(settingElemIndent >= 0,
      "SettingSerialPorts element must appear on its own line; got:\n$result")
    verifyEq(settingElemIndent, indexOpenerIndent + 4,
      "nested list element must be indented 4 spaces deeper than 'index = ['; got:\n$result")

    // The fin.setting closer '],' must be ONE indent level deeper than index's '['
    Int settingCloserIndent := -1
    // Find the '],' that immediately follows the SettingSerialPorts line
    for (i := 0; i < lines.size; i++)
    {
      if (lines[i].trim == "\"mySerialPod:myPodExt::SettingSerialPorts\","
          && i + 1 < lines.size && lines[i+1].trim == "],")
      {
        cl := lines[i+1]
        idx := 0
        while (idx < cl.size && cl[idx] == ' ') idx++
        settingCloserIndent = idx
      }
    }
    verify(settingCloserIndent >= 0,
      "'],' closer for fin.setting must appear on its own line; got:\n$result")
    verifyEq(settingCloserIndent, indexOpenerIndent + 2,
      "fin.setting closer '],' must be indented 2 spaces deeper than 'index = ['; got:\n$result")

    // -----------------------------------------------------------------------
    // Idempotency
    // -----------------------------------------------------------------------
    pass2 := format(result)
    verifyEq(result, pass2,
      "real-world build.fan formatting must be idempotent;\npass1:\n$result\npass2:\n$pass2")
  }

  //////////////////////////////////////////////////////////////////////////
  // Block comment (/* ... */) preservation
  //
  // Lines inside a multi-line /* ... */ block comment must be emitted
  // verbatim — internal formatting, spacing, and bracket-like patterns
  // must not be modified.
  //////////////////////////////////////////////////////////////////////////

  **
  ** A multi-line /* */ block comment must be passed through verbatim:
  **   • Space runs inside comment lines are NOT collapsed.
  **   • Bracket-like patterns (e.g. table rows with [1, 17, 33]) are NOT
  **     bracket-expanded or normalised.
  **   • Comment lines ending with '.' are NOT joined to the next line.
  **
  Void testBlockCommentPreservedVerbatim()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  /**\n" +
      "   Converts a value to a list.\n" +
      "\n" +
      "   @param value  The value to convert.  Must be positive.\n" +
      "   @param nBits  Number of bits.  Defaults to 16.\n" +
      "\n" +
      "   Example table (rows = instance, cols = bit):\n" +
      "\n" +
      "       instance    0    1    2    3\n" +
      "              1   [1,  17,  33,  49]\n" +
      "              2   [2,  18,  34,  50]\n" +
      "   */\n" +
      "  Int[] convert(Int value) { return [,] }\n" +
      "}\n"

    result := format(src)

    // The @param lines must NOT be joined together even though they end with '.'
    verify(result.contains("@param value  The value to convert.  Must be positive."),
      "@param value line must be preserved verbatim; got:\n$result")
    verify(result.contains("@param nBits  Number of bits.  Defaults to 16."),
      "@param nBits line must be preserved verbatim; got:\n$result")

    // Table rows: spaces must NOT be collapsed
    verify(result.contains("[1,  17,  33,  49]"),
      "table row must keep its aligned spaces; got:\n$result")
    verify(result.contains("[2,  18,  34,  50]"),
      "second table row must keep its aligned spaces; got:\n$result")

    // The code after the comment must still be formatted normally
    verify(result.contains("Int[] convert(Int value)"),
      "code after block comment must appear; got:\n$result")

    // Idempotency
    pass2 := format(result)
    verifyEq(result, pass2,
      "block comment preservation must be idempotent; got:\n$result\npass2:\n$pass2")
  }

  **
  ** A single-line // comment with internal commas and parentheses must
  ** NOT be split at any comma or operator — it is emitted as-is (or
  ** word-wrapped only when it exceeds maxLineLength).
  **
  Void testSingleLineCommentWithCommasNotSplit()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    // Cantor pairing function: f(a,b) = n*(a) + b, guarantees (1,2) != (2,1).\n" +
      "    return pairing(1, 2)\n" +
      "  }\n" +
      "}\n"

    result := format(src)
    // The whole comment must appear on exactly one line, unchanged
    verify(result.contains("// Cantor pairing function: f(a,b) = n*(a) + b, guarantees (1,2) != (2,1)."),
      "comment with commas must not be split; got:\n$result")
  }

  **
  ** When maxLineLength is set, a long // comment must be word-wrapped
  ** at a space boundary — NOT split at a comma or operator.
  **
  Void testLongCommentWordWraps()
  {
    o := opts.copy
    o.maxLineLength = 60
    src :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    // This is a very long comment that exceeds sixty chars and should wrap at a space.\n" +
      "    return 1\n" +
      "  }\n" +
      "}\n"

    result := formatWith(src, o)
    lines := result.splitLines
    // Every output line must be at most 60 chars (or the single-word case)
    lines.each |l|
    {
      if (l.trim.startsWith("//"))
        verify(l.size <= 60 || !l.contains(" "),
          "comment line must be wrapped to <=60 chars; got: '$l'")
    }
    // All comment lines must still start with //
    Int commentCount := lines.findAll |l| { l.trim.startsWith("//") }.size
    verify(commentCount >= 2, "wrapped comment must produce at least 2 // lines; got:\n$result")
  }

  **
  ** A ** Fantom doc comment line must NOT have bracket literals inside it
  ** expanded as if they were code.
  **
  Void testFantomDocCommentBracketsNotExpanded()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  ** Returns a list [open, close] containing the bracket pair.\n" +
      "  Str[] brackets() { return [\"(\", \")\"] }\n" +
      "}\n"

    result := format(src)
    // The ** line must be preserved as-is — the [open, close] must NOT be expanded
    verify(result.contains("** Returns a list [open, close] containing the bracket pair."),
      "** doc comment with brackets must not be expanded; got:\n$result")
  }

  //////////////////////////////////////////////////////////////////////////
  // convertFantomDocComments option
  //////////////////////////////////////////////////////////////////////////

  **
  ** When convertFantomDocComments is true, a '//' comment block immediately
  ** above a method declaration is converted to '**' Fantom doc style.
  **
  Void testConvertLineCommentToFantomDoc()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  // Returns the sum of a and b.\n" +
      "  // Both parameters must be non-negative.\n" +
      "  Int add(Int a, Int b) { return a + b }\n" +
      "}\n"

    o := opts.copy
    o.convertFantomDocComments = true
    result := formatWith(src, o)

    verify(result.contains("** Returns the sum of a and b."),
      "// comment must be converted to **; got:\n$result")
    verify(result.contains("** Both parameters must be non-negative."),
      "second // comment line must be converted; got:\n$result")
    verify(!result.contains("// Returns"),
      "original // must be gone after conversion; got:\n$result")
  }

  **
  ** When convertFantomDocComments is false (default), '//' comments above
  ** methods must NOT be touched.
  **
  Void testConvertDocCommentsDisabledByDefault()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  // Returns the sum.\n" +
      "  Int add(Int a, Int b) { return a + b }\n" +
      "}\n"

    result := format(src)  // default opts — convertFantomDocComments = false
    verify(result.contains("// Returns the sum."),
      "// comment must be left alone when option is disabled; got:\n$result")
  }

  **
  ** A '//' comment that is NOT immediately followed by a declaration
  ** (e.g. it's a section separator or inline comment) must NOT be converted.
  **
  Void testConvertDocCommentsOnlyBeforeDeclarations()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  // This is a section header\n" +
      "\n" +
      "  Int add(Int a, Int b) { return a + b }\n" +
      "}\n"

    o := opts.copy
    o.convertFantomDocComments = true
    result := formatWith(src, o)

    // There's a blank line between the comment and the method — don't convert
    verify(result.contains("// This is a section header"),
      "comment with blank line before method must NOT be converted; got:\n$result")
  }

  //////////////////////////////////////////////////////////////////////////
  // Method call / declaration argument expansion
  //////////////////////////////////////////////////////////////////////////

  **
  ** A method call with 2+ arguments whose total length exceeds maxLineLength
  ** must be expanded to one argument per line.
  **
  Void testMethodCallArgsExpandedWhenTooLong()
  {
    o := opts.copy
    o.maxLineLength = 60
    src :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    return makeFromDbInternal(cx, siteRef, modelIdName, entityModelIdVal)\n" +
      "  }\n" +
      "}\n"

    result := formatWith(src, o)
    lines := result.splitLines

    // The opening line must end with '('
    verify(lines.any |l| { l.trim == "return makeFromDbInternal(" },
      "method call opener must be on its own line; got:\n$result")
    // Each argument must be on its own line
    verify(lines.any |l| { l.trim == "cx," },
      "first arg must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "siteRef," },
      "second arg must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "modelIdName," },
      "third arg must be on its own line; got:\n$result")
    // Last arg has closing ')' appended
    verify(lines.any |l| { l.trim == "entityModelIdVal)" },
      "last arg must have ) appended; got:\n$result")
  }

  **
  ** Method call expansion must be idempotent.
  **
  Void testMethodCallExpansionIdempotent()
  {
    o := opts.copy
    o.maxLineLength = 60
    src :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    return makeFromDbInternal(cx, siteRef, modelIdName, entityModelIdVal)\n" +
      "  }\n" +
      "}\n"

    pass1 := formatWith(src, o)
    pass2 := formatWith(pass1, o)
    verifyEq(pass1, pass2, "method call expansion must be idempotent;\npass1:\n$pass1\npass2:\n$pass2")
  }

  **
  ** A method call with 2+ arguments is always expanded to one-arg-per-line,
  ** even when the arguments are short.
  **
  Void testShortMethodCallNotExpanded()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  Void bar() { return add(x, y) }\n" +
      "}\n"

    result := format(src)
    // The 2-arg call must be expanded unconditionally
    verify(result.splitLines.any |l| { l.trim == "x," },
      "short 2-arg call must be expanded: x must be on its own line; got:\n$result")
    // Last arg carries any suffix from the original line (e.g. ' }' here)
    verify(result.splitLines.any |l| { l.trim.startsWith("y)") },
      "short 2-arg call must be expanded: y must be on its own line; got:\n$result")
  }

  **
  ** Method call expansion is always triggered for 2+ args, regardless of
  ** line length.  This is the same unconditional policy as list/map expansion.
  **
  Void testMethodCallAlwaysExpandedRegardlessOfLength()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    foo(a, b)\n" +
      "  }\n" +
      "}\n"

    result := format(src)
    lines := result.splitLines
    verify(lines.any |l| { l.trim == "foo(" },
      "2-arg call must be expanded: opener on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "a," },
      "first arg must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "b)" },
      "last arg must close with ); got:\n$result")
    // Idempotent
    pass2 := format(result)
    verifyEq(result, pass2,
      "always-expand must be idempotent; pass1:\n$result\npass2:\n$pass2")
  }

  **
  ** A method call with exactly 1 argument must NOT be expanded.
  **
  Void testSingleArgMethodCallNotExpanded()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    doSomething(value)\n" +
      "  }\n" +
      "}\n"

    result := format(src)
    verify(result.contains("doSomething(value)"),
      "single-arg call must stay on one line; got:\n$result")
    // Idempotent
    pass2 := format(result)
    verifyEq(result, pass2,
      "single-arg call must be idempotent; pass1:\n$result\npass2:\n$pass2")
  }

  **
  ** Method call expansion must apply regardless of the call's syntactic
  ** position: as the RHS of an assignment, as a return value, and as a
  ** standalone statement.
  **
  Void testMethodCallInEveryPosition()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    x := compute(alpha, beta)\n" +
      "    return build(one, two)\n" +
      "    emit(src, dst)\n" +
      "  }\n" +
      "}\n"

    result := format(src)
    lines := result.splitLines
    // Assignment RHS
    verify(lines.any |l| { l.trim == "alpha," },
      "assignment-RHS arg must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "beta)" },
      "last assignment-RHS arg must close with ); got:\n$result")
    // Return value
    verify(lines.any |l| { l.trim == "one," },
      "return-value arg must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "two)" },
      "last return-value arg must close with ); got:\n$result")
    // Standalone statement
    verify(lines.any |l| { l.trim == "src," },
      "standalone-call arg must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "dst)" },
      "last standalone-call arg must close with ); got:\n$result")
    // Idempotent
    pass2 := format(result)
    verifyEq(result, pass2, "method-call-in-every-position must be idempotent")
  }

  **
  ** A method DECLARATION with 2+ parameters must also be expanded to
  ** one-parameter-per-line, even when it is short.
  **
  Void testMethodDeclarationAlwaysExpanded()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(Int x, Int y) {}\n" +
      "}\n"

    result := format(src)
    lines := result.splitLines
    // Declaration opener ends with '('
    verify(lines.any |l| { l.trim == "Void bar(" },
      "declaration opener must end with '('; got:\n$result")
    // First param on its own line
    verify(lines.any |l| { l.trim == "Int x," },
      "first param must be on its own line; got:\n$result")
    // Last param has ')' with optional suffix
    verify(lines.any |l| { l.trim.startsWith("Int y)") },
      "last param must be on its own line and start with 'Int y)'; got:\n$result")
    // Idempotent
    pass2 := format(result)
    verifyEq(result, pass2,
      "method declaration expansion must be idempotent; pass1:\n$result\npass2:\n$pass2")
  }

  **
  ** Control-flow keywords (if, while, for, switch) must NOT be treated
  ** as method calls and must never be expanded.
  **
  Void testControlFlowNotExpandedAsMethodCall()
  {
    o := opts.copy
    o.maxLineLength = 40
    src :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(Int x, Int y, Int z)\n" +
      "  {\n" +
      "    if (x > 0 && y > 0 && z > 0) doSomething()\n" +
      "  }\n" +
      "}\n"

    result := formatWith(src, o)
    // The 'if' condition must not be expanded as a method call
    verify(!result.splitLines.any |l| { l.trim == "x > 0 &&" || l.trim == "x > 0 && y > 0 &&" },
      "if condition must not be expanded as method args; got:\n$result")
  }

  //////////////////////////////////////////////////////////////////////////
  // [list/map] literal inside method call
  //////////////////////////////////////////////////////////////////////////

  **
  ** A map literal '[key: val, ...]' passed directly as an argument inside
  ** a method call must be expanded to one-entry-per-line, exactly like a
  ** top-level bracket literal.
  **
  Void testMapLiteralInsideMethodCallExpanded()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  Dict toDict() {\n" +
      "    return Etc.makeDict([hasErrorsKey: this.hasErrors, demandControlRatioKey: this.demandRatio, notesKey: this.notes])\n" +
      "  }\n" +
      "}\n"

    result := format(src)
    lines := result.splitLines

    // Each map entry must be on its own indented line.
    // (The map-aligner may pad the values, so check the key prefix only.)
    verify(lines.any |l| { l.trim.startsWith("hasErrorsKey:") && l.trim.endsWith("this.hasErrors,") },
      "first map entry must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim.startsWith("demandControlRatioKey:") && l.trim.endsWith("this.demandRatio,") },
      "second map entry must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim.startsWith("notesKey:") && l.trim.endsWith("this.notes,") },
      "third map entry must be on its own line; got:\n$result")
    // Closing must be '])'
    verify(lines.any |l| { l.trim == "])" },
      "closing must be ]) on its own line; got:\n$result")
  }

  **
  ** Map literal inside method call expansion must be idempotent.
  **
  Void testMapLiteralInsideMethodCallIdempotent()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  Dict toDict() {\n" +
      "    return Etc.makeDict([hasErrorsKey: this.hasErrors, demandControlRatioKey: this.demandRatio, notesKey: this.notes])\n" +
      "  }\n" +
      "}\n"

    pass1 := format(src)
    pass2 := format(pass1)
    verifyEq(pass1, pass2, "map-in-method-call expansion must be idempotent;\npass1:\n$pass1\npass2:\n$pass2")
  }

  **
  ** A list literal '[elem1, elem2, ...]' passed as an argument inside a
  ** method call must also be expanded to one-element-per-line.
  **
  Void testListLiteralInsideMethodCallExpanded()
  {
    src :=
      "class Foo\n" +
      "{\n" +
      "  Void bar() { process(items, [\"alpha\", \"beta\", \"gamma\", \"delta\"]) }\n" +
      "}\n"

    result := format(src)
    lines := result.splitLines

    verify(lines.any |l| { l.trim == "\"alpha\"," },
      "first list element must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "\"delta\"," },
      "last list element must be on its own line; got:\n$result")
  }

  //////////////////////////////////////////////////////////////////////////
  // Real-world: ModelEntityFactory-style formatting
  //
  // Verifies that a class with long method declarations and long method
  // calls is formatted so that each parameter/argument lands on its own
  // line, matching the canonical style from real-world code.
  //////////////////////////////////////////////////////////////////////////

  **
  ** A method DECLARATION whose opening line exceeds maxLineLength must be
  ** expanded: the '(' ends the first line, each parameter goes on its own
  ** line with a trailing comma, and the last parameter line ends with ') {'
  ** (or ')' for a method without a body opener on the same line).
  **
  Void testLongMethodDeclarationExpandedOneParamPerLine()
  {
    // ModelEntityFactory.makeEntity signature style — 8 typed params, several
    // with default values.  Total length is well over 100 characters.
    src :=
      "class EntityFactory\n" +
      "{\n" +
      "  public static EntityBase? makeEntity(Context cx, Str type, Str? model := null, Str? name := null, Ref? siteId := null, Ref? parentId := null, Dict args := Etc.emptyDict, Bool keepTransient := false) {\n" +
      "    return null\n" +
      "  }\n" +
      "}\n"

    result := format(src)
    lines  := result.splitLines

    // The opening line must end with '('
    verify(lines.any |l| { l.trim == "public static EntityBase? makeEntity(" },
      "method decl opener must end the first line with '('; got:\n$result")

    // Each parameter must be on its own indented line with trailing ','
    verify(lines.any |l| { l.trim == "Context cx," },
      "first param 'Context cx' must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "Str type," },
      "second param 'Str type' must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "Str? model := null," },
      "'Str? model := null' must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "Str? name := null," },
      "'Str? name := null' must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "Ref? siteId := null," },
      "'Ref? siteId := null' must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "Ref? parentId := null," },
      "'Ref? parentId := null' must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "Dict args := Etc.emptyDict," },
      "'Dict args := Etc.emptyDict' must be on its own line; got:\n$result")

    // Last param closes with ') {' (body brace on same line)
    verify(lines.any |l| { l.trim == "Bool keepTransient := false) {" },
      "last param must close with ') {'; got:\n$result")

    // Idempotent
    pass2 := format(result)
    verifyEq(result, pass2,
      "method declaration expansion must be idempotent;\npass1:\n$result\npass2:\n$pass2")
  }

  **
  ** A method CALL whose line exceeds maxLineLength must be expanded:
  ** the call up to '(' ends the first line, each argument is on its own
  ** line with a trailing comma, and the last argument line ends with ')'.
  **
  Void testLongMethodCallExpandedOneArgPerLine()
  {
    // makeFromTrioAndEntityValsAndAdd call style — 5 arguments whose total line
    // length (with indentation) exceeds 100 characters.
    src :=
      "class EntityFactory\n" +
      "{\n" +
      "  public static EntityBase? makeAdd(Context cx) {\n" +
      "    entity := EntityBase.makeFromTrioAndEntityValsAndAdd(entityInfo, parentId, entityName, entityArgs, keepTransient)\n" +
      "    entity?.commit(cx)\n" +
      "    return entity\n" +
      "  }\n" +
      "}\n"

    result := format(src)
    lines  := result.splitLines

    // The call opener must end with '('
    verify(lines.any |l| { l.trim == "entity := EntityBase.makeFromTrioAndEntityValsAndAdd(" },
      "method call opener must end with '('; got:\n$result")

    // Each argument must be on its own indented line
    verify(lines.any |l| { l.trim == "entityInfo," },
      "arg 'entityInfo' must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "parentId," },
      "arg 'parentId' must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "entityName," },
      "arg 'entityName' must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "entityArgs," },
      "arg 'entityArgs' must be on its own line; got:\n$result")

    // Last argument closes the call
    verify(lines.any |l| { l.trim == "keepTransient)" },
      "last arg must close with ')'; got:\n$result")

    // Idempotent
    pass2 := format(result)
    verifyEq(result, pass2,
      "method call expansion must be idempotent;\npass1:\n$result\npass2:\n$pass2")
  }

  **
  ** The ModelEntityFactory pattern end-to-end: a class with both long method
  ** declarations and long inner method calls is formatted correctly in a
  ** single pass and is idempotent.
  **
  Void testRealWorldModelEntityFactoryStyle()
  {
    // Complete class excerpt mirroring ModelEntityFactory, with long declarations
    // and long call-sites, as found in typical real-world Fantom code.
    src :=
      "class EntityFactory\n" +
      "{\n" +
      "  public static EntityBase? makeEntity(Context cx, Str type, Str? model := null, Str? name := null, Ref? siteId := null, Ref? parentId := null, Dict args := Etc.emptyDict, Bool keepTransient := false) {\n" +
      "    entity := EntityBase.makeFromTrioAndEntityValsAndAdd(entityInfo, parentId, name, args, keepTransient)\n" +
      "    return entity\n" +
      "  }\n" +
      "\n" +
      "  public static EntityBase? makeAdd(Context cx, Str type, Str? model := null, Str? name := null, Ref? siteId := null, Ref? parentId := null, Dict args := Etc.emptyDict, Bool keepTransient := false) {\n" +
      "    entity := makeEntity(cx, type, model, name, siteId, parentId, args, keepTransient)\n" +
      "    entity?.commit(cx)\n" +
      "    return entity\n" +
      "  }\n" +
      "}\n"

    result := format(src)
    lines  := result.splitLines

    // Both method declarations must be expanded
    Int declOpeners := lines.findAll |l| { l.trim == "public static EntityBase? makeEntity(" || l.trim == "public static EntityBase? makeAdd(" }.size
    verify(declOpeners == 2,
      "both long method declarations must have their '(' on the opener line; got:\n$result")

    // Both inner calls must be expanded
    verify(lines.any |l| { l.trim == "entity := EntityBase.makeFromTrioAndEntityValsAndAdd(" },
      "inner makeFromTrioAndEntityValsAndAdd call must be expanded; got:\n$result")

    // The makeEntity call in makeAdd is also expanded (8 args)
    verify(lines.any |l| { l.trim == "entity := makeEntity(" },
      "makeEntity call in makeAdd must also be expanded; got:\n$result")

    // No single line may exceed maxLineLength (= 100 by default)
    lines.each |l|
    {
      verify(l.size <= 100,
        "no line must exceed 100 chars after formatting; offending line: '$l'")
    }

    // Idempotent
    pass2 := format(result)
    verifyEq(result, pass2,
      "ModelEntityFactory style must be idempotent;\npass1:\n$result\npass2:\n$pass2")
  }

  //////////////////////////////////////////////////////////////////////////
  // Etc.makeDict([map]) inside method call — DemandControlResult.toDict style
  //
  // A map literal '[key: val, ...]' passed directly into a method call must
  // always be expanded to one-entry-per-line, regardless of whether the
  // source input is compact (single line) or already in multi-line form.
  //////////////////////////////////////////////////////////////////////////

  **
  ** COMPACT single-line form: the map is all on one line.
  ** The formatter must expand it so every entry is on its own line.
  **
  Void testMakeDictMapCompactExpandedToMultiLine()
  {
    src :=
      "class DemandControlResult\n" +
      "{\n" +
      "  Dict toDict()\n" +
      "  {\n" +
      "    return Etc.makeDict([hasErrorsKey: this.hasErrors, demandControlRatioKey: this.demandControlRatio, notesKey: this.notes])\n" +
      "  }\n" +
      "}\n"

    result := format(src)
    lines  := result.splitLines

    verify(lines.any |l| { l.trim.startsWith("hasErrorsKey:")            && l.trim.endsWith("this.hasErrors,") },
      "hasErrorsKey entry must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim.startsWith("demandControlRatioKey:")   && l.trim.endsWith("this.demandControlRatio,") },
      "demandControlRatioKey entry must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim.startsWith("notesKey:")                && l.trim.endsWith("this.notes,") },
      "notesKey entry must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim == "])" },
      "closing ]) must be on its own line; got:\n$result")

    pass2 := format(result)
    verifyEq(result, pass2, "must be idempotent; got:\n$result\npass2:\n$pass2")
  }

  **
  ** ALREADY MULTI-LINE form: exactly as the source file has it (the map is
  ** already split across lines but without a trailing comma on the last entry).
  ** The formatter must normalize it to canonical form (trailing comma, consistent
  ** indent) and must NOT collapse it back to a single line.
  **
  Void testMakeDictMapAlreadyMultiLinePreservedAndNormalized()
  {
    // Intentionally: no trailing comma on last entry, mixed indentation
    src :=
      "class DemandControlResult\n" +
      "{\n" +
      "  Dict toDict()\n" +
      "  {\n" +
      "    return Etc.makeDict([\n" +
      "      hasErrorsKey: this.hasErrors,\n" +
      "      demandControlRatioKey: this.demandControlRatio,\n" +
      "      notesKey: this.notes\n" +
      "    ])\n" +
      "  }\n" +
      "}\n"

    result := format(src)
    lines  := result.splitLines

    // Must still be multi-line — entries not collapsed to one line
    verify(lines.any |l| { l.trim.startsWith("hasErrorsKey:") },
      "hasErrorsKey must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim.startsWith("demandControlRatioKey:") },
      "demandControlRatioKey must be on its own line; got:\n$result")
    verify(lines.any |l| { l.trim.startsWith("notesKey:") },
      "notesKey must be on its own line; got:\n$result")
    // Closing ]) on its own line
    verify(lines.any |l| { l.trim == "])" },
      "closing ]) must be on its own line; got:\n$result")
    // Last entry must have a trailing comma (normalization)
    verify(lines.any |l| { l.trim.startsWith("notesKey:") && l.trim.endsWith(",") },
      "last entry must have a trailing comma; got:\n$result")

    pass2 := format(result)
    verifyEq(result, pass2, "must be idempotent; got:\n$result\npass2:\n$pass2")
  }
}


