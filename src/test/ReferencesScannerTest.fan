**
** ReferencesScannerTest - Unit tests for ReferencesScanner.
**
class ReferencesScannerTest : Test
{
  private ReferencesScanner s := ReferencesScanner()

  private Str uri() { "file:///test/Foo.fan" }

  private [Str:Obj?][] scan(Str source, ReferencesTarget t) {
    s.scan(uri, source, t)
  }

  private Int? lineOf([Str:Obj?][] locs, Int n := 0)
  {
    if (locs.size <= n) return null
    try
    {
      r := locs[n]["range"] as Str:Obj?
      if (r == null) return null
      start := r["start"] as Str:Obj?
      if (start == null) return null
      return start["line"] as Int
    }
    catch (Err e) { return null }
  }

//////////////////////////////////////////////////////////////////////////
// resolveVarTypes
//////////////////////////////////////////////////////////////////////////

  Void testResolveVarTypesExplicit()
  {
    lines := ["  Foo x := Foo()"]
    types := s.resolveVarTypes(lines)
    verifyEq(types["x"], "Foo")
  }

  Void testResolveVarTypesCtor()
  {
    lines := ["  x := Bar()"]
    types := s.resolveVarTypes(lines)
    verifyEq(types["x"], "Bar")
  }

  Void testResolveVarTypesNullable()
  {
    lines := ["  Foo? x := null"]
    types := s.resolveVarTypes(lines)
    verifyEq(types["x"], "Foo")
  }

  Void testResolveVarTypesIgnoresNoType()
  {
    lines := ["  x := someMethod()"]
    types := s.resolveVarTypes(lines)
    verify(!types.containsKey("x"))
  }

//////////////////////////////////////////////////////////////////////////
// Type scanning
//////////////////////////////////////////////////////////////////////////

  Void testScanTypeFindsUsage()
  {
    source := "class A {}\nclass B : A {}\nVoid foo(A a) {}"
    t := ReferencesTarget.forType("A")
    locs := scan(source, t)
    verify(locs.size >= 2)
  }

  Void testScanTypeSkipsStringLiteral()
  {
    source := "class A {}\nStr s := \"A is great\"\n"
    t := ReferencesTarget.forType("A")
    locs := scan(source, t)
    // Only the class declaration itself — the string must be skipped
    lines := locs.map |l| { lineOf([l]) }
    verify(!lines.contains(1), "String literal must not be a reference")
  }

  Void testScanTypeSkipsLineComment()
  {
    source := "class A {}\n// A is used here\nVoid foo(A a) {}\n"
    t := ReferencesTarget.forType("A")
    locs := scan(source, t)
    lines := locs.map |l| { lineOf([l]) }
    verify(!lines.contains(1), "Comment must not be a reference")
  }

  Void testScanTypeNoFalseSubstring()
  {
    source := "class Alpha {}\nclass A {}\n"
    t := ReferencesTarget.forType("A")
    locs := scan(source, t)
    // "Alpha" must not match "A"
    lines := locs.map |l| { lineOf([l]) }
    verify(!lines.contains(0), "'Alpha' must not match target 'A'")
  }

//////////////////////////////////////////////////////////////////////////
// Member scanning — static access
//////////////////////////////////////////////////////////////////////////

  Void testScanMemberStaticExact()
  {
    // Two separate lines: declaration on line 0, static usage on line 1
    source :=
      "class A\n" +
      "{\n" +
      "  static Str v := \"x\"\n" +
      "}\n" +
      "x := A.v\n"
    family := ["A"]
    t := ReferencesTarget.forMember("v", "A", family)
    locs := scan(source, t)
    verify(locs.size >= 1)
    // line 4 (the A.v usage) must be among the results
    verify(locs.any |l| { lineOf([l]) == 4 }, "A.v on line 4 must be found")
  }

  Void testScanMemberStaticWrongType()
  {
    source := "x := B.v\n"
    family := ["A"]
    t := ReferencesTarget.forMember("v", "A", family)
    locs := scan(source, t)
    verifyEq(locs.size, 0, "B.v must not match family {A}")
  }

//////////////////////////////////////////////////////////////////////////
// Member scanning — annotated receiver
//////////////////////////////////////////////////////////////////////////

  Void testScanMemberAnnotatedReceiver()
  {
    source :=
      "class A { Void run() {} }\n" +
      "Void test() {\n" +
      "  A obj := A()\n" +
      "  obj.run()\n" +
      "}\n"
    family := ["A"]
    t := ReferencesTarget.forMember("run", "A", family)
    locs := scan(source, t)
    verify(locs.any |l| { lineOf([l]) == 3 })
  }

  Void testScanMemberAnnotatedWrongType()
  {
    source :=
      "Void test() {\n" +
      "  B obj := B()\n" +
      "  obj.run()\n" +
      "}\n"
    family := ["A"]
    t := ReferencesTarget.forMember("run", "A", family)
    locs := scan(source, t)
    verifyEq(locs.size, 0, "B receiver must not match family {A}")
  }

//////////////////////////////////////////////////////////////////////////
// Member scanning — ctor inference
//////////////////////////////////////////////////////////////////////////

  Void testScanMemberCtorInference()
  {
    source :=
      "class A { Void go() {} }\n" +
      "Void test() {\n" +
      "  a := A()\n" +
      "  a.go()\n" +
      "}\n"
    family := ["A"]
    t := ReferencesTarget.forMember("go", "A", family)
    locs := scan(source, t)
    verify(locs.any |l| { lineOf([l]) == 3 })
  }

//////////////////////////////////////////////////////////////////////////
// Member scanning — no family (include all)
//////////////////////////////////////////////////////////////////////////

  Void testScanMemberNoFamilyIncludesAll()
  {
    source := "a.run()\nb.run()\n"
    t := ReferencesTarget.forMember("run", null, Str[,])
    locs := scan(source, t)
    verifyEq(locs.size, 2)
  }

//////////////////////////////////////////////////////////////////////////
// Implementations
//////////////////////////////////////////////////////////////////////////

  Void testScanImplementationsDirectExtend()
  {
    source := "class Foo : Bar {}\n"
    locs := s.scanImplementations(uri, source, "Bar")
    verifyEq(locs.size, 1)
    verifyEq(lineOf(locs), 0)
  }

  Void testScanImplementationsMultiBases()
  {
    source := "class Foo : Bar, Baz {}\n"
    locs := s.scanImplementations(uri, source, "Bar")
    verifyEq(locs.size, 1)
    locs2 := s.scanImplementations(uri, source, "Baz")
    verifyEq(locs2.size, 1)
  }

  Void testScanImplementationsMixinExtend()
  {
    source := "mixin MFoo : IBase {}\n"
    locs := s.scanImplementations(uri, source, "IBase")
    verifyEq(locs.size, 1)
  }

  Void testScanImplementationsNoMatch()
  {
    source := "class Foo {}\n"
    locs := s.scanImplementations(uri, source, "Bar")
    verifyEq(locs.size, 0)
  }

  Void testScanImplementationsPointsToSubclass()
  {
    source := "class Child : Parent {}\n"
    locs := s.scanImplementations(uri, source, "Parent")
    verifyEq(locs.size, 1)
    r := locs[0]["range"] as Str:Obj?
    if (r == null) { fail("range missing"); return }
    start := r["start"] as Str:Obj?
    if (start == null) { fail("start missing"); return }
    col := start["character"] as Int
    // col should point to "Child", not "Parent"
    verify(col != null && col < 10)
  }
}
