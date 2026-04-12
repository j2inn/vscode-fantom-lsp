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

//////////////////////////////////////////////////////////////////////////
// Find Implementations — deep mixin hierarchy (real-world pattern)
//////////////////////////////////////////////////////////////////////////

  Void testFindImplThreeLevelMixinHierarchy()
  {
    // Mirrors a real-world pattern: a root mixin implemented by an abstract class,
    // which is then extended by multiple concrete classes, plus a direct branch.
    //
    //   mixin IShape
    //     Shape : IShape            (level 2 — abstract implementation)
    //       ColorShape : Shape       (level 3)
    //         RedShape : ColorShape  (level 4)
    //         BlueShape : ColorShape (level 4)
    //       GrayShape : Shape        (level 3, different branch)
    //
    // findImplementations on IShape.draw must cover all 5 overrides.
    ibase :=
      "mixin IShape { abstract Void draw() }\n"
    base :=
      "class Shape : IShape {\n" +
      "  override Void draw() {}\n" +
      "}\n"
    mid :=
      "class ColorShape : Shape {\n" +
      "  override Void draw() {}\n" +
      "}\n"
    leafA :=
      "class RedShape : ColorShape {\n" +
      "  override Void draw() {}\n" +
      "}\n"
    leafB :=
      "class BlueShape : ColorShape {\n" +
      "  override Void draw() {}\n" +
      "}\n"
    leafC :=
      "class GrayShape : Shape {\n" +
      "  override Void draw() {}\n" +
      "}\n"
    idx := makeIndex([
      "file:///IShape.fan":     ibase,
      "file:///Shape.fan":      base,
      "file:///ColorShape.fan": mid,
      "file:///RedShape.fan":   leafA,
      "file:///BlueShape.fan":  leafB,
      "file:///GrayShape.fan":  leafC,
    ])
    // "mixin IShape { abstract Void draw() }"
    // 'd' of 'draw' at col 29
    locs := svc.findImplementations("file:///IShape.fan", pos(0, 29), ibase, idx)
    verifyEq(locs.size, 5, "All 5 overrides across 4 levels must be found, got: $locs.size")
    uris := locs.map |l| { uriOf(l) }
    verify(uris.contains("file:///Shape.fan"),      "Shape.draw must be found")
    verify(uris.contains("file:///ColorShape.fan"),  "ColorShape.draw must be found")
    verify(uris.contains("file:///RedShape.fan"),    "RedShape.draw must be found")
    verify(uris.contains("file:///BlueShape.fan"),   "BlueShape.draw must be found")
    verify(uris.contains("file:///GrayShape.fan"),   "GrayShape.draw must be found")
  }

  Void testFindImplMixinFiveImplementations()
  {
    // Mirrors a real-world pattern: a device-type mixin implemented by
    // 5 independent concrete device classes (e.g. air handlers, chillers, etc.).
    // None of the implementors share a common base — they all directly implement the mixin.
    //
    //   mixin ITask { abstract Bool run() }
    //   TaskA, TaskB, TaskC, TaskD, TaskE : ITask
    //
    mixin_ :=
      "mixin ITask {\n" +
      "  abstract Bool run()\n" +
      "}\n"
    taskA :=
      "class TaskA : ITask {\n" +
      "  override Bool run() { return true }\n" +
      "}\n"
    taskB :=
      "class TaskB : ITask {\n" +
      "  override Bool run() { return true }\n" +
      "}\n"
    taskC :=
      "class TaskC : ITask {\n" +
      "  override Bool run() { return true }\n" +
      "}\n"
    taskD :=
      "class TaskD : ITask {\n" +
      "  override Bool run() { return true }\n" +
      "}\n"
    taskE :=
      "class TaskE : ITask {\n" +
      "  override Bool run() { return false }\n" +
      "}\n"
    idx := makeIndex([
      "file:///ITask.fan":  mixin_,
      "file:///TaskA.fan":  taskA,
      "file:///TaskB.fan":  taskB,
      "file:///TaskC.fan":  taskC,
      "file:///TaskD.fan":  taskD,
      "file:///TaskE.fan":  taskE,
    ])
    // "  abstract Bool run()" — 'r' of 'run' at line 1, col 16
    locs := svc.findImplementations("file:///ITask.fan", pos(1, 16), mixin_, idx)
    verifyEq(locs.size, 5, "All 5 ITask.run overrides must be found, got: $locs.size")
    uris := locs.map |l| { uriOf(l) }
    verify(uris.contains("file:///TaskA.fan"), "TaskA.run must be found")
    verify(uris.contains("file:///TaskB.fan"), "TaskB.run must be found")
    verify(uris.contains("file:///TaskC.fan"), "TaskC.run must be found")
    verify(uris.contains("file:///TaskD.fan"), "TaskD.run must be found")
    verify(uris.contains("file:///TaskE.fan"), "TaskE.run must be found")
  }

  Void testFindImplMixinExtendsMixin()
  {
    // A mixin that itself extends another mixin (mixin inheritance chain).
    // Mirrors a real-world pattern where base capability mixins are specialised
    // by derived mixins, then implemented by concrete classes.
    //
    //   mixin IMeter { abstract Str unit() }
    //   mixin IAdvancedMeter : IMeter { abstract Int precision() }
    //   class MeterA : IAdvancedMeter
    //   class MeterB : IAdvancedMeter
    //
    base_ :=
      "mixin IMeter { abstract Str unit() }\n"
    derived_ :=
      "mixin IAdvancedMeter : IMeter { abstract Int precision() }\n"
    meterA :=
      "class MeterA : IAdvancedMeter {\n" +
      "  override Str unit() { return \"m\" }\n" +
      "  override Int precision() { return 2 }\n" +
      "}\n"
    meterB :=
      "class MeterB : IAdvancedMeter {\n" +
      "  override Str unit() { return \"k\" }\n" +
      "  override Int precision() { return 3 }\n" +
      "}\n"
    idx := makeIndex([
      "file:///IMeter.fan":          base_,
      "file:///IAdvancedMeter.fan":  derived_,
      "file:///MeterA.fan":          meterA,
      "file:///MeterB.fan":          meterB,
    ])
    // Find implementations of IAdvancedMeter type — cursor on 'I' at col 6
    locs := svc.findImplementations("file:///IAdvancedMeter.fan", pos(0, 6), derived_, idx)
    verifyEq(locs.size, 2, "MeterA and MeterB must implement IAdvancedMeter, got: $locs.size")
    uris := locs.map |l| { uriOf(l) }
    verify(uris.contains("file:///MeterA.fan"), "MeterA must be found")
    verify(uris.contains("file:///MeterB.fan"), "MeterB must be found")
  }

//////////////////////////////////////////////////////////////////////////
// Find References — static method across many files (real-world pattern)
//////////////////////////////////////////////////////////////////////////

  Void testFindRefsMemberStaticAcrossMultipleFiles()
  {
    // Mirrors a real-world pattern: a library utility method (static) called
    // from many independent service files.  The scanner must find all call sites
    // across all files via the uppercase-receiver branch.
    //
    //   class Registry { static Dict lookup(Str id) {} }
    //   ServiceA/B/C/D all call Registry.lookup(...)
    //
    registry :=
      "class Registry { static Dict lookup(Str id) { return Dict() } }\n"
    svcA :=
      "class ServiceA { Void load() { Dict d := Registry.lookup(\"a\") } }\n"
    svcB :=
      "class ServiceB { Void load() { Dict d := Registry.lookup(\"b\") } }\n"
    svcC :=
      "class ServiceC { Void load() { Dict d := Registry.lookup(\"c\") } }\n"
    svcD :=
      "class ServiceD { Void load() { Dict d := Registry.lookup(\"d\") } }\n"
    idx := makeIndex([
      "file:///Registry.fan":  registry,
      "file:///ServiceA.fan":  svcA,
      "file:///ServiceB.fan":  svcB,
      "file:///ServiceC.fan":  svcC,
      "file:///ServiceD.fan":  svcD,
    ])
    // "class Registry { static Dict lookup(Str id) ... }"
    // 'l' of 'lookup' at col 29
    locs := svc.findReferences("file:///Registry.fan", pos(0, 29), registry, idx, false)
    uris := locs.map |l| { uriOf(l) }
    verify(uris.contains("file:///ServiceA.fan"), "ServiceA.lookup call must be found")
    verify(uris.contains("file:///ServiceB.fan"), "ServiceB.lookup call must be found")
    verify(uris.contains("file:///ServiceC.fan"), "ServiceC.lookup call must be found")
    verify(uris.contains("file:///ServiceD.fan"), "ServiceD.lookup call must be found")
  }

  Void testFindRefsMemberIsolatedHierarchiesNoBleed()
  {
    // Two completely independent classes have a method with the same name.
    // References to ServiceA.process must NOT include ServiceB.process usages,
    // even when both are called on explicitly-typed local variables.
    // Mirrors the real-world pattern of many unrelated service classes all having
    // a common method name (e.g. 'execute', 'init', 'save').
    a := "class ServiceA { Void process() {} }\n"
    b := "class ServiceB { Void process() {} }\n"
    clientA :=
      "class ClientA {\n" +
      "  Void run() {\n" +
      "    ServiceA svc := ServiceA()\n" +
      "    svc.process()\n" +
      "  }\n" +
      "}\n"
    clientB :=
      "class ClientB {\n" +
      "  Void run() {\n" +
      "    ServiceB svc := ServiceB()\n" +
      "    svc.process()\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex([
      "file:///ServiceA.fan":  a,
      "file:///ServiceB.fan":  b,
      "file:///ClientA.fan":   clientA,
      "file:///ClientB.fan":   clientB,
    ])
    // "class ServiceA { Void process() {} }" — 'p' at col 22
    locsA := svc.findReferences("file:///ServiceA.fan", pos(0, 22), a, idx, false)
    verify(locsA.any |l| { uriOf(l) == "file:///ClientA.fan" },
      "ClientA.svc.process() must be found")
    verify(!locsA.any |l| { uriOf(l) == "file:///ServiceB.fan" },
      "ServiceB.process declaration must NOT appear in ServiceA references")
    verify(!locsA.any |l| { uriOf(l) == "file:///ClientB.fan" },
      "ClientB.svc.process() must NOT appear in ServiceA references")

    // Symmetry: ServiceB references must not include ServiceA usages
    locsB := svc.findReferences("file:///ServiceB.fan", pos(0, 22), b, idx, false)
    verify(locsB.any |l| { uriOf(l) == "file:///ClientB.fan" },
      "ClientB.svc.process() must be found")
    verify(!locsB.any |l| { uriOf(l) == "file:///ServiceA.fan" },
      "ServiceA.process declaration must NOT appear in ServiceB references")
    verify(!locsB.any |l| { uriOf(l) == "file:///ClientA.fan" },
      "ClientA.svc.process() must NOT appear in ServiceB references")
  }

  Void testFindRefsMemberCalledOnTypedInterfaceLocal()
  {
    // An interface method called on a local variable declared with an explicit
    // interface type annotation.  Mirrors the real-world pattern where a device
    // reference (declared as the interface type) is obtained and then used.
    //
    //   ITask task := TaskA()
    //   task.run()   ← must be found as a reference to ITask.run
    //
    mixin_ :=
      "mixin ITask {\n" +
      "  abstract Bool run()\n" +
      "}\n"
    taskA :=
      "class TaskA : ITask { override Bool run() { return true } }\n"
    caller :=
      "class Scheduler {\n" +                    // line 0
      "  Void schedule() {\n" +                   // line 1
      "    ITask task := TaskA()\n" +              // line 2: typed local
      "    task.run()\n" +                         // line 3: must be found
      "  }\n" +                                   // line 4
      "}\n"
    idx := makeIndex([
      "file:///ITask.fan":     mixin_,
      "file:///TaskA.fan":     taskA,
      "file:///Caller.fan":    caller,
    ])
    // "  abstract Bool run()" — 'r' of 'run' at line 1, col 16
    locs := svc.findReferences("file:///ITask.fan", pos(1, 16), mixin_, idx, false)
    verify(locs.any |l| { uriOf(l) == "file:///Caller.fan" && lineOf(l) == 3 },
      "task.run() via typed interface local must be found")
  }
}
