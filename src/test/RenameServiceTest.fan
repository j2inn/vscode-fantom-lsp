**
** RenameServiceTest - Tests for RenameService (F2 rename).
**
class RenameServiceTest : Test
{
  private RenameService svc := RenameService()

  private LspPosition pos(Int line, Int ch) { LspPosition(line, ch) }

  private ProjectIndex makeIndex([Str:Str] files)
  {
    idx := ProjectIndex()
    files.each |src, uri| { idx.indexFile(uri, src) }
    return idx
  }

  private [Str:Obj?][]? editsFor([Str:Obj?]? result, Str fileUri)
  {
    if (result == null) return null
    changes := result["documentChanges"] as [Str:Obj?][]
    if (changes == null) return null
    entry := changes.find |c|
    {
      td := c["textDocument"] as Str:Obj?
      return td != null && td["uri"] == fileUri
    }
    if (entry == null) return null
    return entry["edits"] as [Str:Obj?][]
  }

  private Str? newTextOf([Str:Obj?] edit) { edit["newText"] as Str }

  private Int? editLine([Str:Obj?] edit)
  {
    try
    {
      r := edit["range"] as Str:Obj?
      if (r == null) return null
      s := r["start"] as Str:Obj?
      if (s == null) return null
      return s["line"] as Int
    }
    catch (Err e) { return null }
  }

//////////////////////////////////////////////////////////////////////////
// Type rename
//////////////////////////////////////////////////////////////////////////

  Void testRenameType()
  {
    // "class Alpha {}" — 'A' of Alpha at col 6
    a   := "class Alpha {}\n"
    b   := "class Beta { Alpha x := Alpha() }\n"
    idx := makeIndex(["file:///A.fan": a, "file:///B.fan": b])

    result := svc.rename("file:///A.fan", pos(0, 6), a, "AlphaV2", idx)
    verifyNotNull(result, "rename must return a WorkspaceEdit")

    editsA := editsFor(result, "file:///A.fan")
    verifyNotNull(editsA, "A.fan must have edits")
    verify(editsA.any |e| { newTextOf(e) == "AlphaV2" })

    editsB := editsFor(result, "file:///B.fan")
    verifyNotNull(editsB, "B.fan must have edits")
    verify(editsB.size >= 2, "Both Alpha usages in B.fan must be renamed")
    verify(editsB.all |e| { newTextOf(e) == "AlphaV2" })
  }

  Void testRenameTypeRenamesFile()
  {
    // Single-class file named Alpha.fan — must get a file-rename operation
    a   := "class Alpha {}\n"
    idx := makeIndex(["file:///Alpha.fan": a])

    result := svc.rename("file:///Alpha.fan", pos(0, 6), a, "AlphaV2", idx)
    verifyNotNull(result)
    changes := result["documentChanges"] as [Str:Obj?][]
    verifyNotNull(changes)
    renameOp := changes.find |c| { c["kind"] == "rename" }
    verifyNotNull(renameOp, "File rename operation must be present")
    verifyEq(renameOp["oldUri"], "file:///Alpha.fan")
    verifyEq(renameOp["newUri"], "file:///AlphaV2.fan")
  }

  Void testRenameTypeNoFileRenameMultiClass()
  {
    // Two classes in one file — no file rename
    src := "class Alpha {}\nclass Helper {}\n"
    idx := makeIndex(["file:///Alpha.fan": src])

    result := svc.rename("file:///Alpha.fan", pos(0, 6), src, "AlphaV2", idx)
    verifyNotNull(result)
    changes := result["documentChanges"] as [Str:Obj?][]
    verifyNotNull(changes)
    renameOp := changes.find |c| { c["kind"] == "rename" }
    verifyNull(renameOp, "Multi-class file must NOT get a file-rename operation")
  }

//////////////////////////////////////////////////////////////////////////
// Member rename
//////////////////////////////////////////////////////////////////////////

  Void testRenameMember()
  {
    // cursor on 'run' at col 12 in "class A { Void run() {} }"
    a := "class A { Void run() {} }\n"
    b :=
      "class Client {\n" +
      "  Void test() {\n" +
      "    A obj := A()\n" +
      "    obj.run()\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///A.fan": a, "file:///B.fan": b])

    result := svc.rename("file:///A.fan", pos(0, 15), a, "execute", idx)
    verifyNotNull(result)

    editsA := editsFor(result, "file:///A.fan")
    verifyNotNull(editsA)
    verify(editsA.any |e| { newTextOf(e) == "execute" }, "Decl in A.fan must be renamed")

    editsB := editsFor(result, "file:///B.fan")
    verifyNotNull(editsB, "Usage in B.fan must be renamed")
    verify(editsB.any |e| { newTextOf(e) == "execute" && editLine(e) == 3 })
  }

  Void testRenameMemberInheritedOverride()
  {
    // Child overrides Base.draw — rename must cover both decls
    base  := "class Base { virtual Void draw() {} }\n"
    child :=
      "class Child : Base {\n" +
      "  override Void draw() {}\n" +
      "}\n"
    idx := makeIndex(["file:///Base.fan": base, "file:///Child.fan": child])

    // 'draw' in base at col 26
    result := svc.rename("file:///Base.fan", pos(0, 26), base, "render", idx)
    verifyNotNull(result)

    editsBase := editsFor(result, "file:///Base.fan")
    verifyNotNull(editsBase, "Decl in Base.fan must be renamed")
    verify(editsBase.any |e| { newTextOf(e) == "render" })

    editsChild := editsFor(result, "file:///Child.fan")
    verifyNotNull(editsChild, "Override in Child.fan must also be renamed")
    verify(editsChild.any |e| { newTextOf(e) == "render" })
  }

//////////////////////////////////////////////////////////////////////////
// Local rename
//////////////////////////////////////////////////////////////////////////

  Void testRenameLocal()
  {
    // 'x' at line 2 col 4 — inside test(); the x in other() must NOT be renamed
    src :=
      "class A {\n" +
      "  Void test() {\n" +
      "    x := 42\n" +
      "    echo(x)\n" +
      "  }\n" +
      "  Void other() { x := 99 }\n" +
      "}\n"
    idx := makeIndex(["file:///A.fan": src])

    result := svc.rename("file:///A.fan", pos(2, 4), src, "val", idx)
    verifyNotNull(result)

    edits := editsFor(result, "file:///A.fan")
    verifyNotNull(edits)
    verifyEq(edits.size, 2, "Only the two x in test() must be renamed")
    verify(edits.all |e| { newTextOf(e) == "val" })
    // Both edits must be inside test() (lines 2 and 3)
    lines := edits.map |e| { editLine(e) }
    verify(lines.contains(2))
    verify(lines.contains(3))
  }

  Void testRenameLocalAfterStaticChainedCall()
  {
    // Regression: SysLib.recTrash(entities) was misdetected as a method
    // declaration boundary, causing rename to miss the last 2 occurrences.
    // Mirrors IntelliplantNAUtils.fan clearClivetNAEntities method.
    // 'entities' is at line 2 col 4.
    src :=
      "class Utils {\n" +
      "  static Number clear(Context cx) {\n" +
      "    entities := cx.proj.readAll(\"tag\")\n" +
      "    if (entities.isEmpty) { return Number.zero }\n" +
      "    SysLib.recTrash(entities)\n" +
      "    return Number(entities.size)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Utils.fan": src])

    result := svc.rename("file:///Utils.fan", pos(2, 4), src, "recs", idx)
    verifyNotNull(result)

    edits := editsFor(result, "file:///Utils.fan")
    verifyNotNull(edits)
    verifyEq(edits.size, 4, "All 4 occurrences of 'entities' must be renamed")
    verify(edits.all |e| { newTextOf(e) == "recs" })
    lines := edits.map |e| { editLine(e) }
    verify(lines.contains(2), "declaration must be renamed")
    verify(lines.contains(3), "entities.isEmpty must be renamed")
    verify(lines.contains(4), "SysLib.recTrash(entities) must be renamed")
    verify(lines.contains(5), "entities.size must be renamed")
  }

//////////////////////////////////////////////////////////////////////////
// Bare call used as argument — regression for IntelliplantNACoreLib pattern
//////////////////////////////////////////////////////////////////////////

  Void testRenameBareCallUsedAsArgument()
  {
    // Mirrors the real-world IntelliplantNACoreLib.fan structure where
    // cx() is a private static helper used as an argument in many forms:
    //   StaticType.method(cx, ...)          — first arg, static call
    //   Constructor(cx, id)                 — first arg, ctor
    //   Constructor(logger, cx).method()    — second arg, ctor, chained
    //   cx.field.something                  — receiver of property chain
    //
    // "cx" is at col 25 on line 1: "  private static Context cx() { Context.cur }"
    src :=
      "class Lib {\n" +
      "  private static Context cx() { Context.cur }\n" +
      "  static Dict backup() { return Handler.backupAll(cx, true) }\n" +
      "  static Dict restore() { return Handler.restore(cx, Ext#.pod) }\n" +
      "  static Void clear() { Utils.clearAll(cx) }\n" +
      "  static Grid devs(Ref id) { Server(cx, id).getDevices() }\n" +
      "  static Grid info(Ref id) { Service(logger, cx).getInfo(id) }\n" +
      "  static Void walk() { uri := cx.proj.dir.uri + `io/` }\n" +
      "}\n"
    idx := makeIndex(["file:///Lib.fan": src])

    result := svc.rename("file:///Lib.fan", pos(1, 25), src, "context", idx)
    verifyNotNull(result)

    edits := editsFor(result, "file:///Lib.fan")
    verifyNotNull(edits)

    lines := edits.map |e| { editLine(e) }
    verify(lines.contains(1), "Declaration (line 1) must be renamed")
    verify(lines.contains(2), "cx in Handler.backupAll(cx, true) must be renamed")
    verify(lines.contains(3), "cx in Handler.restore(cx, ...) must be renamed")
    verify(lines.contains(4), "cx in Utils.clearAll(cx) must be renamed")
    verify(lines.contains(5), "cx in Server(cx, id) must be renamed")
    verify(lines.contains(6), "cx in Service(logger, cx).getInfo() must be renamed")
    verify(lines.contains(7), "cx.proj.dir receiver must be renamed")
    verify(edits.all |e| { newTextOf(e) == "context" })
  }

//////////////////////////////////////////////////////////////////////////
// Three-level hierarchy rename (real-world pattern)
//////////////////////////////////////////////////////////////////////////

  Void testRenameThreeLevelHierarchy()
  {
    // Rename a method that is declared in a root mixin and overridden through
    // two more inheritance levels.  All 5 override declarations (plus the mixin
    // declaration) must receive rename edits.
    //
    //   mixin IShape { abstract Void draw() }
    //   Shape : IShape               → override draw()
    //     ColorShape : Shape          → override draw()
    //       RedShape : ColorShape     → override draw()
    //     GrayShape : Shape           → override draw()
    //
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
      "class GrayShape : Shape {\n" +
      "  override Void draw() {}\n" +
      "}\n"
    idx := makeIndex([
      "file:///IShape.fan":     ibase,
      "file:///Shape.fan":      base,
      "file:///ColorShape.fan": mid,
      "file:///RedShape.fan":   leafA,
      "file:///GrayShape.fan":  leafB,
    ])
    // "mixin IShape { abstract Void draw() }" — 'd' of 'draw' at col 29
    result := svc.rename("file:///IShape.fan", pos(0, 29), ibase, "paint", idx)
    verifyNotNull(result, "Rename must return a WorkspaceEdit")
    ["file:///IShape.fan", "file:///Shape.fan", "file:///ColorShape.fan",
     "file:///RedShape.fan", "file:///GrayShape.fan"].each |uri|
    {
      edits := editsFor(result, uri)
      verifyNotNull(edits, "$uri must have rename edits")
      verify(edits.any |e| { newTextOf(e) == "paint" }, "$uri must rename 'draw' to 'paint'")
    }
  }

//////////////////////////////////////////////////////////////////////////
// Mixin with many implementations rename (real-world pattern)
//////////////////////////////////////////////////////////////////////////

  Void testRenameMixinMethodAcrossAllImplementations()
  {
    // Rename an abstract method in a mixin that is implemented by 5 independent
    // concrete classes (no shared base class between them).
    // All 6 declarations (1 mixin + 5 overrides) must receive rename edits.
    // Mirrors the real-world pattern of device-type mixins.
    mixin_ :=
      "mixin ITask {\n" +
      "  abstract Bool run()\n" +
      "}\n"
    taskA := "class TaskA : ITask { override Bool run() { return true } }\n"
    taskB := "class TaskB : ITask { override Bool run() { return true } }\n"
    taskC := "class TaskC : ITask { override Bool run() { return true } }\n"
    taskD := "class TaskD : ITask { override Bool run() { return true } }\n"
    taskE := "class TaskE : ITask { override Bool run() { return false } }\n"
    idx := makeIndex([
      "file:///ITask.fan":  mixin_,
      "file:///TaskA.fan":  taskA,
      "file:///TaskB.fan":  taskB,
      "file:///TaskC.fan":  taskC,
      "file:///TaskD.fan":  taskD,
      "file:///TaskE.fan":  taskE,
    ])
    // "  abstract Bool run()" — 'r' at line 1, col 16
    result := svc.rename("file:///ITask.fan", pos(1, 16), mixin_, "execute", idx)
    verifyNotNull(result)
    ["file:///ITask.fan", "file:///TaskA.fan", "file:///TaskB.fan",
     "file:///TaskC.fan", "file:///TaskD.fan", "file:///TaskE.fan"].each |uri|
    {
      edits := editsFor(result, uri)
      verifyNotNull(edits, "$uri must have rename edits")
      verify(edits.any |e| { newTextOf(e) == "execute" },
        "$uri must rename 'run' to 'execute'")
    }
  }

//////////////////////////////////////////////////////////////////////////
// Local variable isolation across three methods (real-world pattern)
//////////////////////////////////////////////////////////////////////////

  Void testRenameLocalIsolatedAcrossThreeMethods()
  {
    // Three methods all declare a local named 'items'.  Renaming 'items'
    // in insert() must touch only the two occurrences in that method and
    // leave the same-named locals in update() and delete() untouched.
    // Mirrors a real-world DAO/repository class where every CRUD method
    // contains a similarly-named local collection variable.
    src :=
      "class Repo {\n" +                            // line 0
      "  Void insert(Dict data) {\n" +               // line 1
      "    items := fetchAll(data)\n" +              // line 2: decl
      "    items.each |i| { echo(i) }\n" +           // line 3: use
      "  }\n" +                                      // line 4
      "  Void update(Dict data) {\n" +               // line 5
      "    items := fetchAll(data)\n" +              // line 6: different scope
      "    items.size\n" +                           // line 7
      "  }\n" +                                      // line 8
      "  Void delete(Dict data) {\n" +               // line 9
      "    items := fetchAll(data)\n" +              // line 10: different scope
      "    items.first\n" +                          // line 11
      "  }\n" +                                      // line 12
      "}\n"
    idx := makeIndex(["file:///Repo.fan": src])

    // Cursor on 'items' at line 2, col 4 (inside insert)
    result := svc.rename("file:///Repo.fan", pos(2, 4), src, "entries", idx)
    verifyNotNull(result)
    edits := editsFor(result, "file:///Repo.fan")
    verifyNotNull(edits)
    verifyEq(edits.size, 2, "Only the 2 'items' in insert() must be renamed, got: $edits.size")
    lines := edits.map |e| { editLine(e) }
    verify(lines.contains(2), "Declaration in insert() must be renamed")
    verify(lines.contains(3), "Use in insert() must be renamed")
    verify(!lines.contains(6),  "items in update() must NOT be renamed")
    verify(!lines.contains(7),  "items.size in update() must NOT be renamed")
    verify(!lines.contains(10), "items in delete() must NOT be renamed")
    verify(!lines.contains(11), "items.first in delete() must NOT be renamed")
  }

//////////////////////////////////////////////////////////////////////////
// Static method rename across many files (real-world pattern)
//////////////////////////////////////////////////////////////////////////

  Void testRenameStaticMethodAcrossFiles()
  {
    // A static utility method called from several independent service files.
    // All call sites across all files must receive rename edits, and the
    // declaration itself must also be renamed.
    // Mirrors a real-world pattern of static library helpers.
    registry :=
      "class Registry { static Dict lookup(Str id) { return Dict() } }\n"
    svcA :=
      "class ServiceA { Void load() { Dict d := Registry.lookup(\"a\") } }\n"
    svcB :=
      "class ServiceB { Void load() { Dict d := Registry.lookup(\"b\") } }\n"
    svcC :=
      "class ServiceC { Void load() { Dict d := Registry.lookup(\"c\") } }\n"
    idx := makeIndex([
      "file:///Registry.fan":  registry,
      "file:///ServiceA.fan":  svcA,
      "file:///ServiceB.fan":  svcB,
      "file:///ServiceC.fan":  svcC,
    ])
    // 'l' of 'lookup' at col 29
    result := svc.rename("file:///Registry.fan", pos(0, 29), registry, "find", idx)
    verifyNotNull(result)
    ["file:///Registry.fan", "file:///ServiceA.fan",
     "file:///ServiceB.fan",  "file:///ServiceC.fan"].each |uri|
    {
      edits := editsFor(result, uri)
      verifyNotNull(edits, "$uri must have rename edits")
      verify(edits.any |e| { newTextOf(e) == "find" },
        "$uri must rename 'lookup' to 'find'")
    }
  }

//////////////////////////////////////////////////////////////////////////
// Isolated hierarchy rename — no bleed into unrelated hierarchy
//////////////////////////////////////////////////////////////////////////

  Void testRenameMemberIsolatedHierarchyNoBleed()
  {
    // Two completely independent classes share a method name.
    // Renaming ServiceA.process must only affect ServiceA and its callers,
    // leaving ServiceB and ClientB entirely unchanged.
    // This is the hardest rename correctness requirement: same name, similar
    // usage patterns, but different type families.
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
    // "class ServiceA { Void process() {} }" — 'p' of 'process' at col 22
    result := svc.rename("file:///ServiceA.fan", pos(0, 22), a, "execute", idx)
    verifyNotNull(result)

    // ServiceA declaration must be renamed
    editsA := editsFor(result, "file:///ServiceA.fan")
    verifyNotNull(editsA, "ServiceA.fan must have edits")
    verify(editsA.any |e| { newTextOf(e) == "execute" })

    // ClientA call must be renamed (receiver type is ServiceA)
    editsCA := editsFor(result, "file:///ClientA.fan")
    verifyNotNull(editsCA, "ClientA.fan must have edits")
    verify(editsCA.any |e| { newTextOf(e) == "execute" })

    // ServiceB and ClientB must be untouched
    editsB := editsFor(result, "file:///ServiceB.fan")
    verify(editsB == null || editsB.isEmpty,
      "ServiceB.fan must NOT be renamed (unrelated hierarchy)")
    editsCB := editsFor(result, "file:///ClientB.fan")
    verify(editsCB == null || editsCB.isEmpty,
      "ClientB.fan must NOT be renamed (ServiceB receiver)")
  }

//////////////////////////////////////////////////////////////////////////
// prepareRename
//////////////////////////////////////////////////////////////////////////

  Void testPrepareRename()
  {
    src := "class Alpha {}\n"
    result := svc.prepareRename("file:///A.fan", pos(0, 6), src)
    verifyNotNull(result)
    verifyEq(result["placeholder"], "Alpha")
    r := result["range"] as Str:Obj?
    verifyNotNull(r)
    start := r["start"] as Str:Obj?
    verifyNotNull(start)
    verifyEq(start["character"], 6)
  }
}
