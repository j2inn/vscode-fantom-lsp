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

  Void testScanMemberCtorInferenceCrossFile()
  {
    // Cross-file ctor inference: svc := Svc() where Svc is in a different file
    mainUri := "file:///Main.fan"
    main :=
      "class Main {\n" +
      "  Void run() {\n" +
      "    svc := Svc()\n" +
      "    svc.stop()\n" +
      "  }\n" +
      "}\n"
    idx := ProjectIndex()
    idx.indexFile("file:///Svc.fan", "class Svc { Void stop() {} }\n")
    idx.indexFile(mainUri, main)

    family := ["Svc"]
    t := ReferencesTarget.forMember("stop", "Svc", family)
    locs := s.scan(mainUri, main, t, idx)
    verify(locs.any |l| { lineOf([l]) == 3 },
      "svc.stop() via ctor-inferred type must be found, got: $locs.size results")
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

  Void testScanMemberBareCallAfterDot()
  {
    // cx() first arg of a static call: "Foo.bar(cx, x)"
    // Old bug: the dot in "Foo." caused cx to be excluded entirely.
    source :=
      "class A {\n" +
      "  static Context cx() { Context.cur }\n" +
      "  static Void test() { Foo.bar(cx, x) }\n" +
      "}\n"
    family := ["A"]
    t := ReferencesTarget.forMember("cx", "A", family)
    locs := scan(source, t)
    verify(locs.any |l| { lineOf([l]) == 1 }, "Declaration must be found")
    verify(locs.any |l| { lineOf([l]) == 2 }, "Bare call cx after Foo. must be found")
  }

  Void testScanMemberBareCallOnlyArg()
  {
    // cx() sole argument: "Util.clear(cx)"
    source :=
      "class A {\n" +
      "  static Context cx() { Context.cur }\n" +
      "  static Void test() { Util.clear(cx) }\n" +
      "}\n"
    family := ["A"]
    t := ReferencesTarget.forMember("cx", "A", family)
    locs := scan(source, t)
    verify(locs.any |l| { lineOf([l]) == 2 }, "cx sole arg must be found")
  }

  Void testScanMemberBareCallSecondArgChained()
  {
    // cx() second arg in a constructor call, result immediately chained:
    // "Service(logger, cx).run(sectionId)"
    source :=
      "class A {\n" +
      "  static Context cx() { Context.cur }\n" +
      "  static Void test() { Service(logger, cx).run(sectionId) }\n" +
      "}\n"
    family := ["A"]
    t := ReferencesTarget.forMember("cx", "A", family)
    locs := scan(source, t)
    verify(locs.any |l| { lineOf([l]) == 2 }, "cx as second arg in chained ctor must be found")
  }

  Void testScanMemberBareCallAsReceiver()
  {
    // cx() used as receiver of a property chain: "cx.proj.dir"
    source :=
      "class A {\n" +
      "  static Context cx() { Context.cur }\n" +
      "  static Void test() { uri := cx.proj.dir.uri }\n" +
      "}\n"
    family := ["A"]
    t := ReferencesTarget.forMember("cx", "A", family)
    locs := scan(source, t)
    verify(locs.any |l| { lineOf([l]) == 2 }, "cx as receiver of property chain must be found")
  }

  Void testScanMemberBareCallMultipleUsagesOnDifferentLines()
  {
    // Multiple bare cx() calls spread across multiple method bodies —
    // all must be found. Mirrors IntelliplantNACoreLib.fan real-world usage.
    source :=
      "class A {\n" +
      "  static Context cx() { Context.cur }\n" +
      "  static Void m1() { Foo.bar(cx, true) }\n" +
      "  static Void m2() { Service(logger, cx).run() }\n" +
      "  static Void m3() { Util.go(cx) }\n" +
      "}\n"
    family := ["A"]
    t := ReferencesTarget.forMember("cx", "A", family)
    locs := scan(source, t)
    verify(locs.any |l| { lineOf([l]) == 2 }, "cx in m1 must be found")
    verify(locs.any |l| { lineOf([l]) == 3 }, "cx in m2 must be found")
    verify(locs.any |l| { lineOf([l]) == 4 }, "cx in m3 must be found")
  }

  Void testScanLocalStaticCallDoesNotBreakMethodBoundary()
  {
    // Regression: "SysLib.recTrash(entities)" was wrongly detected as a method
    // declaration boundary. scanLocal now uses AST-derived method bounds from the
    // index instead of heuristic text detection, so this is no longer fragile.
    // All 4 occurrences of 'entities' must be found (decl + isEmpty + recTrash + size).
    source :=
      "class A {\n" +
      "  static Number clear(Context cx) {\n" +
      "    entities := cx.proj.readAll(\"tag\")\n" +
      "    if (entities.isEmpty) { return Number.zero }\n" +
      "    SysLib.recTrash(entities)\n" +
      "    return Number(entities.size)\n" +
      "  }\n" +
      "}\n"
    idx := ProjectIndex()
    idx.indexFile(uri, source)
    t := ReferencesTarget.forLocal("entities", "clear", uri)
    locs := s.scan(uri, source, t, idx)
    verifyEq(locs.size, 4, "All 4 occurrences of 'entities' must be found, got: $locs.size")
    verify(locs.any |l| { lineOf([l]) == 2 }, "declaration on line 2 must be found")
    verify(locs.any |l| { lineOf([l]) == 3 }, "entities.isEmpty on line 3 must be found")
    verify(locs.any |l| { lineOf([l]) == 4 }, "SysLib.recTrash(entities) on line 4 must be found")
    verify(locs.any |l| { lineOf([l]) == 5 }, "entities.size on line 5 must be found")
  }

  Void testScanLocalScopedToMethodOnly()
  {
    // 'x' exists in two methods — only the one in the target method must be returned
    source :=
      "class A {\n" +
      "  Void first() { x := 1 }\n" +
      "  Void second() { x := 2 }\n" +
      "}\n"
    idx := ProjectIndex()
    idx.indexFile(uri, source)
    t := ReferencesTarget.forLocal("x", "first", uri)
    locs := s.scan(uri, source, t, idx)
    verifyEq(locs.size, 1, "Only x in first() must be found")
    verify(locs.any |l| { lineOf([l]) == 1 })
  }

//////////////////////////////////////////////////////////////////////////
// Implementations
//////////////////////////////////////////////////////////////////////////


//////////////////////////////////////////////////////////////////////////
// Member scanning — multi-hierarchy isolation (real-world pattern)
//////////////////////////////////////////////////////////////////////////

  Void testScanMemberFamilyIsolatesUnrelatedClass()
  {
    // Two unrelated classes both have a field named 'tag'.
    // Scanning for Widget.tag (family = ["Widget"]) must not include Panel.tag.
    // Mirrors the real-world pattern where many independent classes share
    // a private 'className' or 'logger' field.
    source :=
      "class Widget {\n" +                     // line 0
      "  const Str tag := \"widget\"\n" +       // line 1: tag decl
      "  Void render() { echo(tag) }\n" +       // line 2: bare call
      "}\n" +                                   // line 3
      "class Panel {\n" +                       // line 4
      "  const Str tag := \"panel\"\n" +         // line 5: tag decl (must NOT be found)
      "  Void show() { echo(tag) }\n" +          // line 6: bare call (must NOT be found)
      "}\n"
    family := ["Widget"]
    t := ReferencesTarget.forMember("tag", "Widget", family)
    locs := scan(source, t)
    lines := locs.map |l| { lineOf([l]) }
    verify(lines.contains(1), "Widget.tag declaration must be found")
    verify(lines.contains(2), "Widget.tag bare call in render() must be found")
    verify(!lines.contains(5), "Panel.tag declaration must NOT be found")
    verify(!lines.contains(6), "Panel.tag bare call in show() must NOT be found")
  }

//////////////////////////////////////////////////////////////////////////
// Member scanning — private helper called from multiple methods
//////////////////////////////////////////////////////////////////////////

  Void testScanMemberBareCallFromMultipleMethods()
  {
    // A private helper called as a bare name from several methods in the same class.
    // Mirrors the real-world pattern of utility helpers like flush(), applyConfig(),
    // or updateSettings() called throughout a service class.
    source :=
      "class Worker {\n" +                          // line 0
      "  private Void flush() {}\n" +               // line 1: decl
      "  Void step1() { flush() }\n" +              // line 2: bare call
      "  Void step2() { flush() }\n" +              // line 3: bare call
      "  Void step3() { flush() }\n" +              // line 4: bare call
      "}\n"
    family := ["Worker"]
    t := ReferencesTarget.forMember("flush", "Worker", family)
    locs := scan(source, t)
    verify(locs.any |l| { lineOf([l]) == 1 }, "Declaration must be found")
    verify(locs.any |l| { lineOf([l]) == 2 }, "Bare call in step1() must be found")
    verify(locs.any |l| { lineOf([l]) == 3 }, "Bare call in step2() must be found")
    verify(locs.any |l| { lineOf([l]) == 4 }, "Bare call in step3() must be found")
  }

//////////////////////////////////////////////////////////////////////////
// Member scanning — same helper name in two unrelated classes, both called bare
//////////////////////////////////////////////////////////////////////////

  Void testScanMemberBareCallTwoClassesSameName()
  {
    // Both classes have a private helper named 'commit()'.
    // Scanning for Store.commit must not find Cache.commit.
    // This is the worst case for bare-call detection: same name, same calling style,
    // different owning class.
    source :=
      "class Store {\n" +                       // line 0
      "  private Void commit() {}\n" +          // line 1: Store.commit decl
      "  Void save(Dict d) { commit() }\n" +    // line 2: bare call inside Store
      "}\n" +                                   // line 3
      "class Cache {\n" +                       // line 4
      "  private Void commit() {}\n" +          // line 5: Cache.commit (must NOT match)
      "  Void put(Dict d) { commit() }\n" +     // line 6: bare call inside Cache (must NOT match)
      "}\n"
    family := ["Store"]
    t := ReferencesTarget.forMember("commit", "Store", family)
    locs := scan(source, t)
    lines := locs.map |l| { lineOf([l]) }
    verify(lines.contains(1), "Store.commit declaration must be found")
    verify(lines.contains(2), "Store.commit call in save() must be found")
    verify(!lines.contains(5), "Cache.commit declaration must NOT be found")
    verify(!lines.contains(6), "Cache.commit call in put() must NOT be found")
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
