**
** SourceMaskTest — unit tests for SourceMask.
**
class SourceMaskTest : Test
{
  Void testMaskKeepsSize()
  {
    src := "x := \"a,b\" // note\ny := `foo.txt` + 'c'\n/* multi\nline */ z"
    verifyEq(SourceMask.mask(src).size, src.size)
  }

  Void testMaskBlanksStringContentsKeepsDelimiters()
  {
    verifyEq(SourceMask.mask("f(\"a,b\")"), "f(\"   \")")
  }

  Void testMaskBlanksBacktickAndCharLiterals()
  {
    verifyEq(SourceMask.mask("a := `Foo.txt`"), "a := `       `")
    verifyEq(SourceMask.mask("c := '{'"), "c := ' '")
  }

  Void testMaskBlanksLineComment()
  {
    verifyEq(SourceMask.mask("a := 1 // Foo.bar\nb"), "a := 1 " + Str.spaces(10) + "\nb")
  }

  Void testMaskBlanksBlockCommentKeepsNewlines()
  {
    verifyEq(SourceMask.mask("a /* x.y\nz */ b"), "a " + Str.spaces(6) + "\n" + Str.spaces(4) + " b")
  }

  Void testMaskMultiLineString()
  {
    verifyEq(SourceMask.mask("s := \"Foo.bar\nBaz.qux\" + x"), "s := \"       \n       \" + x")
  }

  Void testMaskTripleQuotedString()
  {
    verifyEq(SourceMask.mask("s := \"\"\"A.b\"\"\""), "s := \"\"\"   \"\"\"")
  }

  Void testMaskUnterminatedStringBlanksToEnd()
  {
    verifyEq(SourceMask.mask("s := \"Foo.bar"), "s := \"       ")
  }

  Void testMaskLeavesCodeUntouched()
  {
    src := "static Void run() { Main.findMods }"
    verifyEq(SourceMask.mask(src), src)
  }
}
