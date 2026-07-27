//
// Copyright (c) 2025, Brian Frank and Andy Frank
// Licensed under the Academic Free License version 3.0
//
// History:
//   11 Feb 26  Creation
//

**
** ProjectIndexTest - Tests for ProjectIndex symbol indexing and lookup
**
class ProjectIndexTest : Test
{

//////////////////////////////////////////////////////////////////////////
// Builder Pattern
//////////////////////////////////////////////////////////////////////////

  Void testInitRequestBuilder()
  {
    request := ProjectIndexInitRequestBuilder()
      .withWorkspaceRootUri("file:///tmp/workspace/")
      .build

    verifyEq(request.workspaceRootUri, "file:///tmp/workspace/")
  }

//////////////////////////////////////////////////////////////////////////
// Index Valid Class
//////////////////////////////////////////////////////////////////////////

  Void testIndexValidClass()
  {
    idx := ProjectIndex()
    uri := "file:///test/Person.fan"
    source :=
      "using sys\n" +
      "\n" +
      "class Person\n" +
      "{\n" +
      "  Str name\n" +
      "  Int age\n" +
      "\n" +
      "  Void greet(Str greeting)\n" +
      "  {\n" +
      "    msg := greeting + name\n" +
      "  }\n" +
      "\n" +
      "  Str fullName(Str first, Str last)\n" +
      "  {\n" +
      "    result := first + \" \" + last\n" +
      "    return result\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Type
    verify(idx.hasType("Person"))
    personSyms := idx.findSymbols("Person")
    verifyEq(personSyms.size, 1)
    verifyEq(personSyms[0].kind, SymbolKind.type)
    verifyEq(personSyms[0].line, 2)

    // Fields
    nameSyms := idx.findSymbols("name")
    nameFld := nameSyms.find |s| { s.kind == SymbolKind.field }
    verifyNotNull(nameFld)
    verifyEq(nameFld.typeName, "Person")
    verifyEq(nameFld.line, 4)

    ageSyms := idx.findSymbols("age")
    ageFld := ageSyms.find |s| { s.kind == SymbolKind.field }
    verifyNotNull(ageFld)
    verifyEq(ageFld.typeName, "Person")
    verifyEq(ageFld.line, 5)

    // Methods
    greetSyms := idx.findSymbols("greet")
    greetMethod := greetSyms.find |s| { s.kind == SymbolKind.method }
    verifyNotNull(greetMethod)
    verifyEq(greetMethod.typeName, "Person")

    fullNameSyms := idx.findSymbols("fullName")
    fullNameMethod := fullNameSyms.find |s| { s.kind == SymbolKind.method }
    verifyNotNull(fullNameMethod)
    verifyEq(fullNameMethod.typeName, "Person")

    // Parameters
    greetingSyms := idx.findSymbols("greeting")
    greetingParam := greetingSyms.find |s| { s.kind == SymbolKind.param }
    verifyNotNull(greetingParam)
    verifyEq(greetingParam.methodName, "greet")

    firstSyms := idx.findSymbols("first")
    firstParam := firstSyms.find |s| { s.kind == SymbolKind.param }
    verifyNotNull(firstParam)
    verifyEq(firstParam.methodName, "fullName")

    lastSyms := idx.findSymbols("last")
    lastParam := lastSyms.find |s| { s.kind == SymbolKind.param }
    verifyNotNull(lastParam)
    verifyEq(lastParam.methodName, "fullName")

    // Local variables
    msgSyms := idx.findSymbols("msg")
    msgLocal := msgSyms.find |s| { s.kind == SymbolKind.localVar }
    verifyNotNull(msgLocal)
    verifyEq(msgLocal.methodName, "greet")
    verifyEq(msgLocal.line, 9)

    resultSyms := idx.findSymbols("result")
    resultLocal := resultSyms.find |s| { s.kind == SymbolKind.localVar }
    verifyNotNull(resultLocal)
    verifyEq(resultLocal.methodName, "fullName")
    verifyEq(resultLocal.line, 14)

    // Negative
    verify(!idx.hasType("NonExistent"))
    verifyEq(idx.findSymbols("NonExistent").size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Index Mixin
//////////////////////////////////////////////////////////////////////////

  Void testIndexMixin()
  {
    idx := ProjectIndex()
    uri := "file:///test/Serializable.fan"
    source :=
      "mixin Serializable\n" +
      "{\n" +
      "  abstract Str serialize()\n" +
      "}"

    idx.indexFile(uri, source)

    verify(idx.hasType("Serializable"))
    syms := idx.findSymbols("Serializable")
    verifyEq(syms.size, 1)
    verifyEq(syms[0].kind, SymbolKind.type)
    verifyEq(syms[0].line, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Index Enum
//////////////////////////////////////////////////////////////////////////

  Void testIndexEnumClass()
  {
    idx := ProjectIndex()
    uri := "file:///test/Color.fan"
    source :=
      "enum class Color\n" +
      "{\n" +
      "  red, green, blue\n" +
      "}"

    idx.indexFile(uri, source)

    verify(idx.hasType("Color"))
    syms := idx.findSymbols("Color")
    verifyEq(syms.size, 1)
    verifyEq(syms[0].kind, SymbolKind.type)
  }

//////////////////////////////////////////////////////////////////////////
// Scope-Aware Definition
//////////////////////////////////////////////////////////////////////////

  Void testScopeAwareDefinition()
  {
    idx := ProjectIndex()
    uri := "file:///test/Svc.fan"
    // Line numbers (0-based):
    // 0: class Svc
    // 1: {
    // 2:   Str data
    // 3:
    // 4:   Void methodA()
    // 5:   {
    // 6:     data := "local"
    // 7:   }
    // 8:
    // 9:   Void methodB()
    // 10:  {
    // 11:    data := "other"
    // 12:  }
    // 13: }
    source :=
      "class Svc\n" +
      "{\n" +
      "  Str data\n" +
      "\n" +
      "  Void methodA()\n" +
      "  {\n" +
      "    data := \"local\"\n" +
      "  }\n" +
      "\n" +
      "  Void methodB()\n" +
      "  {\n" +
      "    data := \"other\"\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Inside methodA at line 6 → should find local var at line 6
    defA := idx.findDefinition("data", uri, 6, 4)
    verifyNotNull(defA)
    verifyEq(defA.kind, SymbolKind.localVar)
    verifyEq(defA.line, 6)
    verifyEq(defA.methodName, "methodA")

    // Inside methodB at line 11 → should find local var at line 11
    defB := idx.findDefinition("data", uri, 11, 4)
    verifyNotNull(defB)
    verifyEq(defB.kind, SymbolKind.localVar)
    verifyEq(defB.line, 11)
    verifyEq(defB.methodName, "methodB")

    // At field level (line 2) → should find field
    defField := idx.findDefinition("data", uri, 2, 6)
    verifyNotNull(defField)
    verifyEq(defField.kind, SymbolKind.field)
    verifyEq(defField.line, 2)
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

    // findSymbols should find Logger from file A
    loggerSyms := idx.findSymbols("Logger")
    verifyEq(loggerSyms.size, 1)
    verifyEq(loggerSyms[0].fileUri, uriA)
    verifyEq(loggerSyms[0].kind, SymbolKind.type)

    // findDefinition from file B should resolve to file A
    def := idx.findDefinition("Logger", uriB, 4, 15)
    verifyNotNull(def)
    verifyEq(def.kind, SymbolKind.type)
    verifyEq(def.fileUri, uriA)

    // log method should be found from file A
    logSyms := idx.findSymbols("log")
    logMethod := logSyms.find |s| { s.kind == SymbolKind.method }
    verifyNotNull(logMethod)
    verifyEq(logMethod.fileUri, uriA)
    verifyEq(logMethod.typeName, "Logger")
  }

//////////////////////////////////////////////////////////////////////////
// Incremental Re-index
//////////////////////////////////////////////////////////////////////////

  Void testIncrementalReindex()
  {
    idx := ProjectIndex()
    uri := "file:///test/Svc.fan"

    // Initial version with methodA
    source1 :=
      "class Svc\n" +
      "{\n" +
      "  Void methodA() {}\n" +
      "}"

    idx.indexFile(uri, source1)
    verifyEq(idx.findSymbols("methodA").size, 1)
    verifyEq(idx.findSymbols("methodB").size, 0)

    // Re-index with methodB (methodA removed)
    source2 :=
      "class Svc\n" +
      "{\n" +
      "  Void methodB() {}\n" +
      "}"

    idx.indexFile(uri, source2)
    verifyEq(idx.findSymbols("methodA").size, 0)
    verifyEq(idx.findSymbols("methodB").size, 1)
  }

//////////////////////////////////////////////////////////////////////////
// Save-Time Indexing Regressions
//////////////////////////////////////////////////////////////////////////

  **
  ** Regression: indexAll must refresh discovered source files so newly
  ** created files are included in the global symbol index.
  **
  Void testIndexAllRefreshesNewFileFromDisk()
  {
    tmpDir := Env.cur.tempDir + `lsp-test-refresh-${DateTime.now.ticks}/`
    tmpDir.create

    try
    {
      // Create a minimal build pod workspace
      (tmpDir + `build.fan`).out.writeChars(
        "#! /usr/bin/env fan\nusing build\n" +
        "class Build : BuildPod\n{\n  new make()\n  {\n" +
        "    podName = \"refreshPod\"\n" +
        "    srcDirs = [`fan/`]\n" +
        "    depends = [\"sys 1.0\"]\n" +
        "  }\n}\n"
      ).close

      fanDir := tmpDir + `fan/`
      fanDir.create
      (fanDir + `Existing.fan`).out.writeChars("class Existing {}\n").close

      idx := ProjectIndex()
      idx.init(LspUtil.fileToUri(tmpDir))

      verify(idx.hasType("Existing"))
      verify(!idx.hasType("NewSavedType"))

      // Create a new file after init, then force a re-index.
      newFile := fanDir + `NewSavedType.fan`
      newFile.out.writeChars("class NewSavedType {}\n").close

      idx.indexAll

      newUri := LspUtil.fileToUri(newFile)
      verify(idx.hasType("NewSavedType"), "New file should be discovered after indexAll refresh")
      verify(idx.isProjectFile(newUri), "New file should be tracked as a project source file")
    }
    finally
    {
      try { deleteDir(tmpDir) } catch {}
    }
  }

  **
  ** Save indexing contract:
  **  - valid save => index symbols immediately
  **  - errored save => skip indexing, keep last valid symbols
  **
  Void testIndexSavedFileSkipsWhenHasErrors()
  {
    idx := ProjectIndex()
    uri := "file:///test/NewThing.fan"

    valid :=
      "class NewThing\n" +
      "{\n" +
      "  Void ok() {}\n" +
      "}"

    verify(idx.indexSavedFile(uri, valid, false))
    verify(idx.hasType("NewThing"))

    broken :=
      "class NewThing\n" +
      "{\n" +
      "  Void broken(\n" +
      "}"

    verify(!idx.indexSavedFile(uri, broken, true))
    verify(idx.hasType("NewThing"), "Last valid symbols should remain when save has errors")

    fresh := ProjectIndex()
    verify(!fresh.indexSavedFile("file:///test/Bad.fan", broken, true))
    verify(!fresh.hasType("Bad"), "Errored first save must not add new symbols")
  }

//////////////////////////////////////////////////////////////////////////
// Build.fan Parsing via init
//////////////////////////////////////////////////////////////////////////

  Void testBuildFanParsing()
  {
    // Create a temp directory with a build.fan
    tmpDir := Env.cur.tempDir + `lsp-test-${Duration.now.ticks}/`
    tmpDir.create

    try
    {
      buildFan := tmpDir + `build.fan`
      buildFan.out.print(
        "using build\n" +
        "class Build : BuildPod\n" +
        "{\n" +
        "  new make()\n" +
        "  {\n" +
        "    podName = \"myPod\"\n" +
        "    srcDirs = [`fan/`, `test/`]\n" +
        "  }\n" +
        "}\n"
      ).flush.close

      // Create srcDirs
      fanDir := tmpDir + `fan/`
      fanDir.create
      testDir := tmpDir + `test/`
      testDir.create

      // Create a source file
      srcFile := fanDir + `Foo.fan`
      srcFile.out.print("class Foo\n{\n  Void bar() {}\n}").flush.close

      idx := ProjectIndex()
      idx.init(tmpDir.uri.toStr)

      verifyEq(idx.podName, "myPod")
      verifyEq(idx.srcDirs.size, 2)
      verify(idx.hasType("Foo"))
    }
    finally
    {
      tmpDir.delete
    }
  }

//////////////////////////////////////////////////////////////////////////
// Parameter Scope
//////////////////////////////////////////////////////////////////////////

  Void testParamScopeDefinition()
  {
    idx := ProjectIndex()
    uri := "file:///test/Handler.fan"
    // Line numbers (0-based):
    // 0: class Handler
    // 1: {
    // 2:   Void process(Str input)
    // 3:   {
    // 4:     result := input.upper
    // 5:   }
    // 6: }
    source :=
      "class Handler\n" +
      "{\n" +
      "  Void process(Str input)\n" +
      "  {\n" +
      "    result := input.upper\n" +
      "  }\n" +
      "}"

    idx.indexFile(uri, source)

    // Inside method body, "input" should resolve to param
    def := idx.findDefinition("input", uri, 4, 14)
    verifyNotNull(def)
    verifyEq(def.kind, SymbolKind.param)
    verifyEq(def.methodName, "process")
  }

//////////////////////////////////////////////////////////////////////////
// Multiple Types in One File
//////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////
// Static Methods and List Return Types
//////////////////////////////////////////////////////////////////////////

  Void testIndexStaticMethod()
  {
    idx := ProjectIndex()
    uri := "file:///test/DeviceData.fan"
    // Line 0: class DeviceData
    // Line 1: {
    // Line 2:   Str name
    // Line 3:
    // Line 4:   static DeviceData readByName(Str name) { return DeviceData() }
    // Line 5:
    // Line 6:   static DeviceData[] readAllByRef(Str ref) { return DeviceData[,] }
    // Line 7:
    // Line 8:   static [Str:DeviceData] readMap() { return [Str:DeviceData][:] }
    // Line 9: }
    source :=
      "class DeviceData\n" +
      "{\n" +
      "  Str name\n" +
      "\n" +
      "  static DeviceData readByName(Str name) { return DeviceData() }\n" +
      "\n" +
      "  static DeviceData[] readAllByRef(Str ref) { return DeviceData[,] }\n" +
      "\n" +
      "  static [Str:DeviceData] readMap() { return [Str:DeviceData][:] }\n" +
      "}"

    idx.indexFile(uri, source)

    // Static method with simple return type should be indexed
    readByNameSyms := idx.findSymbols("readByName")
    readByNameMethod := readByNameSyms.find |s| { s.kind == SymbolKind.method }
    verifyNotNull(readByNameMethod)
    verifyEq(readByNameMethod.typeName, "DeviceData")
    verifyEq(readByNameMethod.line, 4)

    // Static method with list return type (DeviceData[]) should be indexed
    readAllSyms := idx.findSymbols("readAllByRef")
    readAllMethod := readAllSyms.find |s| { s.kind == SymbolKind.method }
    verifyNotNull(readAllMethod)
    verifyEq(readAllMethod.typeName, "DeviceData")
    verifyEq(readAllMethod.line, 6)

    // Static method with map return type ([Str:DeviceData]) should be indexed
    readMapSyms := idx.findSymbols("readMap")
    readMapMethod := readMapSyms.find |s| { s.kind == SymbolKind.method }
    verifyNotNull(readMapMethod)
    verifyEq(readMapMethod.typeName, "DeviceData")
    verifyEq(readMapMethod.line, 8)
  }

//////////////////////////////////////////////////////////////////////////
// Multiple Types in One File
//////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////
// Index Enum Values
//////////////////////////////////////////////////////////////////////////

  Void testIndexEnumValues()
  {
    idx := ProjectIndex()
    uri := "file:///test/Color.fan"
    // Line 0: enum class Color
    // Line 1: {
    // Line 2:   red,
    // Line 3:   green,
    // Line 4:   blue
    // Line 5: }
    source :=
      "enum class Color\n" +
      "{\n" +
      "  red,\n" +
      "  green,\n" +
      "  blue\n" +
      "}"

    idx.indexFile(uri, source)

    verify(idx.hasType("Color"))

    // Enum values should be indexed
    redSyms := idx.findSymbols("red")
    redSym := redSyms.find |s| { s.kind == SymbolKind.enumVal }
    verifyNotNull(redSym)
    verifyEq(redSym.typeName, "Color")
    verifyEq(redSym.line, 2)

    greenSyms := idx.findSymbols("green")
    greenSym := greenSyms.find |s| { s.kind == SymbolKind.enumVal }
    verifyNotNull(greenSym)
    verifyEq(greenSym.typeName, "Color")
    verifyEq(greenSym.line, 3)

    blueSyms := idx.findSymbols("blue")
    blueSym := blueSyms.find |s| { s.kind == SymbolKind.enumVal }
    verifyNotNull(blueSym)
    verifyEq(blueSym.typeName, "Color")
    verifyEq(blueSym.line, 4)
  }

//////////////////////////////////////////////////////////////////////////
// Index Closure Params
//////////////////////////////////////////////////////////////////////////

  Void testIndexClosureParams()
  {
    idx := ProjectIndex()
    uri := "file:///test/Processor.fan"
    // Line 0: class Processor
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
      "class Processor\n" +
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

    // "item" closure param should be indexed
    itemSyms := idx.findSymbols("item")
    verify(itemSyms.size > 0)
    itemSym := itemSyms.find |s| { s.kind == SymbolKind.param || s.kind == SymbolKind.localVar }
    verifyNotNull(itemSym)
    verifyEq(itemSym.methodName, "run")
  }

//////////////////////////////////////////////////////////////////////////
// Multiple Types in One File
//////////////////////////////////////////////////////////////////////////

  Void testMultipleTypesInFile()
  {
    idx := ProjectIndex()
    uri := "file:///test/Multi.fan"
    source :=
      "class Alpha\n" +
      "{\n" +
      "  Str name\n" +
      "  Void doStuff() {}\n" +
      "}\n" +
      "\n" +
      "class Beta\n" +
      "{\n" +
      "  Int count\n" +
      "  Void run() {}\n" +
      "}"

    idx.indexFile(uri, source)

    verify(idx.hasType("Alpha"))
    verify(idx.hasType("Beta"))

    // name field belongs to Alpha
    nameSym := idx.findSymbols("name").find |s| { s.kind == SymbolKind.field }
    verifyNotNull(nameSym)
    verifyEq(nameSym.typeName, "Alpha")

    // count field belongs to Beta
    countSym := idx.findSymbols("count").find |s| { s.kind == SymbolKind.field }
    verifyNotNull(countSym)
    verifyEq(countSym.typeName, "Beta")
  }

//////////////////////////////////////////////////////////////////////////
// Closure Parameter Indexing (Text Fallback)
//////////////////////////////////////////////////////////////////////////

  **
  ** Closure parameters like |file| or |Type name| should be indexed
  ** when AST parsing fails and text-based fallback is used.
  ** Regression test for go-to-definition on closure params.
  **
  Void testIndexClosureParamsTextFallback()
  {
    idx := ProjectIndex()
    // Source uses a project type (ExtLogger) to force text-based fallback
    idx.indexFile("file:///test/ExtLogger.fan",
      "class ExtLogger\n" +
      "{\n" +
      "  Void log(Str msg) {}\n" +
      "}")

    idx.indexFile("file:///test/Handler.fan",
      "class Handler : ExtLogger\n" +
      "{\n" +
      "  static Void restore(Str name)\n" +
      "  {\n" +
      "    files := [,]\n" +
      "    files.findAll |file| { file.ext == \"csv\" }\n" +
      "    files.each |File item| { echo(item) }\n" +
      "  }\n" +
      "}")

    // Closure params should be indexed
    fileSyms := idx.findSymbols("file").findAll |s|
    {
      s.kind == SymbolKind.param && s.fileUri == "file:///test/Handler.fan"
    }
    verify(fileSyms.size > 0, "Closure param 'file' should be indexed in text fallback")

    itemSyms := idx.findSymbols("item").findAll |s|
    {
      s.kind == SymbolKind.param && s.fileUri == "file:///test/Handler.fan"
    }
    verify(itemSyms.size > 0, "Typed closure param 'item' should be indexed in text fallback")
  }

  **
  ** Closure param in current file should take priority over same-named
  ** param in another file during definition lookup.
  **
  Void testClosureParamDefinitionPriority()
  {
    idx := ProjectIndex()
    // File A has a closure param named "file" at line 3
    idx.indexFile("file:///test/Utils.fan",
      "class Utils\n" +
      "{\n" +
      "  static Void getFiles()\n" +
      "  {\n" +
      "    list.findAll |file| { file.ext == \"csv\" }\n" +
      "  }\n" +
      "}")

    // File B also has a closure param named "file" at line 5
    // Uses a project type to force text fallback
    idx.indexFile("file:///test/ExtLogger.fan",
      "class ExtLogger\n" +
      "{\n" +
      "  Void log(Str msg) {}\n" +
      "}")

    idx.indexFile("file:///test/Handler.fan",
      "class Handler : ExtLogger\n" +
      "{\n" +
      "  static Void restore()\n" +
      "  {\n" +
      "    items := [,]\n" +
      "    items.findAll |file| { file.uri != null }\n" +
      "  }\n" +
      "}")

    // When looking up "file" from Handler.fan line 5, should find the local one
    sym := idx.findDefinition("file", "file:///test/Handler.fan", 5, 30)
    verifyNotNull(sym)
    verifyEq(sym.fileUri, "file:///test/Handler.fan")
    verifyEq(sym.kind, SymbolKind.param)
  }

//////////////////////////////////////////////////////////////////////////
// Multi-Pod Discovery
//////////////////////////////////////////////////////////////////////////

  ** Recursively delete a directory and all its contents.
  private Void deleteDir(File dir)
  {
    dir.list.each |f|
    {
      if (f.isDir) deleteDir(f)
      else try { f.delete } catch {}
    }
    try { dir.delete } catch {}
  }

  **
  ** Create a temporary two-pod workspace on disk, call ProjectIndex.init(),
  ** and verify that both pods are discovered and all their types indexed.
  **
  Void testMultiPodDiscovery()
  {
    // Build a temp directory tree:
    //   tmp/
    //     pod1/
    //       build.fan   (podName="pod1", srcDirs=[`fan/`], depends=["sys 1.0"])
    //       fan/
    //         Foo.fan
    //     pod2/
    //       build.fan   (podName="pod2", depends=["sys 1.0", "pod1 1.0"])
    //       fan/
    //         Bar.fan
    tmpDir := Env.cur.tempDir + `lsp-test-multipod-${DateTime.now.ticks}/`
    tmpDir.create

    try
    {
      // Pod 1
      pod1Dir := tmpDir + `pod1/`
      pod1Dir.create
      (pod1Dir + `build.fan`).out.writeChars(
        "#! /usr/bin/env fan\nusing build\n" +
        "class Build : BuildPod\n{\n  new make()\n  {\n" +
        "    podName = \"pod1\"\n" +
        "    srcDirs = [`fan/`]\n" +
        "    depends = [\"sys 1.0\"]\n" +
        "  }\n}\n"
      ).close
      pod1FanDir := pod1Dir + `fan/`
      pod1FanDir.create
      (pod1FanDir + `Foo.fan`).out.writeChars("class Foo { Str name := \"\" }\n").close

      // Pod 2 (depends on pod1)
      pod2Dir := tmpDir + `pod2/`
      pod2Dir.create
      (pod2Dir + `build.fan`).out.writeChars(
        "#! /usr/bin/env fan\nusing build\n" +
        "class Build : BuildPod\n{\n  new make()\n  {\n" +
        "    podName = \"pod2\"\n" +
        "    srcDirs = [`fan/`]\n" +
        "    depends = [\"sys 1.0\", \"pod1 1.0\"]\n" +
        "  }\n}\n"
      ).close
      pod2FanDir := pod2Dir + `fan/`
      pod2FanDir.create
      (pod2FanDir + `Bar.fan`).out.writeChars("class Bar { Int count := 0 }\n").close

      // Initialize the project index from the workspace root
      idx := ProjectIndex()
      idx.init(LspUtil.fileToUri(tmpDir))

      // Two pods should be discovered
      verifyEq(idx.pods.size, 2)

      // Types from both pods should be indexed (cross-pod)
      verify(idx.hasType("Foo"), "Foo from pod1 should be indexed")
      verify(idx.hasType("Bar"), "Bar from pod2 should be indexed")

      // getPodForFile resolves pod1
      fooUri := LspUtil.fileToUri(pod1FanDir + `Foo.fan`)
      pod1Info := idx.getPodForFile(fooUri)
      verifyNotNull(pod1Info)
      verifyEq(pod1Info.podName, "pod1")

      // buildFanForFile returns pod1's build.fan
      bf := idx.buildFanForFile(fooUri)
      verifyNotNull(bf)
      verify(bf.osPath.endsWith("pod1${File.sep}build.fan") || bf.osPath.contains("pod1"), "Should point to pod1/build.fan")

      // Pod2 depends list includes pod1
      pod2Info := idx.pods.find |p| { p.podName == "pod2" }
      verifyNotNull(pod2Info)
      verify(pod2Info.depends.contains("pod1"), "pod2 should list pod1 as a dependency")

      // isProjectFile works across both pods
      barUri := LspUtil.fileToUri(pod2FanDir + `Bar.fan`)
      verify(idx.isProjectFile(fooUri), "Foo.fan should be a project file")
      verify(idx.isProjectFile(barUri), "Bar.fan should be a project file")
    }
    finally
    {
      // Clean up temp directory
      try { deleteDir(tmpDir) } catch {}
    }
  }

  **
  ** A build.fan that extends BuildGroup (not BuildPod) should be skipped
  ** during pod discovery — it orchestrates pods, it is not itself a pod.
  **
  Void testBuildGroupIsSkipped()
  {
    tmpDir := Env.cur.tempDir + `lsp-test-buildgroup-${DateTime.now.ticks}/`
    tmpDir.create
    try
    {
      // Root build.all that extends BuildGroup — should NOT become a PodInfo
      (tmpDir + `build.all`).out.writeChars(
        "#! /usr/bin/env fan\nusing build\n" +
        "class Build : BuildGroup\n{\n  new make()\n  {\n" +
        "    children = [`pod1/`]\n" +
        "  }\n}\n"
      ).close

      // Pod1 listed in children
      pod1Dir := tmpDir + `pod1/`
      pod1Dir.create
      (pod1Dir + `build.fan`).out.writeChars(
        "#! /usr/bin/env fan\nusing build\n" +
        "class Build : BuildPod\n{\n  new make()\n  {\n" +
        "    podName = \"pod1\"\n" +
        "    srcDirs = [`fan/`]\n" +
        "    depends = [\"sys 1.0\"]\n" +
        "  }\n}\n"
      ).close
      pod1FanDir := pod1Dir + `fan/`
      pod1FanDir.create
      (pod1FanDir + `Foo.fan`).out.writeChars("class Foo {}\n").close

      idx := ProjectIndex()
      idx.init(LspUtil.fileToUri(tmpDir))

      // Only pod1 should be a pod (not the BuildGroup)
      verifyEq(idx.pods.size, 1)
      verifyEq(idx.pods.first.podName, "pod1")
      verify(idx.hasType("Foo"))
    }
    finally
    {
      try { deleteDir(tmpDir) } catch {}
    }
  }

//////////////////////////////////////////////////////////////////////////
// indexSavedFile — regression for newly-created types not detected
//////////////////////////////////////////////////////////////////////////

  **
  ** Regression: indexSavedFile with no errors must index the file and
  ** return true.  This was the fix for newly-created types not being
  ** detected after the first save.
  **
  Void testIndexSavedFileIndexesWhenNoErrors()
  {
    idx := ProjectIndex()
    uri := "file:///test/NewType.fan"
    source :=
      "class NewType\n" +
      "{\n" +
      "  Str name := \"hello\"\n" +
      "}"

    result := idx.indexSavedFile(uri, source, false)

    verify(result, "indexSavedFile should return true when there are no errors")
    verify(idx.hasType("NewType"), "NewType should be present in the index after save with no errors")
  }

  **
  ** Regression: indexSavedFile with errors must skip indexing and return false.
  ** Broken snapshots must never be promoted into the project index.
  **
  Void testIndexSavedFileSkipsWhenHasErrorsKeepsPreviousSymbols()
  {
    idx := ProjectIndex()
    uri := "file:///test/BrokenType.fan"

    // First, index a valid version so the type is present.
    idx.indexFile(uri, "class BrokenType { Str name := \"ok\" }")
    verify(idx.hasType("BrokenType"), "BrokenType should exist before broken save")

    // Now simulate saving a broken version – hasErrors = true.
    brokenSource :=
      "class BrokenType\n" +
      "{\n" +
      "  THIS IS NOT VALID FANTOM SYNTAX !!!\n" +
      "}"

    result := idx.indexSavedFile(uri, brokenSource, true)

    verify(!result, "indexSavedFile should return false when errors are present")
    // The previously-indexed valid symbols must still be intact.
    verify(idx.hasType("BrokenType"), "BrokenType should still be in the index (old snapshot retained)")
  }

  **
  ** Regression: a newly created type (not previously indexed at all) must
  ** become visible after indexSavedFile is called with no errors, even
  ** before a full indexAll is run.  This was the original issue reported
  ** as "newly-created types not detected".
  **
  Void testNewlyCreatedTypeDetectedAfterSave()
  {
    idx := ProjectIndex()

    // Brand-new type that has never been indexed yet.
    uri := "file:///test/BrandNew.fan"
    source :=
      "class BrandNew\n" +
      "{\n" +
      "  Int value := 42\n" +
      "}"

    verify(!idx.hasType("BrandNew"), "BrandNew must not exist before first save")

    result := idx.indexSavedFile(uri, source, false)

    verify(result, "indexSavedFile should return true for a new error-free file")
    verify(idx.hasType("BrandNew"), "BrandNew must be discoverable right after save with no errors")
  }

  **
  ** Regression: static const Str (and other typed) fields must have typeStr
  ** populated by the text-scan indexer so that hover shows "Str MyClass.fieldName"
  ** instead of the "Obj? fieldName" fallback.
  **
  Void testFieldTypeStrIndexed()
  {
    idx := ProjectIndex()
    uri := "file:///test/MyService.fan"
    source :=
      "class MyService\n" +
      "{\n" +
      "  static const Str defName := \"hello\"\n" +
      "  const Int maxRetries := 3\n" +
      "  Bool enabled := true\n" +
      "  Str? label\n" +
      "}"

    idx.indexFile(uri, source)

    // static const Str — must have typeStr populated
    defNameSyms := idx.findSymbols("defName")
    defNameFld := defNameSyms.find |s| { s.kind == SymbolKind.field }
    verifyNotNull(defNameFld, "defName field not indexed")
    verifyEq(defNameFld.typeName, "MyService")
    verifyEq(defNameFld.typeStr, "Str",
      "static const Str field must have typeStr=\"Str\", not null (which renders as Obj?)")

    // const Int
    maxRetriesSyms := idx.findSymbols("maxRetries")
    maxRetriesFld := maxRetriesSyms.find |s| { s.kind == SymbolKind.field }
    verifyNotNull(maxRetriesFld, "maxRetries field not indexed")
    verifyEq(maxRetriesFld.typeStr, "Int",
      "const Int field must have typeStr=\"Int\"")

    // plain Bool
    enabledSyms := idx.findSymbols("enabled")
    enabledFld := enabledSyms.find |s| { s.kind == SymbolKind.field }
    verifyNotNull(enabledFld, "enabled field not indexed")
    verifyEq(enabledFld.typeStr, "Bool",
      "Bool field must have typeStr=\"Bool\"")

    // nullable Str?
    labelSyms := idx.findSymbols("label")
    labelFld := labelSyms.find |s| { s.kind == SymbolKind.field }
    verifyNotNull(labelFld, "label field not indexed")
    verifyEq(labelFld.typeStr, "Str",
      "Str? field must have typeStr=\"Str\" (nullable marker stripped by extractDeclaredType)")
  }

  Void testGetBaseTypeChainMultiLevel()
  {
    idx := ProjectIndex()
    idx.indexFile("file:///A.fan", "class A {\n  Void go() {}\n}\n")
    idx.indexFile("file:///B.fan", "class B : A {}\n")
    idx.indexFile("file:///C.fan", "class C : B {}\n")

    chainB := idx.getBaseTypeChain("B")
    verify(chainB.contains("A"), "B's chain must include A, got: $chainB")

    chainC := idx.getBaseTypeChain("C")
    verify(chainC.contains("B"), "C's chain must include B, got: $chainC")
    verify(chainC.contains("A"), "C's chain must include A, got: $chainC")
  }

  Void testGetVarTypesCtorInference()
  {
    // Cross-file ctor inference: svc := Svc() — Svc is in a different file
    a := "class Svc { Void stop() {} }\n"
    b :=
      "class Main {\n" +
      "  Void run() {\n" +
      "    svc := Svc()\n" +
      "    svc.stop()\n" +
      "  }\n" +
      "}\n"
    idx := ProjectIndex()
    idx.indexFile("file:///Svc.fan", a)
    idx.indexFile("file:///Main.fan", b)

    varTypes := idx.getVarTypesForFile("file:///Main.fan")
    verifyEq(varTypes["svc"], "Svc",
      "ctor-inferred type must resolve to 'Svc', got varTypes=$varTypes")
  }

//////////////////////////////////////////////////////////////////////////
// Multi-Line Method Signature (Text Fallback)
//////////////////////////////////////////////////////////////////////////

  **
  ** Regression: a method whose parameter list spans multiple lines (each
  ** param on its own line, opening brace only after the closing paren) was
  ** ending the text-fallback scanner's method scope one line after the
  ** declaration line — since braceDepth had not yet risen past
  ** methodBraceDepth (the body brace not reached yet). This caused every
  ** param's default-value line to be misindexed as a class field, and every
  ** local variable inside the method body to be missed entirely.
  ** Forces text fallback via an unresolvable base type per this repo's
  ** "always test the inheritance case" policy.
  **
  Void testMultiLineMethodSignatureTextFallback()
  {
    idx := ProjectIndex()
    idx.indexFile("file:///test/Widget.fan",
      "class Widget\n" +
      "{\n" +
      "}\n")

    idx.indexFile("file:///test/Foo.fan",
      "class Foo : UnresolvableBase\n" +
      "{\n" +
      "  static Widget? createDevice(\n" +
      "        Str cx,\n" +
      "        Str siteId,\n" +
      "        Dict fields := emptyDict\n" +
      "        ) {\n" +
      "    result := getWidget(cx)\n" +
      "    return result\n" +
      "  }\n" +
      "}\n")

    // The default-value param on its own line must NOT be misindexed as a
    // class field.
    fieldsFieldSyms := idx.findSymbols("fields").findAll |s|
    {
      s.kind == SymbolKind.field && s.fileUri == "file:///test/Foo.fan"
    }
    verifyEq(fieldsFieldSyms.size, 0,
      "multi-line param default value must not be indexed as a field")

    // Note: the text-fallback parser only extracts params physically present
    // on the method's declaration line, so a param on its own line (as here)
    // isn't indexed as SymbolKind.param either — that's a separate, narrower
    // gap than this regression test targets. The important fix verified here
    // is that it's no longer misindexed as a field, and locals after it are
    // no longer lost.

    // The local variable inside the method body must be indexed.
    resultSyms := idx.findSymbols("result").findAll |s|
    {
      s.kind == SymbolKind.localVar && s.fileUri == "file:///test/Foo.fan"
    }
    verify(resultSyms.size > 0, "local var declared after a multi-line signature must be indexed")
    verifyEq(resultSyms.first.methodName, "createDevice")
  }
}
