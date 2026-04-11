**
** ReferencesServiceTest - Integration tests for ReferencesService.
** Uses a real ProjectIndex populated via indexFile() so symbol
** resolution and source scanning work end-to-end.
**
class ReferencesServiceTest : Test
{
  private ReferencesService svc := ReferencesService()

  private Int? lineOf([Str:Obj?] loc)
  {
    try
    {
      r := loc["range"] as Str:Obj?
      if (r == null) return null
      start := r["start"] as Str:Obj?
      if (start == null) return null
      return start["line"] as Int
    }
    catch (Err e) { return null }
  }

  private Str? uriOf([Str:Obj?] loc) { loc["uri"] as Str }

  private ProjectIndex makeIndex([Str:Str] files)
  {
    idx := ProjectIndex()
    files.each |src, uri| { idx.indexFile(uri, src) }
    return idx
  }

  private LspPosition pos(Int line, Int ch) {
    LspPosition(line, ch)
  }

//////////////////////////////////////////////////////////////////////////
// Find References — type
//////////////////////////////////////////////////////////////////////////

  Void testFindRefsType()
  {
    a := "class Alpha {}\n"
    b := "class Beta { Alpha x := Alpha() }\n"
    idx := makeIndex(["file:///A.fan": a, "file:///B.fan": b])

    locs := svc.findReferences("file:///B.fan", pos(0, 15), b, idx, true)
    verify(locs.size >= 1, "Should find at least one reference to Alpha")
    verify(locs.any |l| { uriOf(l) == "file:///B.fan" })
  }

  Void testFindRefsTypeExcludesDecl()
  {
    a := "class Alpha {}\n"
    b := "class Beta { Alpha x := Alpha() }\n"
    idx := makeIndex(["file:///A.fan": a, "file:///B.fan": b])

    withDecl    := svc.findReferences("file:///A.fan", pos(0, 6), a, idx, true)
    withoutDecl := svc.findReferences("file:///A.fan", pos(0, 6), a, idx, false)
    verify(withDecl.size >= withoutDecl.size,
      "includeDeclaration=true must return >= results")
  }

//////////////////////////////////////////////////////////////////////////
// Find References — member
//////////////////////////////////////////////////////////////////////////

  Void testFindRefsMemberStaticCall()
  {
    a := "class Cfg { static Str host := \"localhost\" }\n"
    b := "class App { Str h() { return Cfg.host } }\n"
    idx := makeIndex(["file:///Cfg.fan": a, "file:///App.fan": b])

    locs := svc.findReferences("file:///Cfg.fan", pos(0, 22), a, idx, false)
    verify(locs.any |l| { uriOf(l) == "file:///App.fan" },
      "Static field reference in App.fan must be found")
  }

  Void testFindRefsMemberAnnotatedReceiver()
  {
    a := "class Svc { Void start() {} }\n"
    b :=
      "class Main {\n" +
      "  Void run() {\n" +
      "    Svc svc := Svc()\n" +
      "    svc.start()\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Svc.fan": a, "file:///Main.fan": b])

    locs := svc.findReferences("file:///Svc.fan", pos(0, 17), a, idx, false)
    verify(locs.any |l| { uriOf(l) == "file:///Main.fan" && lineOf(l) == 3 },
      "start() call via annotated receiver must be found")
  }

  Void testFindRefsMemberCtorInference()
  {
    a := "class Svc { Void stop() {} }\n"
    b :=
      "class Main {\n" +
      "  Void run() {\n" +
      "    svc := Svc()\n" +
      "    svc.stop()\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Svc.fan": a, "file:///Main.fan": b])

    locs := svc.findReferences("file:///Svc.fan", pos(0, 17), a, idx, false)
    verify(locs.any |l| { uriOf(l) == "file:///Main.fan" && lineOf(l) == 3 },
      "stop() call via ctor-inferred type must be found")
  }

  Void testFindRefsNoFalsePositive()
  {
    a := "class A { Void run() {} }\n"
    b := "class B { Void run() {} }\n"
    c := "class C { Void test() { B b := B(); b.run() } }\n"
    idx := makeIndex(["file:///A.fan": a, "file:///B.fan": b, "file:///C.fan": c])

    // References to A.run — must NOT include the B.run call in C
    locs := svc.findReferences("file:///A.fan", pos(0, 17), a, idx, false)
    verify(!locs.any |l| { uriOf(l) == "file:///C.fan" },
      "B.run() call must not appear as reference to A.run()")
  }

//////////////////////////////////////////////////////////////////////////
// Find Implementations — type
//////////////////////////////////////////////////////////////////////////

  Void testFindImplType()
  {
    base := "class IAnimal {}\n"
    dog  := "class Dog : IAnimal {}\n"
    cat  := "class Cat : IAnimal {}\n"
    idx  := makeIndex(["file:///IAnimal.fan": base, "file:///Dog.fan": dog, "file:///Cat.fan": cat])

    locs := svc.findImplementations("file:///IAnimal.fan", pos(0, 6), base, idx)
    verifyEq(locs.size, 2, "Dog and Cat must appear as implementations")
    uris := locs.map |l| { uriOf(l) }
    verify(uris.contains("file:///Dog.fan"))
    verify(uris.contains("file:///Cat.fan"))
  }

  Void testFindImplTypeNoResults()
  {
    base := "class Leaf {}\n"
    idx  := makeIndex(["file:///Leaf.fan": base])
    locs := svc.findImplementations("file:///Leaf.fan", pos(0, 6), base, idx)
    verifyEq(locs.size, 0)
  }

  Void testFindImplMixin()
  {
    base := "mixin IRunnable {}\n"
    impl := "class Runner : IRunnable {}\n"
    idx  := makeIndex(["file:///IRunnable.fan": base, "file:///Runner.fan": impl])

    locs := svc.findImplementations("file:///IRunnable.fan", pos(0, 6), base, idx)
    verifyEq(locs.size, 1)
    verifyEq(uriOf(locs[0]), "file:///Runner.fan")
  }

//////////////////////////////////////////////////////////////////////////
// Find Implementations — method overrides
//////////////////////////////////////////////////////////////////////////

  Void testFindImplMethodOverride()
  {
    base  := "class Base { virtual Void draw() {} }\n"
    childA :=
      "class ChildA : Base {\n" +
      "  override Void draw() {}\n" +
      "}\n"
    childB :=
      "class ChildB : Base {\n" +
      "  override Void draw() {}\n" +
      "}\n"
    idx := makeIndex([
      "file:///Base.fan":   base,
      "file:///ChildA.fan": childA,
      "file:///ChildB.fan": childB,
    ])

    locs := svc.findImplementations("file:///Base.fan", pos(0, 26), base, idx)
    verifyEq(locs.size, 2, "Both ChildA and ChildB must override draw()")
    uris := locs.map |l| { uriOf(l) }
    verify(uris.contains("file:///ChildA.fan"))
    verify(uris.contains("file:///ChildB.fan"))
  }

  Void testFindImplMethodNoOverride()
  {
    base   := "class Base { virtual Void tick() {} }\n"
    child  := "class Child : Base {}\n"
    idx := makeIndex(["file:///Base.fan": base, "file:///Child.fan": child])

    locs := svc.findImplementations("file:///Base.fan", pos(0, 25), base, idx)
    verifyEq(locs.size, 0, "Child does not override tick(), so no results")
  }

  Void testFindImplMethodOverrideChain()
  {
    // 3-level chain: Base -> Child -> GrandChild, all override draw()
    base :=
      "class Base {\n" +
      "  virtual Void draw() {}\n" +
      "}\n"
    child :=
      "class Child : Base {\n" +
      "  override Void draw() {}\n" +
      "}\n"
    grand :=
      "class GrandChild : Child {\n" +
      "  override Void draw() {}\n" +
      "}\n"
    idx := makeIndex([
      "file:///Base.fan":       base,
      "file:///Child.fan":      child,
      "file:///GrandChild.fan": grand,
    ])
    // "  virtual Void draw() {}" — 'd' of draw at col 15
    locs := svc.findImplementations("file:///Base.fan", pos(1, 15), base, idx)
    verifyEq(locs.size, 2, "Child and GrandChild must both be found")
    uris := locs.map |l| { uriOf(l) }
    verify(uris.contains("file:///Child.fan"))
    verify(uris.contains("file:///GrandChild.fan"))
  }

//////////////////////////////////////////////////////////////////////////
// Find Implementations — mixin method
//////////////////////////////////////////////////////////////////////////

  Void testFindImplMixinMethod()
  {
    iwork :=
      "mixin IWork {\n" +
      "  Void doWork() {}\n" +
      "}\n"
    impl :=
      "class Worker : IWork {\n" +
      "  override Void doWork() {}\n" +
      "}\n"
    idx := makeIndex(["file:///IWork.fan": iwork, "file:///Worker.fan": impl])
    // "  Void doWork() {}" — 'd' of doWork at col 7
    locs := svc.findImplementations("file:///IWork.fan", pos(1, 7), iwork, idx)
    verifyEq(locs.size, 1, "Worker must override IWork.doWork")
    verifyEq(uriOf(locs[0]), "file:///Worker.fan")
  }

//////////////////////////////////////////////////////////////////////////
// Find References — multi-level type family
//////////////////////////////////////////////////////////////////////////

  Void testFindRefsMultiLevelFamily()
  {
    // A -> B : A -> C : B  —  C is a transitive subtype of A
    a :=
      "class A {\n" +
      "  Void go() {}\n" +
      "}\n"
    b := "class B : A {}\n"
    c := "class C : B {}\n"
    client :=
      "class Client {\n" +
      "  Void test() {\n" +
      "    C obj := C()\n" +
      "    obj.go()\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex([
      "file:///A.fan":      a,
      "file:///B.fan":      b,
      "file:///C.fan":      c,
      "file:///Client.fan": client,
    ])
    // "  Void go() {}" — 'g' of go at col 7
    locs := svc.findReferences("file:///A.fan", pos(1, 7), a, idx, false)
    verify(locs.any |l| { uriOf(l) == "file:///Client.fan" },
      "C-typed receiver (C is transitive subtype of A) must be found")
  }

  Void testFindRefsIsolatedHierarchyExcluded()
  {
    // A and D are unrelated hierarchies — D-typed calls must not appear in A.run refs
    a :=
      "class A {\n" +
      "  Void run() {}\n" +
      "}\n"
    d :=
      "class D {\n" +
      "  Void run() {}\n" +
      "}\n"
    e := "class E : D {}\n"
    usage :=
      "class Client {\n" +
      "  Void test() {\n" +
      "    E e := E()\n" +
      "    e.run()\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex([
      "file:///A.fan":      a,
      "file:///D.fan":      d,
      "file:///E.fan":      e,
      "file:///Client.fan": usage,
    ])
    // "  Void run() {}" — 'r' of run at col 7
    locs := svc.findReferences("file:///A.fan", pos(1, 7), a, idx, false)
    verify(!locs.any |l| { uriOf(l) == "file:///Client.fan" },
      "E-typed receiver (E : D, unrelated to A) must not appear in A.run refs")
  }
}
