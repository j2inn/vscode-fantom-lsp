**
** ItBlockTrackerTest — unit tests for ItBlockTracker.
**
class ItBlockTrackerTest : Test
{
  private Bool at(Str line, Str word)
  {
    ItBlockTracker().scan(line)[line.index(word)]
  }

  Void testSameLineItBlockAfterCall()
  {
    verify(at("x := Foo(1) { name = n }", "name"))
  }

  Void testSameLineItBlockAfterTypeName()
  {
    verify(at("x := Foo { name = n }", "name"))
  }

  Void testPlainStatementIsNotItBlock()
  {
    verifyFalse(at("name = n", "name"))
  }

  Void testIfBlockIsNotItBlock()
  {
    verifyFalse(at("if (x) { name = n }", "name"))
  }

  Void testClosureIsNotItBlock()
  {
    verifyFalse(at("list.each |x| { name = n }", "name"))
  }

  Void testMethodDeclarationBodyIsNotItBlock()
  {
    verifyFalse(at("static Void bar(Str x) { name = x }", "name"))
  }

  Void testNullableReturnDeclarationBodyIsNotItBlock()
  {
    verifyFalse(at("static Str? bar() { name = x }", "name"))
  }

  Void testItBlockStateCarriesAcrossLines()
  {
    t := ItBlockTracker()
    t.scan("x := Foo {")
    verify(t.scan("  name = n")[2])
    t.scan("}")
    verifyFalse(t.scan("name = n")[0])
  }

  Void testAllmanMethodBodyIsNotItBlock()
  {
    t := ItBlockTracker()
    t.scan("static Void bar()")
    t.scan("{")
    verifyFalse(t.scan("  name = n")[2])
  }

  Void testCallWithoutBlockLeavesNoState()
  {
    t := ItBlockTracker()
    t.scan("x := Foo(a, b)")
    verifyFalse(t.scan("name = n")[0])
  }
}
