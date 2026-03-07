//
// Copyright (c) 2025, Brian Frank and Andy Frank
// Licensed under the Academic Free License version 3.0
//
// History:
//   12 Feb 26  Creation
//

**
** CompletionServiceTest - Tests for autocompletion type inference.
**
class CompletionServiceTest : Test
{
  private CompletionServiceBuilderFacade svc := CompletionServiceBuilderFacade(CompletionService())
  private ProjectIndex idx := ProjectIndex()

//////////////////////////////////////////////////////////////////////////
// Inferred type from right-hand side expression
//////////////////////////////////////////////////////////////////////////

  Void testInferredListLiteral()
  {
    // a := [1,2,3] → inferred as List, a. should show List methods
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := [1,2,3]\n" +
      "    a.\n" +
      "  }\n" +
      "}"

    // Cursor on line 5 (0-based), after "a."
    pos := LspPosition(5, 6)
    items := svc.complete("file:///test/Foo.fan", pos, source, idx)

    // Should have List methods like "add", "each", "size", "map"
    labels := items.map |item| { item.label }
    verify(labels.contains("add"))
    verify(labels.contains("each"))
    verify(labels.contains("size"))
    verify(labels.contains("map"))
  }

  Void testInferredStrLiteral()
  {
    // s := "hello" → inferred as Str, s. should show Str methods
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    s := \"hello\"\n" +
      "    s.\n" +
      "  }\n" +
      "}"

    pos := LspPosition(5, 6)
    items := svc.complete("file:///test/Foo.fan", pos, source, idx)

    labels := items.map |item| { item.label }
    verify(labels.contains("size"))
    verify(labels.contains("contains"))
    verify(labels.contains("trim"))
    verify(labels.contains("split"))
  }

  Void testInferredMapLiteral()
  {
    // m := ["a":1, "b":2] → inferred as Map, m. should show Map methods
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    m := [\"a\":1, \"b\":2]\n" +
      "    m.\n" +
      "  }\n" +
      "}"

    pos := LspPosition(5, 6)
    items := svc.complete("file:///test/Foo.fan", pos, source, idx)

    labels := items.map |item| { item.label }
    verify(labels.contains("get"))
    verify(labels.contains("set"))
    verify(labels.contains("keys"))
    verify(labels.contains("each"))
  }

  Void testInferredIntLiteral()
  {
    // n := 42 → inferred as Int, n. should show Int methods
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    n := 42\n" +
      "    n.\n" +
      "  }\n" +
      "}"

    pos := LspPosition(5, 6)
    items := svc.complete("file:///test/Foo.fan", pos, source, idx)

    labels := items.map |item| { item.label }
    verify(labels.contains("toStr"))
    verify(labels.contains("max"))
    verify(labels.contains("abs"))
  }

  Void testExplicitTypeStillWorks()
  {
    // Str a := "hello" → explicit Str type, a. should show Str methods
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    Str a := \"hello\"\n" +
      "    a.\n" +
      "  }\n" +
      "}"

    pos := LspPosition(5, 6)
    items := svc.complete("file:///test/Foo.fan", pos, source, idx)

    labels := items.map |item| { item.label }
    verify(labels.contains("size"))
    verify(labels.contains("trim"))
  }

//////////////////////////////////////////////////////////////////////////
// Static type access: TypeName.
//////////////////////////////////////////////////////////////////////////

  Void testStaticTypeAccess()
  {
    // Str. should show Str static and instance methods
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    Str.\n" +
      "  }\n" +
      "}"

    pos := LspPosition(4, 8)
    items := svc.complete("file:///test/Foo.fan", pos, source, idx)

    labels := items.map |item| { item.label }
    verify(labels.contains("defVal"))
    verify(labels.contains("fromChars"))
  }

  Void testStaticProjectTypeAccess()
  {
    // MyClass. should show members from project index
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    MyClass.\n" +
      "  }\n" +
      "}"

    idxWithType := ProjectIndex()
    idxWithType.indexFile("file:///test/MyClass.fan",
      "class MyClass\n" +
      "{\n" +
      "  static Void doSomething() {}\n" +
      "  Str name\n" +
      "}")

    pos := LspPosition(4, 12)
    items := svc.complete("file:///test/Foo.fan", pos, source, idxWithType)

    labels := items.map |item| { item.label }
    verify(labels.contains("doSomething"))
    verify(labels.contains("name"))
  }

//////////////////////////////////////////////////////////////////////////
// In-scope identifier completion (non-member)
//////////////////////////////////////////////////////////////////////////

  Void testSuggestMethodParameterInsideMethod()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(Str userName, Int count)\n" +
      "  {\n" +
      "    us\n" +
      "  }\n" +
      "}"

    // Cursor after "us"
    pos := LspPosition(4, 6)
    items := svc.complete("file:///test/Foo.fan", pos, source, idx)

    userItem := items.find |item| { item.label == "userName" }
    verifyNotNull(userItem)
    verifyEq(userItem.kind, CompletionItemKind.variable)
  }

  Void testSuggestFreshlyDeclaredObjectVariable()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    serviceClient := HttpClient()\n" +
      "    service\n" +
      "  }\n" +
      "}"

    // Cursor after "service"
    pos := LspPosition(5, 11)
    items := svc.complete("file:///test/Foo.fan", pos, source, idx)

    svcItem := items.find |item| { item.label == "serviceClient" }
    verifyNotNull(svcItem)
    verifyEq(svcItem.kind, CompletionItemKind.variable)
  }

  Void testSuggestFieldInMethodBody()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Str status := \"ok\"\n" +
      "\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    sta\n" +
      "  }\n" +
      "}"

    // Cursor after "sta"
    pos := LspPosition(6, 7)
    items := svc.complete("file:///test/Foo.fan", pos, source, idx)

    statusItem := items.find |item| { item.label == "status" }
    verifyNotNull(statusItem)
    verifyEq(statusItem.kind, CompletionItemKind.field)
  }

  Void testSuggestMethodParameterWithMultilineSignature()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(\n" +
      "    Str userName,\n" +
      "    Int count)\n" +
      "  {\n" +
      "    us\n" +
      "  }\n" +
      "}"

    // Cursor after "us"
    pos := LspPosition(6, 6)
    items := svc.complete("file:///test/Foo.fan", pos, source, idx)

    userItem := items.find |item| { item.label == "userName" }
    verifyNotNull(userItem)
    verifyEq(userItem.kind, CompletionItemKind.variable)
  }

  Void testSuggestLocalVarWithMultilineSignature()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(\n" +
      "    Str userName)\n" +
      "  {\n" +
      "    serviceClient := HttpClient()\n" +
      "    service\n" +
      "  }\n" +
      "}"

    // Cursor after "service"
    pos := LspPosition(6, 11)
    items := svc.complete("file:///test/Foo.fan", pos, source, idx)

    svcItem := items.find |item| { item.label == "serviceClient" }
    verifyNotNull(svcItem)
    verifyEq(svcItem.kind, CompletionItemKind.variable)
  }

  Void testDoesNotLeakLocalsFromOtherMethods()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void first()\n" +
      "  {\n" +
      "    serviceOne := HttpClient()\n" +
      "  }\n" +
      "\n" +
      "  Void second()\n" +
      "  {\n" +
      "    serviceTwo := HttpClient()\n" +
      "    service\n" +
      "  }\n" +
      "}"

    // Cursor after "service" in second()
    pos := LspPosition(10, 11)
    items := svc.complete("file:///test/Foo.fan", pos, source, idx)

    serviceTwo := items.find |item| { item.label == "serviceTwo" }
    verifyNotNull(serviceTwo)

    serviceOne := items.find |item| { item.label == "serviceOne" }
    verifyNull(serviceOne)
  }

//////////////////////////////////////////////////////////////////////////
// No duplicate completions
//////////////////////////////////////////////////////////////////////////

  Void testNoDuplicateCompletions()
  {
    // a := "hello" then a. should not produce duplicate method names
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := \"hello\"\n" +
      "    a.\n" +
      "  }\n" +
      "}"

    pos := LspPosition(5, 6)
    items := svc.complete("file:///test/Foo.fan", pos, source, idx)

    // Check that no label appears more than once
    labels := items.map |item| { item.label }
    unique := Str:Int[:]
    labels.each |l| { unique[l] = (unique[l] ?: 0) + 1 }
    duplicates := unique.findAll |count, name| { count > 1 }
    verifyEq(duplicates.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Documentation in completions
//////////////////////////////////////////////////////////////////////////

  Void testCompletionHasDocumentation()
  {
    // Index a type with documented methods
    idxWithDocs := ProjectIndex()
    idxWithDocs.indexFile("file:///test/MyService.fan",
      "class MyService\n" +
      "{\n" +
      "  **\n" +
      "  ** Finds a record by its unique identifier.\n" +
      "  **\n" +
      "  Str findById(Int id) { return \"\" }\n" +
      "\n" +
      "  ** Returns the total count.\n" +
      "  Int count() { return 0 }\n" +
      "\n" +
      "  Void noDoc() {}\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    svc := MyService()\n" +
      "    svc.\n" +
      "  }\n" +
      "}"

    pos := LspPosition(5, 8)
    items := svc.complete("file:///test/Foo.fan", pos, source, idxWithDocs)

    // findById should have documentation
    findByIdItem := items.find |item| { item.label == "findById" }
    verifyNotNull(findByIdItem)
    verifyNotNull(findByIdItem.documentation)
    verify(findByIdItem.documentation.contains("Finds a record"))

    // count should have documentation
    countItem := items.find |item| { item.label == "count" }
    verifyNotNull(countItem)
    verifyNotNull(countItem.documentation)
    verify(countItem.documentation.contains("total count"))

    // noDoc should have no documentation
    noDocItem := items.find |item| { item.label == "noDoc" }
    verifyNotNull(noDocItem)
    verifyNull(noDocItem.documentation)
  }

  Void testCompletionHasDetail()
  {
    // Detail should show method signature
    idxWithType := ProjectIndex()
    idxWithType.indexFile("file:///test/Calc.fan",
      "class Calc\n" +
      "{\n" +
      "  ** Add two numbers.\n" +
      "  Int add(Int a, Int b) { return a + b }\n" +
      "\n" +
      "  Str name\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    c := Calc()\n" +
      "    c.\n" +
      "  }\n" +
      "}"

    pos := LspPosition(5, 6)
    items := svc.complete("file:///test/Foo.fan", pos, source, idxWithType)

    addItem := items.find |item| { item.label == "add" }
    verifyNotNull(addItem)
    verifyNotNull(addItem.detail)
    verify(addItem.detail.contains("add"))
    verify(addItem.detail.contains("Int"))

    nameItem := items.find |item| { item.label == "name" }
    verifyNotNull(nameItem)
  }

//////////////////////////////////////////////////////////////////////////
// Parameter snippet insertion
//////////////////////////////////////////////////////////////////////////

  Void testCompletionHasParameterSnippet()
  {
    idxWithType := ProjectIndex()
    idxWithType.indexFile("file:///test/Calc.fan",
      "class Calc\n" +
      "{\n" +
      "  Int add(Int a, Int b) { return a + b }\n" +
      "  Void reset() {}\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    c := Calc()\n" +
      "    c.\n" +
      "  }\n" +
      "}"

    pos := LspPosition(5, 6)
    items := svc.complete("file:///test/Foo.fan", pos, source, idxWithType)

    // add() should have snippet with parameter placeholders
    addItem := items.find |item| { item.label == "add" }
    verifyNotNull(addItem)
    verifyNotNull(addItem.insertText)
    verifyEq(addItem.insertTextFormat, 2) // Snippet format
    verify(addItem.insertText.contains("\${1:a}"))
    verify(addItem.insertText.contains("\${2:b}"))
    verify(addItem.insertText.startsWith("add("))
    verify(addItem.insertText.endsWith(")"))

    // reset() has no params, should NOT have snippet
    resetItem := items.find |item| { item.label == "reset" }
    verifyNotNull(resetItem)
    verifyNull(resetItem.insertText)
    verifyNull(resetItem.insertTextFormat)
  }

  Void testCompletionSnippetMultipleParams()
  {
    idxWithType := ProjectIndex()
    idxWithType.indexFile("file:///test/Builder.fan",
      "class Builder\n" +
      "{\n" +
      "  ** Configure the builder with name and options.\n" +
      "  Void configure(Str name, Int timeout, Bool verbose) {}\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    b := Builder()\n" +
      "    b.\n" +
      "  }\n" +
      "}"

    pos := LspPosition(5, 6)
    items := svc.complete("file:///test/Foo.fan", pos, source, idxWithType)

    configItem := items.find |item| { item.label == "configure" }
    verifyNotNull(configItem)
    verifyNotNull(configItem.insertText)
    verifyEq(configItem.insertText, "configure(\${1:name}, \${2:timeout}, \${3:verbose})")
    verifyEq(configItem.insertTextFormat, 2)
    // Documentation should be present
    verifyNotNull(configItem.documentation)
    verify(configItem.documentation.contains("Configure the builder"))
  }

//////////////////////////////////////////////////////////////////////////
// Documentation as MarkupContent in toMap
//////////////////////////////////////////////////////////////////////////

  Void testDocumentationMarkupContent()
  {
    item := CompletionItem("foo", CompletionItemKind.method, "Void foo()", "This is **bold** docs")
    map := item.toMap
    docObj := map["documentation"]
    verifyNotNull(docObj)
    // Should be a MarkupContent map with kind=markdown
    verify(docObj is Map)
    docMap := (Str:Obj)docObj
    verifyEq(docMap["kind"], "markdown")
    verifyEq(docMap["value"], "This is **bold** docs")
  }

//////////////////////////////////////////////////////////////////////////
// Doc comment extraction utility
//////////////////////////////////////////////////////////////////////////

  Void testExtractDocComment()
  {
    lines :=
      ["",
       "**",
       "** Finds a record by its unique identifier.",
       "** Returns null if not found.",
       "**",
       "Str? findById(Int id) { return null }"]

    doc := ProjectIndex.extractDocComment(lines, 5)
    verifyNotNull(doc)
    verify(doc.contains("Finds a record"))
    verify(doc.contains("Returns null"))
  }

  Void testExtractDocCommentSingleLine()
  {
    lines :=
      ["",
       "** Simple doc.",
       "Void foo() {}"]

    doc := ProjectIndex.extractDocComment(lines, 2)
    verifyNotNull(doc)
    verifyEq(doc, "Simple doc.")
  }

  Void testExtractDocCommentNone()
  {
    lines :=
      ["",
       "Void foo() {}"]

    doc := ProjectIndex.extractDocComment(lines, 1)
    verifyNull(doc)
  }
}

internal class CompletionServiceBuilderFacade
{
  private CompletionService service

  new make(CompletionService service)
  {
    this.service = service
  }

  CompletionItem[] complete(Str uri, LspPosition pos, Str source, ProjectIndex index)
  {
    request := CompletionRequestBuilder()
      .withUri(uri)
      .withPos(pos)
      .withSource(source)
      .withIndex(index)
      .build

    return service.completeRequest(request)
  }
}
