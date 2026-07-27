//
// Copyright (c) 2026, Brian Frank and Andy Frank
// Licensed under the Academic Free License version 3.0
//
// History:
//   27 Jul 26  Creation
//

using compiler

**
** InlayHintServiceTest - Tests for inline type and parameter-name hints
**
class InlayHintServiceTest : Test
{
  private InlayHintService svc := InlayHintService()

  private LspRange wholeFile(Str source)
  {
    lineCount := source.splitLines.size
    return LspRange(LspPosition(0, 0), LspPosition(lineCount, 0))
  }

  private Str:Obj? findHintAt([Str:Obj?][] hints, Int line, Int character)
  {
    hint := hints.find |h|
    {
      pos := h["position"] as Str:Obj?
      return pos["line"] == line && pos["character"] == character
    }
    verifyNotNull(hint)
    return hint
  }

//////////////////////////////////////////////////////////////////////////
// Type Hint on Inferred Declaration
//////////////////////////////////////////////////////////////////////////

  Void testTypeHintOnInferredLocalVar()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    // Line 0: class Widget
    // Line 1: {
    // Line 2: }
    // Line 3: class Foo
    // Line 4: {
    // Line 5:   Widget make() { return Widget() }
    // Line 6:   Void run()
    // Line 7:   {
    // Line 8:     x := make()
    // Line 9:   }
    // Line 10: }
    source :=
      "class Widget\n" +
      "{\n" +
      "}\n" +
      "class Foo\n" +
      "{\n" +
      "  Widget make() { return Widget() }\n" +
      "  Void run()\n" +
      "  {\n" +
      "    x := make()\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    hints := svc.computeHints(uri, wholeFile(source), source, idx)

    // "x" starts at col 4 on line 8, ends at col 5 — hint attaches right after
    hint := findHintAt(hints, 8, 5)
    verifyEq(hint["label"], ": Widget")
    verifyEq(hint["kind"], 1)
  }

  Void testNoTypeHintOnExplicitDeclaration()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    Str x := \"hi\"\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    hints := svc.computeHints(uri, wholeFile(source), source, idx)

    // "x" is explicitly typed — must NOT get a type hint
    typeHints := hints.findAll { it["kind"] == 1 }
    verifyEq(typeHints.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Parameter-Name Hints at Call Sites
//////////////////////////////////////////////////////////////////////////

  Void testParamHintsOnProjectLocalMethodCall()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    // Line 0: class Foo
    // Line 1: {
    // Line 2:   Void insert(Int index, Str item) {}
    // Line 3:   Void run()
    // Line 4:   {
    // Line 5:     insert(0, "a")
    // Line 6:   }
    // Line 7: }
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void insert(Int index, Str item) {}\n" +
      "  Void run()\n" +
      "  {\n" +
      "    insert(0, \"a\")\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    hints := svc.computeHints(uri, wholeFile(source), source, idx, false)
    paramHints := hints.findAll { it["kind"] == 2 }
    verifyEq(paramHints.size, 2)

    indexHint := findHintAt(hints, 5, 11)
    verifyEq(indexHint["label"], "index:")
    itemHint := findHintAt(hints, 5, 14)
    verifyEq(itemHint["label"], "item:")
  }

  Void testSingleParamCallSkippedByDefault()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void setName(Str name) {}\n" +
      "  Void run()\n" +
      "  {\n" +
      "    setName(\"a\")\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    hints := svc.computeHints(uri, wholeFile(source), source, idx, true)
    paramHints := hints.findAll { it["kind"] == 2 }
    verifyEq(paramHints.size, 0)
  }

  Void testSingleParamCallShownWhenNotSkipped()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void setName(Str name) {}\n" +
      "  Void run()\n" +
      "  {\n" +
      "    setName(\"a\")\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    hints := svc.computeHints(uri, wholeFile(source), source, idx, false)
    paramHints := hints.findAll { it["kind"] == 2 }
    verifyEq(paramHints.size, 1)
    verifyEq(paramHints[0]["label"], "name:")
  }

  Void testParamHintSkippedWhenArgTextMatchesName()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    // "index" argument is a variable named exactly like the parameter —
    // hinting "index: index" would be redundant noise.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void insert(Int index, Str item) {}\n" +
      "  Void run(Int index)\n" +
      "  {\n" +
      "    insert(index, \"a\")\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    hints := svc.computeHints(uri, wholeFile(source), source, idx, false)
    paramHints := hints.findAll { it["kind"] == 2 }
    verifyEq(paramHints.size, 1)
    verifyEq(paramHints[0]["label"], "item:")
  }

//////////////////////////////////////////////////////////////////////////
// Range Restriction
//////////////////////////////////////////////////////////////////////////

  Void testHintsRestrictedToRequestedRange()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    // Line 0: class Foo
    // Line 1: {
    // Line 2:   Void run()
    // Line 3:   {
    // Line 4:     a := 1
    // Line 5:     b := 2
    // Line 6:   }
    // Line 7: }
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    a := 1\n" +
      "    b := 2\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Restrict to just line 4 (the "a" declaration)
    range := LspRange(LspPosition(4, 0), LspPosition(4, 20))
    hints := svc.computeHints(uri, range, source, idx)

    typeHints := hints.findAll { it["kind"] == 1 }
    verifyEq(typeHints.size, 1)
    verifyEq(typeHints[0]["label"], ": Int")
  }

//////////////////////////////////////////////////////////////////////////
// No Hints When Nothing to Show
//////////////////////////////////////////////////////////////////////////

  Void testNoHintsOnEmptyMethodBody()
  {
    idx := ProjectIndex()
    uri := "file:///test/Foo.fan"
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run() {}\n" +
      "}"

    idx.indexFile(uri, source)

    hints := svc.computeHints(uri, wholeFile(source), source, idx)
    verifyEq(hints.size, 0)
  }
}
