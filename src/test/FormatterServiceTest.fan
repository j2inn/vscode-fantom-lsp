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
}
