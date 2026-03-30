//
// Copyright (c) 2025, Brian Frank and Andy Frank
// Licensed under the Academic Free License version 3.0
//
// History:
//   11 Feb 26  Creation
//

using compiler

**
** DefinitionServiceTest - Tests for go-to-definition with scope awareness
**
class DefinitionServiceTest : Test
{
  private DefinitionService svc := DefinitionService()

//////////////////////////////////////////////////////////////////////////
// Definition of Field in Same File
//////////////////////////////////////////////////////////////////////////

  Void testDefinitionField()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    // Line 0: class Foo
    // Line 1: {
    // Line 2:   Str name
    // Line 3:   Void bar()
    // Line 4:   {
    // Line 5:     x := name
    // Line 6:   }
    // Line 7: }
    source :=
      "class Foo\n" +
      "{\n" +
      "  Str name\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    x := name\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Position on "name" at line 5, col 9 (within the word "name")
    pos := LspPosition(5, 9)
    result := svc.findDefinition(uri, pos, source, idx)

    verifyNotNull(result)
    range := result["range"] as Str:Obj?
    verifyNotNull(range)
    start := range["start"] as Str:Obj?
    verifyNotNull(start)
    // Should point to field declaration at line 2
    verifyEq(start["line"], 2)
  }

//////////////////////////////////////////////////////////////////////////
// Definition of Type in Same File
//////////////////////////////////////////////////////////////////////////

  Void testDefinitionType()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar() {}\n" +
      "}"

    idx.indexFile(uri, source)

    // Position on "Foo" at line 0, col 6
    pos := LspPosition(0, 6)
    result := svc.findDefinition(uri, pos, source, idx)

    verifyNotNull(result)
    range := result["range"] as Str:Obj?
    verifyNotNull(range)
    start := range["start"] as Str:Obj?
    verifyNotNull(start)
    verifyEq(start["line"], 0)
  }

//////////////////////////////////////////////////////////////////////////
// Definition of Local Variable
//////////////////////////////////////////////////////////////////////////

  Void testDefinitionLocalVar()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    // Line 0: class Foo
    // Line 1: {
    // Line 2:   Void bar()
    // Line 3:   {
    // Line 4:     result := 42
    // Line 5:     x := result + 1
    // Line 6:   }
    // Line 7: }
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    result := 42\n" +
      "    x := result + 1\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Position on "result" at line 5, col 9
    pos := LspPosition(5, 9)
    result := svc.findDefinition(uri, pos, source, idx)

    verifyNotNull(result)
    range := result["range"] as Str:Obj?
    verifyNotNull(range)
    start := range["start"] as Str:Obj?
    verifyNotNull(start)
    // Should point to local var declaration at line 4
    verifyEq(start["line"], 4)
  }

//////////////////////////////////////////////////////////////////////////
// Definition of Method Parameter
//////////////////////////////////////////////////////////////////////////

  Void testDefinitionParam()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    // Line 0: class Foo
    // Line 1: {
    // Line 2:   Void bar(Str msg)
    // Line 3:   {
    // Line 4:     x := msg
    // Line 5:   }
    // Line 6: }
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(Str msg)\n" +
      "  {\n" +
      "    x := msg\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Position on "msg" at line 4, col 9
    pos := LspPosition(4, 9)
    result := svc.findDefinition(uri, pos, source, idx)

    verifyNotNull(result)
    range := result["range"] as Str:Obj?
    verifyNotNull(range)
    start := range["start"] as Str:Obj?
    verifyNotNull(start)
    // Should point to param declaration at line 2
    verifyEq(start["line"], 2)
  }

//////////////////////////////////////////////////////////////////////////
// Definition Returns Null for Unknown Symbol
//////////////////////////////////////////////////////////////////////////

  Void testDefinitionUnknownSymbol()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    x := nonExistent\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Position on "nonExistent" — not indexed (it's a reference, not a declaration)
    // The walrus var is "x", not "nonExistent"
    pos := LspPosition(4, 14)
    result := svc.findDefinition(uri, pos, source, idx)

    // Should return null since "nonExistent" isn't declared anywhere
    verifyNull(result)
  }

//////////////////////////////////////////////////////////////////////////
// Scope Awareness: Same Name Different Methods
//////////////////////////////////////////////////////////////////////////

  Void testDefinitionScopeAwareness()
  {
    idx := ProjectIndex()
    uri := "file:///test/Svc.fan"
    // Line 0: class Svc
    // Line 1: {
    // Line 2:   Str data
    // Line 3:
    // Line 4:   Void methodA()
    // Line 5:   {
    // Line 6:     data := "localA"
    // Line 7:   }
    // Line 8:
    // Line 9:   Void methodB()
    // Line 10:  {
    // Line 11:    data := "localB"
    // Line 12:  }
    // Line 13: }
    source :=
      "class Svc\n" +
      "{\n" +
      "  Str data\n" +
      "\n" +
      "  Void methodA()\n" +
      "  {\n" +
      "    data := \"localA\"\n" +
      "  }\n" +
      "\n" +
      "  Void methodB()\n" +
      "  {\n" +
      "    data := \"localB\"\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Inside methodA (line 6) → should go to local at line 6
    posA := LspPosition(6, 4)
    resultA := svc.findDefinition(uri, posA, source, idx)
    verifyNotNull(resultA)
    rangeA := (resultA["range"] as Str:Obj?)["start"] as Str:Obj?
    verifyEq(rangeA["line"], 6)

    // Inside methodB (line 11) → should go to local at line 11
    posB := LspPosition(11, 4)
    resultB := svc.findDefinition(uri, posB, source, idx)
    verifyNotNull(resultB)
    rangeB := (resultB["range"] as Str:Obj?)["start"] as Str:Obj?
    verifyEq(rangeB["line"], 11)
  }

//////////////////////////////////////////////////////////////////////////
// Cross-File Definition
//////////////////////////////////////////////////////////////////////////

  Void testCrossFileDefinition()
  {
    idx := ProjectIndex()
    uriA := "file:///test/Logger.fan"
    uriB := "file:///test/App.fan"

    sourceA :=
      "class Logger\n" +
      "{\n" +
      "  Void log(Str msg) {}\n" +
      "}"

    sourceB :=
      "class App\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    logger := Logger()\n" +
      "  }\n" +
      "}"

    idx.indexFile(uriA, sourceA)
    idx.indexFile(uriB, sourceB)

    // Position on "Logger" at line 4 in App.fan
    pos := LspPosition(4, 15)
    result := svc.findDefinition(uriB, pos, sourceB, idx)

    verifyNotNull(result)
    // Should point to Logger.fan
    verifyEq(result["uri"], uriA)
    range := result["range"] as Str:Obj?
    start := range["start"] as Str:Obj?
    verifyEq(start["line"], 0)
  }

//////////////////////////////////////////////////////////////////////////
// Cross-File Static Method Definition
//////////////////////////////////////////////////////////////////////////

  Void testCrossFileStaticMethodDefinition()
  {
    idx := ProjectIndex()
    uriA := "file:///test/DeviceData.fan"
    uriB := "file:///test/Writer.fan"

    sourceA :=
      "class DeviceData\n" +
      "{\n" +
      "  Str name\n" +
      "\n" +
      "  static DeviceData[] readAllByScheduleRef(Str ref) { return DeviceData[,] }\n" +
      "}"

    sourceB :=
      "class Writer\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    list := DeviceData.readAllByScheduleRef(\"abc\")\n" +
      "  }\n" +
      "}"

    idx.indexFile(uriA, sourceA)
    idx.indexFile(uriB, sourceB)

    // Position on "readAllByScheduleRef" at line 4 in Writer.fan
    pos := LspPosition(4, 25)
    result := svc.findDefinition(uriB, pos, sourceB, idx)

    verifyNotNull(result)
    // Should point to DeviceData.fan
    verifyEq(result["uri"], uriA)
    range := result["range"] as Str:Obj?
    start := range["start"] as Str:Obj?
    // Method is on line 4 of DeviceData.fan
    verifyEq(start["line"], 4)
  }

//////////////////////////////////////////////////////////////////////////
// Definition Result Structure
//////////////////////////////////////////////////////////////////////////

  Void testDefinitionResultHasCorrectStructure()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    source :=
      "class Foo\n" +
      "{\n" +
      "  Str name\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    x := name\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    pos := LspPosition(5, 9)
    result := svc.findDefinition(uri, pos, source, idx)

    verifyNotNull(result)

    // Must have "uri" key
    verify(result.containsKey("uri"))

    // Must have "range" key with start/end
    verify(result.containsKey("range"))
    range := result["range"] as Str:Obj?
    verifyNotNull(range)
    verify(range.containsKey("start"))
    verify(range.containsKey("end"))

    start := range["start"] as Str:Obj?
    verifyNotNull(start)
    verify(start.containsKey("line"))
    verify(start.containsKey("character"))

    end := range["end"] as Str:Obj?
    verifyNotNull(end)
    verify(end.containsKey("line"))
    verify(end.containsKey("character"))
  }

//////////////////////////////////////////////////////////////////////////
// Constructor Call Goes to make Method
//////////////////////////////////////////////////////////////////////////

  Void testConstructorCallGoesToMake()
  {
    idx := ProjectIndex()
    uriA := "file:///test/BacnetServer.fan"
    uriB := "file:///test/Lib.fan"

    // Line 0: class BacnetServer
    // Line 1: {
    // Line 2:   new make(Obj cx, Obj siteId) {}
    // Line 3:   Obj[] getDevices() { [,] }
    // Line 4: }
    sourceA :=
      "class BacnetServer\n" +
      "{\n" +
      "  new make(Obj cx, Obj siteId) {}\n" +
      "  Obj[] getDevices() { [,] }\n" +
      "}"

    // Line 0: class Lib
    // Line 1: {
    // Line 2:   Void test(Obj cx, Obj siteId)
    // Line 3:   {
    // Line 4:     BacnetServer(cx, siteId).getDevices()
    // Line 5:   }
    // Line 6: }
    sourceB :=
      "class Lib\n" +
      "{\n" +
      "  Void test(Obj cx, Obj siteId)\n" +
      "  {\n" +
      "    BacnetServer(cx, siteId).getDevices()\n" +
      "  }\n" +
      "}"

    idx.indexFile(uriA, sourceA)
    idx.indexFile(uriB, sourceB)

    // Position on "BacnetServer" at line 4 of Lib.fan (constructor call)
    pos := LspPosition(4, 8)
    result := svc.findDefinition(uriB, pos, sourceB, idx)

    verifyNotNull(result)
    // Should point to BacnetServer.fan
    verifyEq(result["uri"], uriA)
    range := result["range"] as Str:Obj?
    start := range["start"] as Str:Obj?
    // Should point to the 'make' method at line 2, not class at line 0
    verifyEq(start["line"], 2)
  }

//////////////////////////////////////////////////////////////////////////
// Facet Goes to Type
//////////////////////////////////////////////////////////////////////////

  Void testFacetGoesToType()
  {
    idx := ProjectIndex()
    uriA := "file:///test/MyFacet.fan"
    uriB := "file:///test/App.fan"

    sourceA :=
      "class MyFacet\n" +
      "{\n" +
      "}"

    // Line 0: @MyFacet
    // Line 1: class App
    // Line 2: {
    // Line 3: }
    sourceB :=
      "@MyFacet\n" +
      "class App\n" +
      "{\n" +
      "}"

    idx.indexFile(uriA, sourceA)
    idx.indexFile(uriB, sourceB)

    // Position on "MyFacet" in @MyFacet at line 0, col 1
    pos := LspPosition(0, 3)
    result := svc.findDefinition(uriB, pos, sourceB, idx)

    verifyNotNull(result)
    verifyEq(result["uri"], uriA)
    range := result["range"] as Str:Obj?
    start := range["start"] as Str:Obj?
    verifyEq(start["line"], 0)
  }

//////////////////////////////////////////////////////////////////////////
// Enum Value Definition
//////////////////////////////////////////////////////////////////////////

  Void testEnumValueDefinition()
  {
    idx := ProjectIndex()
    uriA := "file:///test/Color.fan"
    uriB := "file:///test/Painter.fan"

    // Line 0: enum class Color
    // Line 1: {
    // Line 2:   red,
    // Line 3:   green,
    // Line 4:   blue
    // Line 5: }
    sourceA :=
      "enum class Color\n" +
      "{\n" +
      "  red,\n" +
      "  green,\n" +
      "  blue\n" +
      "}"

    // Line 0: class Painter
    // Line 1: {
    // Line 2:   Void paint()
    // Line 3:   {
    // Line 4:     c := Color.red
    // Line 5:   }
    // Line 6: }
    sourceB :=
      "class Painter\n" +
      "{\n" +
      "  Void paint()\n" +
      "  {\n" +
      "    c := Color.red\n" +
      "  }\n" +
      "}"

    idx.indexFile(uriA, sourceA)
    idx.indexFile(uriB, sourceB)

    // Position on "red" in "Color.red" at line 4, col 16
    pos := LspPosition(4, 16)
    result := svc.findDefinition(uriB, pos, sourceB, idx)

    verifyNotNull(result)
    verifyEq(result["uri"], uriA)
    range := result["range"] as Str:Obj?
    start := range["start"] as Str:Obj?
    // Should point to enum value "red" at line 2
    verifyEq(start["line"], 2)
  }

//////////////////////////////////////////////////////////////////////////
// Closure Param Definition
//////////////////////////////////////////////////////////////////////////

  Void testClosureParamDefinition()
  {
    idx := ProjectIndex()
    uri := "file:///test/Worker.fan"
    // Line 0: class Worker
    // Line 1: {
    // Line 2:   Void run()
    // Line 3:   {
    // Line 4:     items := ["a", "b"]
    // Line 5:     items.each |item|
    // Line 6:     {
    // Line 7:       echo(item)
    // Line 8:     }
    // Line 9:   }
    // Line 10: }
    source :=
      "class Worker\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    items := [\"a\", \"b\"]\n" +
      "    items.each |item|\n" +
      "    {\n" +
      "      echo(item)\n" +
      "    }\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Position on "item" at line 7, col 11
    pos := LspPosition(7, 11)
    result := svc.findDefinition(uri, pos, source, idx)

    // Should find the closure param "item"
    verifyNotNull(result)
    range := result["range"] as Str:Obj?
    start := range["start"] as Str:Obj?
    // item is declared at the closure line (line 5)
    verifyNotNull(start)
    startLine := start["line"] as Int
    // The closure param should be found (line 5 where |item| is)
    verify(startLine <= 7)
  }

//////////////////////////////////////////////////////////////////////////
// Static Const Field Cross-File (Type.FIELD where same name exists in current file)
//////////////////////////////////////////////////////////////////////////

  **
  ** Regression test: "Go to Definition" on the RHS of
  **   static const Str MY_CONST := Constants.MY_CONST
  ** must navigate to Constants.fan, NOT stay on the current line.
  ** Bug: step 0b only checked SymbolKind.enumVal, missing SymbolKind.field.
  **
  Void testStaticConstFieldCrossFile()
  {
    idx := ProjectIndex()
    uriConst  := "file:///test/Constants.fan"
    uriEntity := "file:///test/Entity.fan"

    // Constants.fan — defines the authoritative constant
    // Line 0: class Constants
    // Line 1: {
    // Line 2:   static const Str MY_CONST := "value"
    // Line 3: }
    sourceConst :=
      "class Constants\n" +
      "{\n" +
      "  static const Str MY_CONST := \"value\"\n" +
      "}"

    // Entity.fan — re-exports the constant; MY_CONST appears on both sides
    // Line 0: class Entity
    // Line 1: {
    // Line 2:   static const Str MY_CONST := Constants.MY_CONST
    // Line 3: }
    sourceEntity :=
      "class Entity\n" +
      "{\n" +
      "  static const Str MY_CONST := Constants.MY_CONST\n" +
      "}"

    idx.indexFile(uriConst,  sourceConst)
    idx.indexFile(uriEntity, sourceEntity)

    // Cursor on the RHS "MY_CONST" in "Constants.MY_CONST" at line 2.
    // "  static const Str MY_CONST := Constants." is 41 chars, so col 44 is inside MY_CONST.
    pos := LspPosition(2, 44)
    result := svc.findDefinition(uriEntity, pos, sourceEntity, idx)

    verifyNotNull(result)
    // Must navigate to Constants.fan, not stay in Entity.fan
    verifyEq(result["uri"], uriConst)
    range := result["range"] as Str:Obj?
    start := range["start"] as Str:Obj?
    // MY_CONST is declared at line 2 of Constants.fan
    verifyEq(start["line"], 2)
  }

  **
  ** Same-name static const field in the SAME file should still resolve correctly
  ** when the cursor is on its own declaration (LHS), not a cross-file reference.
  **
  Void testStaticConstFieldSameFileLhs()
  {
    idx := ProjectIndex()
    uri := "file:///test/Entity.fan"

    // Line 0: class Entity
    // Line 1: {
    // Line 2:   static const Str MY_CONST := "val"
    // Line 3: }
    source :=
      "class Entity\n" +
      "{\n" +
      "  static const Str MY_CONST := \"val\"\n" +
      "}"

    idx.indexFile(uri, source)

    // Cursor on the LHS "MY_CONST" (no dot before it) at line 2, col 20
    pos := LspPosition(2, 20)
    result := svc.findDefinition(uri, pos, source, idx)

    verifyNotNull(result)
    // Must stay in Entity.fan at line 2
    verifyEq(result["uri"], uri)
    range := result["range"] as Str:Obj?
    start := range["start"] as Str:Obj?
    verifyEq(start["line"], 2)
  }

  **
  ** Static method on a type: TypeName.method() should navigate cross-file even
  ** when a same-named member exists locally (covers the findMemberSymbol path).
  **
  Void testStaticMemberWithAmbiguousLocalName()
  {
    idx := ProjectIndex()
    uriLib    := "file:///test/Lib.fan"
    uriCaller := "file:///test/Caller.fan"

    // Lib.fan — defines process() as a static method
    // Line 0: class Lib
    // Line 1: {
    // Line 2:   static Void process(Str s) {}
    // Line 3: }
    sourceLib :=
      "class Lib\n" +
      "{\n" +
      "  static Void process(Str s) {}\n" +
      "}"

    // Caller.fan — also has a local method named process, AND calls Lib.process(...)
    // Line 0: class Caller
    // Line 1: {
    // Line 2:   Void process() {}
    // Line 3:   Void run()
    // Line 4:   {
    // Line 5:     Lib.process("x")
    // Line 6:   }
    // Line 7: }
    sourceCaller :=
      "class Caller\n" +
      "{\n" +
      "  Void process() {}\n" +
      "  Void run()\n" +
      "  {\n" +
      "    Lib.process(\"x\")\n" +
      "  }\n" +
      "}"

    idx.indexFile(uriLib,    sourceLib)
    idx.indexFile(uriCaller, sourceCaller)

    // Cursor on "process" in "Lib.process" at line 5.
    // "    Lib." is 8 chars, so col 8 is the start of "process"
    pos := LspPosition(5, 10)
    result := svc.findDefinition(uriCaller, pos, sourceCaller, idx)

    verifyNotNull(result)
    // Must navigate to Lib.fan, not Caller.fan
    verifyEq(result["uri"], uriLib)
    range := result["range"] as Str:Obj?
    start := range["start"] as Str:Obj?
    // process() is declared at line 2 of Lib.fan
    verifyEq(start["line"], 2)
  }

//////////////////////////////////////////////////////////////////////////
// Type Reference Without Parens Goes to Class
//////////////////////////////////////////////////////////////////////////

  Void testTypeReferenceWithoutParensGoesToClass()
  {
    idx := ProjectIndex()
    uriA := "file:///test/BacnetServer.fan"
    uriB := "file:///test/Lib.fan"

    sourceA :=
      "class BacnetServer\n" +
      "{\n" +
      "  new make(Obj cx, Obj siteId) {}\n" +
      "}"

    // BacnetServer without ( — not a constructor call, should go to class
    sourceB :=
      "class Lib : BacnetServer\n" +
      "{\n" +
      "}"

    idx.indexFile(uriA, sourceA)
    idx.indexFile(uriB, sourceB)

    // Position on "BacnetServer" in inheritance clause (no parens after)
    pos := LspPosition(0, 14)
    result := svc.findDefinition(uriB, pos, sourceB, idx)

    verifyNotNull(result)
    verifyEq(result["uri"], uriA)
    range := result["range"] as Str:Obj?
    start := range["start"] as Str:Obj?
    // Should point to the class declaration at line 0
    verifyEq(start["line"], 0)
  }

//////////////////////////////////////////////////////////////////////////
// Instance method call via dot should NOT resolve to same-named param
//////////////////////////////////////////////////////////////////////////

  **
  ** Regression: _logger.debug("...") where the enclosing method has a Bool
  ** debug parameter — go-to-definition on "debug" after the dot must navigate
  ** to the debug() method declaration, not to the Bool debug parameter.
  **
  Void testInstanceMethodCallNotShadowedByParam()
  {
    idx := ProjectIndex()
    uriLogger := "file:///test/Logger.fan"
    uriCaller := "file:///test/Caller.fan"

    // Logger.fan — defines a debug(Str) method
    // Line 0: class Logger
    // Line 1: {
    // Line 2:   Void debug(Str msg) {}
    // Line 3: }
    sourceLogger :=
      "class Logger\n" +
      "{\n" +
      "  Void debug(Str msg) {}\n" +
      "}"

    // Caller.fan — has a Bool debug parameter AND calls _logger.debug(...)
    // Line 0: class Caller
    // Line 1: {
    // Line 2:   Logger _logger := Logger()
    // Line 3:   Void run(Bool debug)
    // Line 4:   {
    // Line 5:     _logger.debug("hello")
    // Line 6:   }
    // Line 7: }
    sourceCaller :=
      "class Caller\n" +
      "{\n" +
      "  Logger _logger := Logger()\n" +
      "  Void run(Bool debug)\n" +
      "  {\n" +
      "    _logger.debug(\"hello\")\n" +
      "  }\n" +
      "}"

    idx.indexFile(uriLogger, sourceLogger)
    idx.indexFile(uriCaller, sourceCaller)

    // Cursor on "debug" in "_logger.debug(" at line 5.
    // "    _logger." is 12 chars, so col 12 is start of "debug"
    pos := LspPosition(5, 13)
    result := svc.findDefinition(uriCaller, pos, sourceCaller, idx)

    verifyNotNull(result)
    // Must navigate to Logger.fan (the method), not the param in Caller.fan
    verifyEq(result["uri"], uriLogger)
    range := result["range"] as Str:Obj?
    start := range["start"] as Str:Obj?
    // debug() method is declared at line 2 of Logger.fan
    verifyEq(start["line"], 2)
  }
}
