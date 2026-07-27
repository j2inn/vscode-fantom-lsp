//
// Copyright (c) 2026, Brian Frank and Andy Frank
// Licensed under the Academic Free License version 3.0
//
// History:
//   26 Jul 26  Creation
//

using compiler

**
** TypeDefinitionServiceTest - Tests for go-to-type-definition
**
class TypeDefinitionServiceTest : Test
{
  private TypeDefinitionService svc := TypeDefinitionService()

  ** Unwrap the "location" branch of a findTypeDefinition result and assert
  ** it points at the given 0-based declaration line.
  private Void verifyLocationAtLine(Str:Obj? result, Int expectedLine)
  {
    verifyNotNull(result)
    location := result["location"] as Str:Obj?
    verifyNotNull(location)
    range := location["range"] as Str:Obj?
    verifyNotNull(range)
    start := range["start"] as Str:Obj?
    verifyNotNull(start)
    verifyEq(start["line"], expectedLine)
  }

//////////////////////////////////////////////////////////////////////////
// Type Definition of Local Variable
//////////////////////////////////////////////////////////////////////////

  Void testTypeDefinitionLocalVar()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    // Line 0: class Bar
    // Line 1: {
    // Line 2: }
    // Line 3: class Foo
    // Line 4: {
    // Line 5:   Void method()
    // Line 6:   {
    // Line 7:     Bar b := Bar()
    // Line 8:     b.toStr
    // Line 9:   }
    // Line 10: }
    source :=
      "class Bar\n" +
      "{\n" +
      "}\n" +
      "class Foo\n" +
      "{\n" +
      "  Void method()\n" +
      "  {\n" +
      "    Bar b := Bar()\n" +
      "    b.toStr\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Position on "b" at line 8, col 4
    pos := LspPosition(8, 4)
    result := svc.findTypeDefinition(uri, pos, source, idx)

    // Should point to "class Bar" declaration at line 0
    verifyLocationAtLine(result, 0)
    location := result["location"] as Str:Obj?
    verifyEq(location["uri"], uri)
  }

//////////////////////////////////////////////////////////////////////////
// Type Definition of Method Parameter
//////////////////////////////////////////////////////////////////////////

  Void testTypeDefinitionParam()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    // Line 0: class Baz
    // Line 1: {
    // Line 2: }
    // Line 3: class Foo
    // Line 4: {
    // Line 5:   Void method(Baz p)
    // Line 6:   {
    // Line 7:     p.toStr
    // Line 8:   }
    // Line 9: }
    source :=
      "class Baz\n" +
      "{\n" +
      "}\n" +
      "class Foo\n" +
      "{\n" +
      "  Void method(Baz p)\n" +
      "  {\n" +
      "    p.toStr\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Position on "p" at line 7, col 4
    pos := LspPosition(7, 4)
    result := svc.findTypeDefinition(uri, pos, source, idx)

    // Should point to "class Baz" declaration at line 0
    verifyLocationAtLine(result, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Type Definition of Bare (Parenthesis-less) Zero-Arg Method Call
//////////////////////////////////////////////////////////////////////////

  **
  ** Regression: `entityReferenceable != null` where entityReferenceable() is
  ** a zero-arg method invoked without parens. resolveVarType only recognizes
  ** declarations ("Type x") and assignments ("x := ..."), so a naked method
  ** call used as a boolean expression previously resolved to nothing.
  **
  Void testTypeDefinitionBareMethodCall()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    // Line 0: class Widget
    // Line 1: {
    // Line 2: }
    // Line 3: class Foo
    // Line 4: {
    // Line 5:   Bool hasWidget()
    // Line 6:   {
    // Line 7:     return widget != null
    // Line 8:   }
    // Line 9:   Widget? widget()
    // Line 10:   {
    // Line 11:     return null
    // Line 12:   }
    // Line 13: }
    source :=
      "class Widget\n" +
      "{\n" +
      "}\n" +
      "class Foo\n" +
      "{\n" +
      "  Bool hasWidget()\n" +
      "  {\n" +
      "    return widget != null\n" +
      "  }\n" +
      "  Widget? widget()\n" +
      "  {\n" +
      "    return null\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Position on "widget" at line 7, col 11 (bare call, no parens)
    pos := LspPosition(7, 11)
    result := svc.findTypeDefinition(uri, pos, source, idx)

    // Should point to "class Widget" declaration at line 0
    verifyLocationAtLine(result, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Type Definition of Parameter in a Multi-Line Parameter List
//////////////////////////////////////////////////////////////////////////

  **
  ** Regression: constructors/methods with one parameter per line (a common
  ** style for long signatures) were never resolved by TypeResolver's method-
  ** parameter scan, which only recognizes a parameter list that opens and
  ** closes on the same source line.
  **
  Void testTypeDefinitionParamInMultiLineSignature()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    // Line 0: class Widget
    // Line 1: {
    // Line 2: }
    // Line 3: class Foo
    // Line 4: {
    // Line 5:   new make(
    // Line 6:     Widget widget,
    // Line 7:     Str name)
    // Line 8:   {
    // Line 9:     x := widget
    // Line 10:   }
    // Line 11: }
    source :=
      "class Widget\n" +
      "{\n" +
      "}\n" +
      "class Foo\n" +
      "{\n" +
      "  new make(\n" +
      "    Widget widget,\n" +
      "    Str name)\n" +
      "  {\n" +
      "    x := widget\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Position on "widget" at line 6 (its own declaration line)
    declPos := LspPosition(6, 11)
    declResult := svc.findTypeDefinition(uri, declPos, source, idx)
    verifyLocationAtLine(declResult, 0)

    // Position on "widget" at its usage site, line 9
    usePos := LspPosition(9, 9)
    useResult := svc.findTypeDefinition(uri, usePos, source, idx)
    verifyLocationAtLine(useResult, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Type Definition of Field
//////////////////////////////////////////////////////////////////////////

  Void testTypeDefinitionField()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    // Line 0: class Widget
    // Line 1: {
    // Line 2: }
    // Line 3: class Foo
    // Line 4: {
    // Line 5:   Widget widget
    // Line 6:   Void method()
    // Line 7:   {
    // Line 8:     widget.toStr
    // Line 9:   }
    // Line 10: }
    source :=
      "class Widget\n" +
      "{\n" +
      "}\n" +
      "class Foo\n" +
      "{\n" +
      "  Widget widget\n" +
      "  Void method()\n" +
      "  {\n" +
      "    widget.toStr\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Position on "widget" at line 8, col 5
    pos := LspPosition(8, 5)
    result := svc.findTypeDefinition(uri, pos, source, idx)

    // Should point to "class Widget" declaration at line 0
    verifyLocationAtLine(result, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Type Definition of a Type Name Itself
//////////////////////////////////////////////////////////////////////////

  Void testTypeDefinitionOnTypeNameJumpsToItself()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar() {}\n" +
      "}"

    idx.indexFile(uri, source)

    // Position on "Foo" at line 0, col 6 (the type name in the class declaration)
    pos := LspPosition(0, 6)
    result := svc.findTypeDefinition(uri, pos, source, idx)

    verifyLocationAtLine(result, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Cross-File Type Definition
//////////////////////////////////////////////////////////////////////////

  Void testCrossFileTypeDefinition()
  {
    idx := ProjectIndex()
    barUri := "file:///test/Bar.fan"
    barSource :=
      "class Bar\n" +
      "{\n" +
      "}"
    idx.indexFile(barUri, barSource)

    fooUri := "file:///test/Foo.fan"
    // Line 0: class Foo
    // Line 1: {
    // Line 2:   Void method()
    // Line 3:   {
    // Line 4:     Bar b := Bar()
    // Line 5:     b.toStr
    // Line 6:   }
    // Line 7: }
    fooSource :=
      "class Foo\n" +
      "{\n" +
      "  Void method()\n" +
      "  {\n" +
      "    Bar b := Bar()\n" +
      "    b.toStr\n" +
      "  }\n" +
      "}"
    idx.indexFile(fooUri, fooSource)

    // Position on "b" at line 5, col 4
    pos := LspPosition(5, 4)
    result := svc.findTypeDefinition(fooUri, pos, fooSource, idx)

    verifyLocationAtLine(result, 0)
    location := result["location"] as Str:Obj?
    verifyEq(location["uri"], barUri)
  }

//////////////////////////////////////////////////////////////////////////
// Graceful Fallback When Type Cannot Be Inferred At All
//////////////////////////////////////////////////////////////////////////

  Void testTypeDefinitionUnknownWordReturnsNull()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    doesNotExist.toStr\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Position on "doesNotExist" at line 4, col 4 — not declared anywhere
    pos := LspPosition(4, 4)
    result := svc.findTypeDefinition(uri, pos, source, idx)

    verifyNull(result)
  }

//////////////////////////////////////////////////////////////////////////
// "No Source Available" Result for Built-In / External Types
//////////////////////////////////////////////////////////////////////////

  **
  ** When the type resolves but has no project-local source (e.g. a sys
  ** type), the result should carry a "noSourceTypeName" descriptor instead
  ** of silently returning null, so the caller can surface an explanatory
  ** message to the user.
  **
  Void testTypeDefinitionSysTypeReturnsNoSourceDescriptor()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    // Line 0: class Foo
    // Line 1: {
    // Line 2:   Void bar()
    // Line 3:   {
    // Line 4:     Str s := "hi"
    // Line 5:     s.toStr
    // Line 6:   }
    // Line 7: }
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    Str s := \"hi\"\n" +
      "    s.toStr\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Position on "s" at line 5, col 4 — type is sys::Str, not in the project index
    pos := LspPosition(5, 4)
    result := svc.findTypeDefinition(uri, pos, source, idx)

    verifyNotNull(result)
    verifyNull(result["location"])
    verifyEq(result["noSourceTypeName"], "Str")
    verifyEq(result["noSourcePod"], "sys")
  }

//////////////////////////////////////////////////////////////////////////
// Result Structure
//////////////////////////////////////////////////////////////////////////

  Void testTypeDefinitionResultHasCorrectStructure()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    source :=
      "class Bar\n" +
      "{\n" +
      "}\n" +
      "class Foo\n" +
      "{\n" +
      "  Void method()\n" +
      "  {\n" +
      "    Bar b := Bar()\n" +
      "    b.toStr\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    pos := LspPosition(8, 4)
    result := svc.findTypeDefinition(uri, pos, source, idx)

    verifyNotNull(result)
    location := result["location"] as Str:Obj?
    verifyNotNull(location)
    verifyNotNull(location["uri"])
    range := location["range"] as Str:Obj?
    verifyNotNull(range)
    start := range["start"] as Str:Obj?
    end := range["end"] as Str:Obj?
    verifyNotNull(start)
    verifyNotNull(end)
    verifyNotNull(start["line"])
    verifyNotNull(start["character"])
    verifyNotNull(end["line"])
    verifyNotNull(end["character"])
  }
}
