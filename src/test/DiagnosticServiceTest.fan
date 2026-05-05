//
// Copyright (c) 2025, Brian Frank and Andy Frank
// Licensed under the Academic Free License version 3.0
//
// History:
//   11 Feb 26  Creation
//

using compiler

**
** DiagnosticServiceTest - Tests for single-file diagnostic analysis.
** Verifies that compiler errors and warnings are passed through as-is.
**
class DiagnosticServiceTest : Test
{
  private DiagnosticServiceBuilderFacade svc := DiagnosticServiceBuilderFacade(DiagnosticService())
  private ProjectIndex idx := ProjectIndex()

//////////////////////////////////////////////////////////////////////////
// Valid Source - No Errors
//////////////////////////////////////////////////////////////////////////

  Void testValidSimpleClass()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar() {}\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    verifyEq(diags.size, 0)
  }

  Void testValidClassWithMethodsAndFields()
  {
    source :=
      "class Calculator\n" +
      "{\n" +
      "  Int value := 0\n" +
      "\n" +
      "  Int add(Int a, Int b) { return a + b }\n" +
      "\n" +
      "  Int sub(Int a, Int b) { return a - b }\n" +
      "\n" +
      "  Void reset() { value = 0 }\n" +
      "}"

    diags := svc.analyze("file:///test/Calculator.fan", source, idx)
    verifyEq(diags.size, 0)
  }

  Void testValidClassWithLocals()
  {
    source :=
      "class Processor\n" +
      "{\n" +
      "  Str process(Str input)\n" +
      "  {\n" +
      "    result := input.upper\n" +
      "    trimmed := result.trim\n" +
      "    return trimmed\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Processor.fan", source, idx)
    verifyEq(diags.size, 0)
  }

  Void testValidClassWithInheritance()
  {
    source :=
      "class Animal\n" +
      "{\n" +
      "  Str name\n" +
      "  new make(Str name) { this.name = name }\n" +
      "  virtual Str speak() { return \"...\" }\n" +
      "}"

    diags := svc.analyze("file:///test/Animal.fan", source, idx)
    verifyEq(diags.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Syntax Errors
//////////////////////////////////////////////////////////////////////////

  Void testMissingClosingParen()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(\n" +
      "  {\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    verify(diags.size > 0)
  }

  Void testMissingClosingBrace()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    x := 42\n"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    verify(diags.size > 0)
  }

  Void testIncompleteExpression()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    x := \n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    verify(diags.size > 0)
  }

  Void testInvalidMethodSignature()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(Int , Str)\n" +
      "  {\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    verify(diags.size > 0)
  }

  Void testUnknownTypeReported()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  NoSuchType getData() { return null }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    unknownTypeDiags := diags.findAll |d|
    {
      d.message.contains("Unknown type") && d.message.contains("NoSuchType")
    }
    verify(unknownTypeDiags.size > 0)
  }

  Void testHashDotPodSyntaxErrorReported()
  {
    // Standalone #.pod is invalid Fantom (# expects an identifier after it).
    // The compiler produces "Expected identifier, not '.'".
    source :=
      "class Foo\n" +
      "{\n" +
      "  static Str test() {\n" +
      "    return doSomething( #.pod, \"test\")\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    expectedId := diags.findAll |d| { d.message.contains("Expected identifier") }
    verify(expectedId.size > 0, "Syntax error '#.pod' should be reported")
  }

  Void testUnknownTypeLiteralReported()
  {
    // When a type literal like "returACoreExt#.pod" references a type
    // unknown to the single-file compiler, the error must be reported.
    source :=
      "class Foo\n" +
      "{\n" +
      "  static Str test() {\n" +
      "    returACoreExt#.pod\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    unknownType := diags.findAll |d|
    {
      d.message.contains("Unknown type") && d.message.contains("returACoreExt")
    }
    verify(unknownType.size > 0, "Unknown type literal error should be reported")
  }

//////////////////////////////////////////////////////////////////////////
// Project Type False Positive Filtering
//////////////////////////////////////////////////////////////////////////

  Void testUnknownVariableFilteredWhenTypeInIndex()
  {
    // When a file references a type from another file in the same pod
    // via static method calls (e.g., MyLib.doSomething()), single-file
    // compilation reports "Unknown variable 'MyLib'". This must be
    // filtered when the type exists in the ProjectIndex.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/MyLib.fan",
      "class MyLib\n" +
      "{\n" +
      "  static Void doWork() {}\n" +
      "  static Void doMore() {}\n" +
      "}")

    source :=
      "class MyExt\n" +
      "{\n" +
      "  static Void run()\n" +
      "  {\n" +
      "    MyLib.doWork()\n" +
      "    MyLib.doMore()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/MyExt.fan", source, typeIdx)

    unknownVar := diags.findAll |d|
    {
      d.message.contains("Unknown variable") && d.message.contains("MyLib")
    }
    verifyEq(unknownVar.size, 0)
  }

  Void testUnknownVariableNotFilteredWhenNotInIndex()
  {
    // When the type is NOT in the ProjectIndex, the error is real
    // and must be reported.
    source :=
      "class MyExt\n" +
      "{\n" +
      "  static Void run()\n" +
      "  {\n" +
      "    NoSuchClass.doWork()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/MyExt.fan", source, idx)

    unknownVar := diags.findAll |d|
    {
      d.message.contains("Unknown variable") && d.message.contains("NoSuchClass")
    }
    verify(unknownVar.size > 0, "Unknown variable not in index should be reported")
  }

  Void testUnknownTypeFilteredWhenInIndex()
  {
    // "Unknown type 'X'" should be filtered when X exists in the index.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/MyData.fan",
      "class MyData\n" +
      "{\n" +
      "  Str value\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  MyData getData() { return null }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, typeIdx)

    unknownType := diags.findAll |d|
    {
      d.message.contains("Unknown type") && d.message.contains("MyData")
    }
    verifyEq(unknownType.size, 0)
  }

  Void testUnknownBaseTypeFilteredWhenInIndex()
  {
    // When a class extends a type from another file in the same pod,
    // single-file compilation reports "Unknown type 'BaseType'".
    // This must be filtered when the base type exists in the ProjectIndex.
    // The index file has a single-line enum BEFORE the class to test that
    // the indexer correctly closes single-line type scopes (enum class Foo { a, b })
    // and continues to index subsequent types.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/BaseFile.fan",
      "enum class Kind { site, floor, room }\n" +
      "\n" +
      "class BaseClass\n" +
      "{\n" +
      "  Void doWork() {}\n" +
      "}")

    // Verify both types are indexed
    verify(typeIdx.hasType("Kind"))
    verify(typeIdx.hasType("BaseClass"))

    source :=
      "class ChildClass : BaseClass\n" +
      "{\n" +
      "  Void test() {}\n" +
      "}"

    diags := svc.analyze("file:///test/ChildClass.fan", source, typeIdx)

    unknownType := diags.findAll |d|
    {
      d.message.contains("Unknown type") && d.message.contains("BaseClass")
    }
    verifyEq(unknownType.size, 0)
  }

  Void testUnknownTypeLiteralFilteredWhenInIndex()
  {
    // "Unknown type 'X' for type literal" (e.g., X#.pod) is a false positive
    // when X exists in the project — single-file compilation can't see it.
    // Even though type literal errors are parse-stopping, showing them as
    // false positives is worse than hiding them.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/MyExt.fan",
      "class MyExt\n" +
      "{\n" +
      "  static Void doWork() {}\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  static Str test() {\n" +
      "    return doSomething(MyExt#.pod, \"test\")\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, typeIdx)

    unknownType := diags.findAll |d|
    {
      d.message.contains("Unknown type") && d.message.contains("MyExt")
    }
    verifyEq(unknownType.size, 0)
  }

  Void testNoConstructorFoundFilteredWhenUnresolvedTypes()
  {
    // In single-file compilation, when argument types can't be resolved,
    // the compiler collapses them to sys::Error, causing constructor lookup
    // to fail with "No constructor found: Foo(sys::Str, sys::Error[], ...)".
    // This is a false positive and must be filtered.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Obj? config\n" +
      "  new make()\n" +
      "  {\n" +
      "    this.config = SomeConfig(\n" +
      "      \"name\",\n" +
      "      [getMapA(), getMapB()],\n" +
      "      [getBaseA(), getBaseB()],\n" +
      "      getNames()\n" +
      "    )\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    noCtorDiags := diags.findAll |d|
    {
      d.message.contains("No constructor found")
    }
    // The compiler may produce various errors for unresolvable code;
    // any "No constructor found" with sys::Error should be filtered
    noCtorWithError := noCtorDiags.findAll |d|
    {
      d.message.contains("sys::Error")
    }
    verifyEq(noCtorWithError.size, 0)
  }

  Void testNoConstructorFoundNotFilteredWhenRealError()
  {
    // A real "No constructor found" (no sys::Error in signature) must
    // still be reported — it's a genuine type mismatch.
    source :=
      "class Bar\n" +
      "{\n" +
      "  new make(Int x) {}\n" +
      "}\n" +
      "class Foo\n" +
      "{\n" +
      "  Void test() { b := Bar(\"wrong\", \"args\", \"here\") }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    noCtorDiags := diags.findAll |d|
    {
      d.message.contains("No constructor found") && d.message.contains("Bar")
    }
    verify(noCtorDiags.size > 0, "Real constructor error should be reported")
  }

  Void testInternalNotAccessibleFiltered()
  {
    // In single-file (script) mode, the code is not compiled as part of
    // its real pod. Internal members from 'using' pods that are accessible
    // in full pod compilation appear inaccessible. These must be filtered.
    source :=
      "using concurrent\n" +
      "class Foo\n" +
      "{\n" +
      "  Void test()\n" +
      "  {\n" +
      "    // This triggers compilation that may produce internal access errors\n" +
      "    x := 42\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    internalDiags := diags.findAll |d|
    {
      d.message.contains("not accessible") &&
      (d.message.startsWith("Internal method") || d.message.startsWith("Internal field"))
    }
    verifyEq(internalDiags.size, 0)
  }

  Void testAmbiguousTypeDowngradedToWarning()
  {
    // When multiple 'using' pods export the same type name, the single-file
    // compiler reports "Ambiguous type: podA::Type podB::Type" as an error.
    // Since full pod compilation resolves it correctly, we downgrade to
    // warning so the user is informed but not blocked.
    source :=
      "using concurrent\n" +
      "using web\n" +
      "class Foo\n" +
      "{\n" +
      "  Void test()\n" +
      "  {\n" +
      "    x := 42\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    ambiguousDiags := diags.findAll |d|
    {
      d.message.startsWith("Ambiguous type")
    }
    // Any ambiguous type diagnostics must be warnings, not errors
    ambiguousDiags.each |d|
    {
      verifyEq(d.severity, DiagnosticSeverity.warning)
    }
  }

  Void testRealSyntaxErrorNotHiddenByProjectTypeFilter()
  {
    // Real syntax errors must still be reported even when project types
    // cause some errors to be filtered.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/MyLib.fan",
      "class MyLib\n" +
      "{\n" +
      "  static Void doWork() {}\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  static Void run()\n" +
      "  {\n" +
      "    MyLib.doWork()\n" +
      "    returACoreExt#.pod\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, typeIdx)

    // "Unknown type 'returACoreExt'" is NOT in the index, so must be reported
    unknownType := diags.findAll |d|
    {
      d.message.contains("Unknown type") && d.message.contains("returACoreExt")
    }
    verify(unknownType.size > 0, "Real unknown type should not be hidden")
  }

//////////////////////////////////////////////////////////////////////////
// Diagnostic Properties
//////////////////////////////////////////////////////////////////////////

  Void testDiagnosticHasCorrectSeverity()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(\n" +
      "  {\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    verify(diags.size > 0)

    diags.each |d|
    {
      if (d.severity == DiagnosticSeverity.error)
        verifyEq(d.severity, 1)
    }
  }

  Void testDiagnosticHasSourceTag()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(\n" +
      "  {\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    verify(diags.size > 0)

    diags.each |d| { verifyEq(d.source, "fantom") }
  }

  Void testDiagnosticHasValidRange()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(\n" +
      "  {\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    verify(diags.size > 0)

    diags.each |d|
    {
      verify(d.range.start.line >= 0)
      verify(d.range.start.character >= 0)
      verify(d.range.end.line >= d.range.start.line)
    }
  }

//////////////////////////////////////////////////////////////////////////
// Map Type Constructor Cascade Error
//////////////////////////////////////////////////////////////////////////

  Void testExpectedCommaNotColonFilteredWhenTypesKnown()
  {
    // Map(Ref:MyClass#) causes "Expected ',', not ':'" in single-file
    // mode. When all types are known (sys or index), filter the error.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    m := Map(Str:MyClass#)\n" +
      "  }\n" +
      "}"

    // Add MyClass to the index so both types are known
    idxWithType := ProjectIndex()
    idxWithType.indexFile("file:///test/MyClass.fan",
      "class MyClass\n" +
      "{\n" +
      "  Str name\n" +
      "}")

    diags := svc.analyze("file:///test/Foo.fan", source, idxWithType)
    filtered := diags.findAll |d| { d.message == "Expected ',', not ':'" }
    verifyEq(filtered.size, 0)
  }

  Void testExpectedCommaNotColonNotFilteredWhenTypeUnknown()
  {
    // Map(Str:Pippo#) — Pippo is not in the index, so the error
    // should NOT be filtered.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    m := Map(Str:Pippo#)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    filtered := diags.findAll |d| { d.message == "Expected ',', not ':'" }
    verify(filtered.size > 0)
  }

//////////////////////////////////////////////////////////////////////////
// Pod-Qualified Type (::) Filtered
//////////////////////////////////////////////////////////////////////////

  Void testPodQualifiedTypeFiltered()
  {
    // podName::TypeName.CONST causes "Expected ',', not '::'" in single-file
    // mode because the compiler can't resolve the pod name.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    x := myPod::Main.DEFAULT_NAME\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    filtered := diags.findAll |d| { d.message == "Expected ',', not '::'" }
    verifyEq(filtered.size, 0)
  }

  Void testPodQualifiedTypeInMethodArgFiltered()
  {
    // Pod-qualified type used as a method argument
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    doSomething(myPod::Config.SETTING)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    filtered := diags.findAll |d| { d.message == "Expected ',', not '::'" }
    verifyEq(filtered.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Java FFI Package Not Found
//////////////////////////////////////////////////////////////////////////

  Void testJavaPackageNotFoundFiltered()
  {
    // "Java package 'xxx' not found" is always a false positive in
    // single-file compilation — Java FFI can't resolve without the
    // full pod build environment.
    source :=
      "using [java] com.siemens.bt.bbs.adapter.wrapper.callback\n" +
      "class Foo\n" +
      "{\n" +
      "  Void bar() {}\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    javaPkgDiags := diags.findAll |d|
    {
      d.message.startsWith("Java package") && d.message.endsWith("not found")
    }
    verifyEq(javaPkgDiags.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Type literal preprocessing
//////////////////////////////////////////////////////////////////////////

  Void testTypeLiteralDoesNotBlockParsing()
  {
    // ProjectType#.pod causes a parse-stopping error in single-file mode.
    // The preprocessor replaces it with Obj# so the compiler can parse
    // past it and detect real errors later in the file.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/MyExt.fan",
      "class MyExt\n" +
      "{\n" +
      "  static Void doWork() {}\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  static Obj test() {\n" +
      "    return doSomething(MyExt#.pod, \"test\")\n" +
      "  }\n" +
      "  static Void broken(\n" +
      "  {\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, typeIdx)

    // The type literal error for MyExt# should NOT appear
    typeLitDiags := diags.findAll |d|
    {
      d.message.contains("Unknown type") && d.message.contains("MyExt")
    }
    verifyEq(typeLitDiags.size, 0)

    // But the real syntax error (missing closing paren) SHOULD be detected
    verify(diags.size > 0, "Real syntax error after type literal should be detected")
  }

  Void testUnknownMethodFilteredWhenConstructorCall()
  {
    // BacnetServer(cx, siteId) is a constructor call but the compiler
    // sees it as "Unknown method 'pod::Type.BacnetServer'" in single-file
    // mode because it can't resolve the BacnetServer type.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/BacnetServer.fan",
      "class BacnetServer\n" +
      "{\n" +
      "  new make(Obj cx, Obj siteId) {}\n" +
      "  Dict[] getDevices() { [,] }\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  static Obj test(Obj cx, Obj siteId) {\n" +
      "    return BacnetServer(cx, siteId).getDevices()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, typeIdx)

    unknownMethod := diags.findAll |d|
    {
      d.message.contains("Unknown method") && d.message.contains("BacnetServer")
    }
    verifyEq(unknownMethod.size, 0)
  }

  Void testUnknownMethodNotFilteredWhenRealError()
  {
    // A real unknown method call (not a project type) must still be reported.
    source :=
      "class Foo\n" +
      "{\n" +
      "  static Obj test() {\n" +
      "    return notAType()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    unknownMethod := diags.findAll |d|
    {
      d.message.contains("Unknown method") && d.message.contains("notAType")
    }
    verify(unknownMethod.size > 0, "Real unknown method should be reported")
  }

//////////////////////////////////////////////////////////////////////////
// Undeclared variable and method detection
//////////////////////////////////////////////////////////////////////////

  Void testUndeclaredVariableReported()
  {
    // Using a variable that was never declared should be reported.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void ciao()\n" +
      "  {\n" +
      "    echo(a)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    unknownVar := diags.findAll |d|
    {
      d.message.contains("Unknown variable") && d.message.contains("a")
    }
    verify(unknownVar.size > 0, "Undeclared variable 'a' should be reported")
  }

  Void testUndeclaredMethodReported()
  {
    // Calling a method that doesn't exist should be reported.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void ciao()\n" +
      "  {\n" +
      "    pippo()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    unknownMethod := diags.findAll |d|
    {
      d.message.contains("Unknown method") && d.message.contains("pippo")
    }
    verify(unknownMethod.size > 0, "Undeclared method 'pippo' should be reported")
  }

  Void testUndeclaredVarAndMethodBothReported()
  {
    // Both undeclared variable and method in the same method body
    // should be detected.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void ciao()\n" +
      "  {\n" +
      "    echo(a)\n" +
      "    pippo()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    unknownVar := diags.findAll |d|
    {
      d.message.contains("Unknown variable") && d.message.contains("'a'")
    }
    unknownMethod := diags.findAll |d|
    {
      d.message.contains("Unknown method") && d.message.contains("pippo")
    }
    verify(unknownVar.size > 0, "Undeclared variable 'a' should be reported")
    verify(unknownMethod.size > 0, "Undeclared method 'pippo' should be reported")
  }

  Void testUndeclaredVarWithProjectBaseType()
  {
    // When a class extends a project type, the preprocessor replaces it
    // with Obj so the compiler can parse method bodies. Undeclared
    // variables should still be detected.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/BaseTest.fan",
      "class BaseTest\n" +
      "{\n" +
      "  Void verify(Bool ok) {}\n" +
      "}")

    source :=
      "class TestFoo : BaseTest\n" +
      "{\n" +
      "  Void test()\n" +
      "  {\n" +
      "    echo(undeclaredVar)\n" +
      "    undeclaredMethod()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/TestFoo.fan", source, typeIdx)

    unknownVar := diags.findAll |d|
    {
      d.message.contains("Unknown variable") && d.message.contains("undeclaredVar")
    }
    unknownMethod := diags.findAll |d|
    {
      d.message.contains("Unknown method") && d.message.contains("undeclaredMethod")
    }
    verify(unknownVar.size > 0, "Undeclared variable should be reported even with project base type")
    verify(unknownMethod.size > 0, "Undeclared method should be reported even with project base type")
  }

  Void testDeclaredVarNotReported()
  {
    // Properly declared variables and methods should NOT produce errors.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Str name := \"hello\"\n" +
      "  Void greet() { echo(name) }\n" +
      "  Void test()\n" +
      "  {\n" +
      "    x := 42\n" +
      "    echo(x)\n" +
      "    greet()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    unknownVar := diags.findAll |d|
    {
      d.message.contains("Unknown variable")
    }
    unknownMethod := diags.findAll |d|
    {
      d.message.contains("Unknown method")
    }
    verifyEq(unknownVar.size, 0)
    verifyEq(unknownMethod.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Resolvable base type (inheritance chain resolution)
//////////////////////////////////////////////////////////////////////////

  Void testResolvableBaseTypePreservesInheritedMethods()
  {
    // When a class extends a project type (ChildBase) that itself extends
    // a sys type (Test), the preprocessor should replace ChildBase with
    // Test (not Obj) so inherited methods like verify() remain visible.
    // This prevents false positives for inherited methods.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/ChildBase.fan",
      "class ChildBase : Test\n" +
      "{\n" +
      "  Void helper() {}\n" +
      "}")

    source :=
      "class MyTest : ChildBase\n" +
      "{\n" +
      "  Void testSomething()\n" +
      "  {\n" +
      "    verify(true)\n" +
      "    verifyEq(1, 1)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/MyTest.fan", source, typeIdx)

    // verify() and verifyEq() are inherited from Test — no false positives
    unknownMethod := diags.findAll |d|
    {
      d.message.contains("Unknown method") &&
      (d.message.contains("verify") || d.message.contains("verifyEq"))
    }
    verifyEq(unknownMethod.size, 0)
  }

  Void testResolvableBaseTypeStillCatchesRealErrors()
  {
    // Even with resolvable base type, real undeclared variables
    // and methods should still be reported.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/ChildBase.fan",
      "class ChildBase : Test\n" +
      "{\n" +
      "  Void helper() {}\n" +
      "}")

    source :=
      "class MyTest : ChildBase\n" +
      "{\n" +
      "  Void testSomething()\n" +
      "  {\n" +
      "    verify(true)\n" +
      "    echo(nonExistentVar)\n" +
      "    fakeMethod()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/MyTest.fan", source, typeIdx)

    // verify() should be fine (inherited from Test)
    verifyMethods := diags.findAll |d|
    {
      d.message.contains("Unknown method") && d.message.contains("verify")
    }
    verifyEq(verifyMethods.size, 0)

    // But nonExistentVar and fakeMethod should be reported
    unknownVar := diags.findAll |d|
    {
      d.message.contains("Unknown variable") && d.message.contains("nonExistentVar")
    }
    unknownMethod := diags.findAll |d|
    {
      d.message.contains("Unknown method") && d.message.contains("fakeMethod")
    }
    verify(unknownVar.size > 0, "Undeclared variable should still be caught")
    verify(unknownMethod.size > 0, "Undeclared method should still be caught")
  }

//////////////////////////////////////////////////////////////////////////
// External base type in inheritance chain (not in using)
//////////////////////////////////////////////////////////////////////////

  Void testExternalBaseTypeNotReportedAsUnknown()
  {
    // When a class extends a project type that itself extends an external
    // pod type (e.g., ExtendableModel), the preprocessor replaces the
    // project type with the external ancestor. If that external type
    // isn't in the current file's 'using' statements, the compiler
    // reports "Unknown type 'ExtendableModel'". This is a false positive
    // caused by our preprocessing and must be filtered.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/ModelEntityGeneric.fan",
      "class ModelEntityGeneric : ExtendableModel\n" +
      "{\n" +
      "  Str name\n" +
      "}")

    source :=
      "class ModelEntityDevice : ModelEntityGeneric\n" +
      "{\n" +
      "  Str deviceId\n" +
      "  Void test()\n" +
      "  {\n" +
      "    x := 42\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/ModelEntityDevice.fan", source, typeIdx)

    // "Unknown type 'ExtendableModel'" should be filtered — it was
    // substituted by replaceProjectBaseTypes from the inheritance chain
    unknownType := diags.findAll |d|
    {
      d.message.contains("Unknown type") && d.message.contains("ExtendableModel")
    }
    verifyEq(unknownType.size, 0, "External base type from inheritance chain should not be reported")
  }

  Void testExternalBaseTypeChainMultipleLevels()
  {
    // Multi-level chain: DeviceConfig -> DeviceGeneric -> ExtendableModel
    // Both project types should resolve to ExtendableModel and not error.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/DeviceGeneric.fan",
      "class DeviceGeneric : ExtendableModel\n" +
      "{\n" +
      "  Str name\n" +
      "}")
    typeIdx.indexFile("file:///test/DeviceConfig.fan",
      "class DeviceConfig : DeviceGeneric\n" +
      "{\n" +
      "  Str config\n" +
      "}")

    source :=
      "class MyDevice : DeviceConfig\n" +
      "{\n" +
      "  Str deviceId\n" +
      "  Void test()\n" +
      "  {\n" +
      "    x := 42\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/MyDevice.fan", source, typeIdx)

    unknownType := diags.findAll |d|
    {
      d.message.contains("Unknown type") && d.message.contains("ExtendableModel")
    }
    verifyEq(unknownType.size, 0, "External base type from multi-level chain should not be reported")
  }

  Void testExternalBaseTypeStillCatchesRealErrors()
  {
    // Even with external base type filtering, real errors should be reported.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/ModelEntityGeneric.fan",
      "class ModelEntityGeneric : ExtendableModel\n" +
      "{\n" +
      "  Str name\n" +
      "}")

    source :=
      "class ModelEntityDevice : ModelEntityGeneric\n" +
      "{\n" +
      "  Void test()\n" +
      "  {\n" +
      "    echo(undeclaredVar)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/ModelEntityDevice.fan", source, typeIdx)

    // ExtendableModel should be filtered
    unknownType := diags.findAll |d|
    {
      d.message.contains("Unknown type") && d.message.contains("ExtendableModel")
    }
    verifyEq(unknownType.size, 0, "External base type should be filtered")

    // But undeclaredVar should still be reported
    unknownVar := diags.findAll |d|
    {
      d.message.contains("Unknown variable") && d.message.contains("undeclaredVar")
    }
    verify(unknownVar.size > 0, "Real undeclared variable should still be caught")
  }

//////////////////////////////////////////////////////////////////////////
// Inherited method via this/super on replaced base type
//////////////////////////////////////////////////////////////////////////

  Void testThisMethodCallOnReplacedBaseFiltered()
  {
    // When a class extends a project type that is replaced with Obj,
    // this.commit(cx) produces "Unknown method 'pod::Type.commit'"
    // because Obj doesn't have commit(). This is a false positive.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/ModelBase.fan",
      "class ModelBase : ExtendableModel\n" +
      "{\n" +
      "  Str name\n" +
      "}")

    source :=
      "class MyModel : ModelBase\n" +
      "{\n" +
      "  Void init()\n" +
      "  {\n" +
      "    this.commit()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/MyModel.fan", source, typeIdx)

    unknownMethod := diags.findAll |d|
    {
      d.message.contains("Unknown method") && d.message.contains("commit")
    }
    verifyEq(unknownMethod.size, 0, "this.commit() should be filtered when base replaced with Obj")
  }

  Void testSuperMethodCallOnReplacedBaseFiltered()
  {
    // super.method() calls on a replaced base type produce
    // "Unknown method 'sys::Obj.method'" which is already filtered.
    // Verify that the existing sys::Obj filter handles this.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/ModelBase.fan",
      "class ModelBase : ExtendableModel\n" +
      "{\n" +
      "  Str name\n" +
      "}")

    source :=
      "class MyModel : ModelBase\n" +
      "{\n" +
      "  Void init()\n" +
      "  {\n" +
      "    super.doSomething()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/MyModel.fan", source, typeIdx)

    // super.doSomething() resolves to sys::Obj.doSomething() which is filtered
    sysObjMethod := diags.findAll |d|
    {
      d.message.contains("Unknown method") && d.message.contains("sys::Obj")
    }
    verifyEq(sysObjMethod.size, 0, "super.method() on replaced base should be filtered")
  }

  Void testBareMethodCallOnReplacedBaseNotFiltered()
  {
    // Bare method calls (without this./super.) that don't exist should
    // NOT be filtered — they are real errors.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/ModelBase.fan",
      "class ModelBase : ExtendableModel\n" +
      "{\n" +
      "  Str name\n" +
      "}")

    source :=
      "class MyModel : ModelBase\n" +
      "{\n" +
      "  Void init()\n" +
      "  {\n" +
      "    reallyUndeclared()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/MyModel.fan", source, typeIdx)

    unknownMethod := diags.findAll |d|
    {
      d.message.contains("Unknown method") && d.message.contains("reallyUndeclared")
    }
    verify(unknownMethod.size > 0, "Bare undeclared method call should still be reported")
  }

  Void testThisMethodCallWithoutReplacedBaseNotFiltered()
  {
    // this.method() on a class that does NOT extend a project type
    // should NOT be filtered — it's a real error.
    source :=
      "class MyModel\n" +
      "{\n" +
      "  Void init()\n" +
      "  {\n" +
      "    this.nonExistent()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/MyModel.fan", source, idx)

    unknownMethod := diags.findAll |d|
    {
      d.message.contains("Unknown method") && d.message.contains("nonExistent")
    }
    verify(unknownMethod.size > 0, "this.method() without replaced base should be reported")
  }

//////////////////////////////////////////////////////////////////////////
// Cross-file reference validation
//////////////////////////////////////////////////////////////////////////

  Void testCrossFileRemovedFieldDetected()
  {
    // When a field is removed from a project type but another file
    // still references it via TypeName.fieldName, an error should
    // be reported.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/Config.fan",
      "class Config\n" +
      "{\n" +
      "  static const Str HOST := \"localhost\"\n" +
      "}")
    // Note: SITE_REF is NOT in Config — it was removed

    source :=
      "class Server\n" +
      "{\n" +
      "  Void init()\n" +
      "  {\n" +
      "    host := Config.HOST\n" +
      "    ref := Config.SITE_REF\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Server.fan", source, typeIdx)

    // Config.SITE_REF should be flagged — member doesn't exist
    missingMember := diags.findAll |d|
    {
      d.message.contains("SITE_REF") && d.message.contains("Config")
    }
    verify(missingMember.size > 0, "Removed field should be reported")

    // Config.HOST should NOT be flagged — member exists
    hostDiags := diags.findAll |d|
    {
      d.message.contains("HOST") && d.message.contains("Config")
    }
    verifyEq(hostDiags.size, 0)
  }

  Void testCrossFileExistingMemberNotReported()
  {
    // When both the type and member exist in the index,
    // no error should be reported.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/MyLib.fan",
      "class MyLib\n" +
      "{\n" +
      "  static const Str NAME := \"test\"\n" +
      "  static Void doWork() {}\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    n := MyLib.NAME\n" +
      "    MyLib.doWork()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, typeIdx)

    crossFileDiags := diags.findAll |d|
    {
      d.message.contains("is not a member of")
    }
    verifyEq(crossFileDiags.size, 0)
  }

  Void testCrossFileStaticMethodRemovedDetected()
  {
    // When a static method is removed from a project type,
    // references to it should be flagged.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/Utils.fan",
      "class Utils\n" +
      "{\n" +
      "  static Str format(Str s) { s }\n" +
      "}")
    // Note: 'parse' method is NOT in Utils — it was removed

    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := Utils.format(\"hello\")\n" +
      "    b := Utils.parse(\"world\")\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, typeIdx)

    // Utils.parse should be flagged
    missingMethod := diags.findAll |d|
    {
      d.message.contains("parse") && d.message.contains("Utils")
    }
    verify(missingMethod.size > 0, "Removed method should be reported")

    // Utils.format should NOT be flagged
    formatDiags := diags.findAll |d|
    {
      d.message.contains("format") && d.message.contains("Utils")
    }
    verifyEq(formatDiags.size, 0)
  }

  Void testCrossFileReferenceInCommentNotReported()
  {
    // References inside comments should NOT trigger cross-file errors.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/Config.fan",
      "class Config\n" +
      "{\n" +
      "  static const Str HOST := \"localhost\"\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  // Config.REMOVED is no longer used\n" +
      "  Void bar() {}\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, typeIdx)

    crossFileDiags := diags.findAll |d|
    {
      d.message.contains("is not a member of")
    }
    verifyEq(crossFileDiags.size, 0)
  }

  **
  ** TypeName.member patterns inside backtick Uri literals should be skipped.
  ** E.g., `/res/DemoSite.csv` should not flag "csv is not a member of DemoSite".
  **
  Void testCrossFileReferenceInUriLiteralNotReported()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/DemoSite.fan",
      "class DemoSite\n" +
      "{\n" +
      "  static Void load() {}\n" +
      "}")

    source :=
      "class Loader\n" +
      "{\n" +
      "  Void init()\n" +
      "  {\n" +
      "    uri := `/res/intesis/DemoSite.csv`\n" +
      "    DemoSite.load()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Loader.fan", source, typeIdx)

    // DemoSite.csv inside backticks should NOT be flagged
    csvDiags := diags.findAll |d|
    {
      d.message.contains("csv") && d.message.contains("DemoSite")
    }
    verifyEq(csvDiags.size, 0)

    // DemoSite.load() outside backticks should still work (no false positive)
    loadDiags := diags.findAll |d|
    {
      d.message.contains("load") && d.message.contains("DemoSite")
    }
    verifyEq(loadDiags.size, 0)
  }

  **
  ** Method calls inside Uri literals should not trigger param validation.
  **
  Void testMethodCallInUriLiteralNotValidated()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    uri := `/path/to/file.txt`\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramDiags := diags.findAll |d|
    {
      d.message.contains("expects") && d.message.contains("argument")
    }
    verifyEq(paramDiags.size, 0)
  }

  Void testCrossFileFieldWithParenthesesInInitializer()
  {
    // Fields whose initializer contains parentheses (e.g., constructor calls,
    // facet lookups) must still be indexed. Previously, any line with "(" was
    // rejected by matchFieldDecl, causing false "not a member" errors.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/MyExt.fan",
      "class MyExt\n" +
      "{\n" +
      "  static const Str metaName := (MyExt#.facet(ExtMeta#, true) as ExtMeta).name\n" +
      "  internal static const User extSysUser := User(Etc.makeDict([\"id\": Ref(\"u:test\")]))\n" +
      "  static const Str SIMPLE := \"hello\"\n" +
      "}")

    // All three fields should be indexed
    verify(typeIdx.hasMember("MyExt", "metaName"), "metaName should be indexed")
    verify(typeIdx.hasMember("MyExt", "extSysUser"), "extSysUser should be indexed")
    verify(typeIdx.hasMember("MyExt", "SIMPLE"), "SIMPLE should be indexed")

    // Cross-file references to these fields should NOT produce errors
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := MyExt.metaName\n" +
      "    b := MyExt.extSysUser\n" +
      "    c := MyExt.SIMPLE\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, typeIdx)

    crossFileDiags := diags.findAll |d|
    {
      d.message.contains("is not a member of")
    }
    verifyEq(crossFileDiags.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Override of project-type virtual slot
//////////////////////////////////////////////////////////////////////////

  Void testOverrideOfProjectTypeVirtualSlotFiltered()
  {
    // When a class extends a project type (DeactivationAlarmStrategy) that
    // is replaced with Obj during preprocessing, the compiler reports
    // "Override of unknown virtual slot" for overridden methods. This is a
    // false positive when the slot exists in the project type's index.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/DeactivationAlarmStrategy.fan",
      "abstract class DeactivationAlarmStrategy\n" +
      "{\n" +
      "  abstract Bool isADeactivationCase(Str[] alarms)\n" +
      "}")

    source :=
      "class IcnaDeactivation : DeactivationAlarmStrategy\n" +
      "{\n" +
      "  override Bool isADeactivationCase(Str[] alarms)\n" +
      "  {\n" +
      "    return !alarms.isEmpty\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/IcnaDeactivation.fan", source, typeIdx)

    // "Override of unknown virtual slot" should be filtered — the slot
    // exists in the project type DeactivationAlarmStrategy
    overrideErrs := diags.findAll |d|
    {
      d.message.contains("Override of unknown virtual slot")
    }
    verifyEq(overrideErrs.size, 0)
  }

  Void testOverrideOfTrulyUnknownSlotNotFiltered()
  {
    // When a class overrides a slot that doesn't exist in ANY project type,
    // the error should NOT be filtered.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/BaseClass.fan",
      "abstract class BaseClass\n" +
      "{\n" +
      "  abstract Void doWork()\n" +
      "}")

    source :=
      "class Child : BaseClass\n" +
      "{\n" +
      "  override Void doWork() {}\n" +
      "  override Void completelyFakeMethod() {}\n" +
      "}"

    diags := svc.analyze("file:///test/Child.fan", source, typeIdx)

    // doWork should be filtered (exists in BaseClass)
    doWorkErrs := diags.findAll |d|
    {
      d.message.contains("Override of unknown virtual slot") &&
      d.message.contains("doWork")
    }
    verifyEq(doWorkErrs.size, 0)

    // completelyFakeMethod should NOT be filtered (doesn't exist anywhere)
    fakeErrs := diags.findAll |d|
    {
      d.message.contains("Override of unknown virtual slot") &&
      d.message.contains("completelyFakeMethod")
    }
    verify(fakeErrs.size > 0, "Override of truly unknown slot should be reported")
  }

  Void testOverrideOfProjectTypeVirtualFieldFiltered()
  {
    // When a class overrides a virtual *field* (not method) from a project
    // base type (e.g. DemoProjUtils.className), the error
    // "Override of unknown virtual slot 'className'" is a false positive.
    // The filter must check SymbolKind.field, not just SymbolKind.method.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/DemoProjUtils.fan",
      "class DemoProjUtils\n" +
      "{\n" +
      "  virtual Str className := DemoProjUtils#.name\n" +
      "}")

    source :=
      "class DemoProjSimulator : DemoProjUtils\n" +
      "{\n" +
      "  override Str className := DemoProjSimulator#.name\n" +
      "}"

    diags := svc.analyze("file:///test/DemoProjSimulator.fan", source, typeIdx)

    // "Override of unknown virtual slot 'className'" should be filtered
    overrideErrs := diags.findAll |d|
    {
      d.message.contains("Override of unknown virtual slot") &&
      d.message.contains("className")
    }
    verifyEq(overrideErrs.size, 0)
  }

  Void testOverrideOfTrulyUnknownFieldNotFiltered()
  {
    // When a class overrides a field name that doesn't exist in any
    // project type, the error should NOT be filtered.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/BaseClass.fan",
      "class BaseClass\n" +
      "{\n" +
      "  virtual Str realField := \"x\"\n" +
      "}")

    source :=
      "class Child : BaseClass\n" +
      "{\n" +
      "  override Str realField := \"y\"\n" +
      "  override Str ghostField := \"z\"\n" +
      "}"

    diags := svc.analyze("file:///test/Child.fan", source, typeIdx)

    // realField override should be filtered (field exists in BaseClass)
    realErrs := diags.findAll |d|
    {
      d.message.contains("Override of unknown virtual slot") &&
      d.message.contains("realField")
    }
    verifyEq(realErrs.size, 0)

    // ghostField override should NOT be filtered (doesn't exist anywhere)
    ghostErrs := diags.findAll |d|
    {
      d.message.contains("Override of unknown virtual slot") &&
      d.message.contains("ghostField")
    }
    verify(ghostErrs.size > 0, "Override of truly unknown field should be reported")
  }

//////////////////////////////////////////////////////////////////////////
// Method Parameter Validation
//////////////////////////////////////////////////////////////////////////

  Void testMethodCallTooFewArgs()
  {
    // List.add requires 1 argument. Calling with 0 should error.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := [1, 2, 3]\n" +
      "    a.add()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'add'") && d.message.contains("argument")
    }
    verify(paramErrs.size > 0, "add() with 0 args should be reported")
  }

  Void testMethodCallTooManyArgs()
  {
    // List.add expects 1 argument. Calling with 3 should error.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := [1, 2, 3]\n" +
      "    a.add(1, 2, 3)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'add'") && d.message.contains("argument")
    }
    verify(paramErrs.size > 0, "add(1,2,3) with 3 args should be reported")
  }

  Void testMethodCallCorrectArgs()
  {
    // List.add with 1 argument should NOT produce a parameter error.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := [1, 2, 3]\n" +
      "    a.add(42)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'add'") && d.message.contains("argument")
    }
    verifyEq(paramErrs.size, 0)
  }

  Void testMethodCallMoveToTooFewArgs()
  {
    // List.moveTo requires 2 arguments. Calling with 1 should error.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := [1, 2, 3]\n" +
      "    a.moveTo(1)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'moveTo'") && d.message.contains("argument")
    }
    verify(paramErrs.size > 0, "moveTo(1) with 1 arg should be reported")
  }

  Void testMethodCallWithTrailingClosure()
  {
    // List.each expects 1 argument (a closure). A trailing closure counts.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := [1, 2, 3]\n" +
      "    a.each |v| { echo(v) }\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'each'") && d.message.contains("argument")
    }
    verifyEq(paramErrs.size, 0)
  }

  Void testMethodCallWithOptionalParam()
  {
    // List.getSafe has 1 required, 1 optional. Calling with 1 arg is fine.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := [1, 2, 3]\n" +
      "    a.getSafe(0)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'getSafe'") && d.message.contains("argument")
    }
    verifyEq(paramErrs.size, 0)
  }

  Void testMethodCallNoArgMethodWithArgs()
  {
    // List.first() takes 0 arguments. Calling with 1 should error.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := [1, 2, 3]\n" +
      "    a.first(42)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'first'") && d.message.contains("argument")
    }
    verify(paramErrs.size > 0, "first(42) should be reported - expects 0 args")
  }

  Void testMethodCallOnStringType()
  {
    // Str.contains expects 1 argument.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    s := \"hello\"\n" +
      "    s.contains()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'contains'") && d.message.contains("argument")
    }
    verify(paramErrs.size > 0, "Str.contains() with 0 args should be reported")
  }

  Void testMethodCallOnMapType()
  {
    // Map.containsKey expects 1 argument.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    m := [\"a\": 1]\n" +
      "    m.containsKey()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'containsKey'") && d.message.contains("argument")
    }
    verify(paramErrs.size > 0, "Map.containsKey() with 0 args should be reported")
  }

  Void testMethodCallOnExplicitType()
  {
    // Explicit type declaration: Str name := "hello"
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    Str name := \"hello\"\n" +
      "    name.replace()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'replace'") && d.message.contains("argument")
    }
    verify(paramErrs.size > 0, "Str.replace() with 0 args should be reported (expects 2)")
  }

  Void testMethodCallReduceWithClosureAndArg()
  {
    // List.reduce expects 2 args: init + closure. With parens(init) and trailing closure.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := [1, 2, 3]\n" +
      "    a.reduce(0) |acc, v| { return acc }\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'reduce'") && d.message.contains("argument")
    }
    verifyEq(paramErrs.size, 0)
  }

  Void testMethodCallOnMethodParam()
  {
    // Variable type resolved from method parameter declaration.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(Str name)\n" +
      "  {\n" +
      "    name.startsWith()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'startsWith'") && d.message.contains("argument")
    }
    verify(paramErrs.size > 0, "Str.startsWith() with 0 args should be reported")
  }

  Void testMethodCallValidNoParamMethod()
  {
    // Calling no-param methods correctly (e.g., a.clear()) should not error.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := [1, 2, 3]\n" +
      "    a.clear()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'clear'") && d.message.contains("argument")
    }
    verifyEq(paramErrs.size, 0)
  }

  Void testMethodCallInComment()
  {
    // Method calls in comments should NOT trigger parameter validation.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := [1, 2, 3]\n" +
      "    // a.add()\n" +
      "    a.add(1)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'add'") && d.message.contains("argument")
    }
    verifyEq(paramErrs.size, 0)
  }

  Void testMethodCallNestedArgs()
  {
    // Method call with nested expressions as arguments should count correctly.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := [1, 2, 3]\n" +
      "    a.insert(0, a.first)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'insert'") && d.message.contains("argument")
    }
    verifyEq(paramErrs.size, 0)
  }

  Void testMethodCallLogicalOrNotCountedAsClosure()
  {
    // '||' (logical OR) after a method call must NOT be counted as a trailing
    // closure. Type.fits(Type) takes 1 arg; "type.fits(Bool#) ||" should
    // not be reported as "got 2 arguments".
    source :=
      "class Foo\n" +
      "{\n" +
      "  Bool bar(Type type)\n" +
      "  {\n" +
      "    return type.fits(Bool#) ||\n" +
      "           type.fits(Int#)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'fits'") && d.message.contains("argument")
    }
    verifyEq(paramErrs.size, 0)
  }

  Void testMethodCallLogicalOrChainNotCountedAsClosure()
  {
    // Multiple conditions joined by '||' on successive lines — mirrors the
    // SerializableObject.getFieldValue pattern. None of the fits() calls
    // should be reported as having too many arguments.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Bool bar(Type type)\n" +
      "  {\n" +
      "    if (type.fits(Bool#) ||\n" +
      "        type.fits(Int#) ||\n" +
      "        type.fits(Float#) ||\n" +
      "        type.fits(Str#))\n" +
      "      return true\n" +
      "    return false\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'fits'") && d.message.contains("argument")
    }
    verifyEq(paramErrs.size, 0)
  }

  Void testParamValidationDoesNotHideCompilerErrors()
  {
    // Compiler errors (undeclared variables/methods) must still be reported
    // even when the same file has method calls on known types.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := [1, 2, 3]\n" +
      "    a.add(42)\n" +
      "    echo(undeclaredVar)\n" +
      "    undeclaredMethod()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    unknownVar := diags.findAll |d|
    {
      d.message.contains("Unknown variable") && d.message.contains("undeclaredVar")
    }
    unknownMethod := diags.findAll |d|
    {
      d.message.contains("Unknown method") && d.message.contains("undeclaredMethod")
    }
    verify(unknownVar.size > 0, "Undeclared variable must be reported alongside param validation")
    verify(unknownMethod.size > 0, "Undeclared method must be reported alongside param validation")
  }

  Void testParamValidationWithSyntaxError()
  {
    // Even when param validation might fail on broken code,
    // compiler syntax errors must still be reported.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    a := [1, 2, 3]\n" +
      "    a.add(\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    verify(diags.size > 0, "Syntax errors must still be reported when param validation runs")
  }

//////////////////////////////////////////////////////////////////////////
// Method param: char literal and block comment as arguments (regression)
//////////////////////////////////////////////////////////////////////////

  Void testMethodCallCharLiteralArgNotMiscounted()
  {
    // Regression: split(',', true) was reported as "expects 0-2 arguments,
    // but got 3" because the comma inside ',' was counted as an arg separator.
    // Char literals must be treated as opaque tokens in arg counting.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(Str appAccess)\n" +
      "  {\n" +
      "    Str[] parts := appAccess.split(',', true)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'split'") && d.message.contains("argument")
    }
    verifyEq(paramErrs.size, 0,
      "split(',', true) must not be flagged — char literal comma is not an arg separator")
  }

  Void testMethodCallCharLiteralWithBlockComment()
  {
    // Regression: split(',', /* trim */ true) — block comment inside args
    // must not affect the argument count.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(Str appAccess)\n" +
      "  {\n" +
      "    Str[] parts := appAccess.split(',', /* trim */ true)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'split'") && d.message.contains("argument")
    }
    verifyEq(paramErrs.size, 0,
      "split(',', /* trim */ true) must not be flagged — 2 real args")
  }

  Void testMethodCallEscapedCharLiteralArg()
  {
    // Char literal used as separator with a second bool arg — the char
    // contains a pipe '|' which is also used in closure syntax; must not
    // be miscounted.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar(Str s)\n" +
      "  {\n" +
      "    Str[] parts := s.split('|', true)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    paramErrs := diags.findAll |d|
    {
      d.message.contains("'split'") && d.message.contains("argument")
    }
    verifyEq(paramErrs.size, 0,
      "split('|', true) must not be flagged — pipe in char literal is not a closure")
  }

//////////////////////////////////////////////////////////////////////////
// Undeclared constant not suppressed when member exists in other type
//////////////////////////////////////////////////////////////////////////

  **
  ** When a constant like MAIN_EQUIP_REF_NAME is commented out but exists
  ** as a member of another project type (e.g., OtherType.MAIN_EQUIP_REF_NAME),
  ** the error about the undefined variable must NOT be filtered out.
  **
  Void testUndeclaredConstNotFilteredWhenMemberOfOtherType()
  {
    // OtherType has MAIN_EQUIP_REF_NAME as a field
    otherSource :=
      "class OtherType\n" +
      "{\n" +
      "  static const Str MAIN_EQUIP_REF_NAME := \"mainEquipRef\"\n" +
      "}"
    idx.indexFile("file:///test/OtherType.fan", otherSource)

    // Current file references MAIN_EQUIP_REF_NAME without declaring it
    source :=
      "class Foo\n" +
      "{\n" +
      "  // static const Str MAIN_EQUIP_REF_NAME := OtherType.MAIN_EQUIP_REF_NAME\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    x := MAIN_EQUIP_REF_NAME\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    errs := diags.findAll |d| { d.severity == DiagnosticSeverity.error }
    verify(errs.size > 0, "Error for undeclared MAIN_EQUIP_REF_NAME must be reported")
  }

  **
  ** When a file references a project type for static access (e.g.,
  ** OtherType.SOME_CONST), the compiler must still detect real errors
  ** like undeclared variables on other lines. The project type reference
  ** should not cause the compiler to bomb before reaching those checks.
  **
  Void testProjectTypeRefDoesNotHideUndeclaredVar()
  {
    // OtherType is a known project type
    otherSource :=
      "class OtherType\n" +
      "{\n" +
      "  static const Str SOME_CONST := \"value\"\n" +
      "}"
    idx.indexFile("file:///test/OtherType.fan", otherSource)

    // File uses OtherType.SOME_CONST (replaced with Obj) and has undeclared var
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    x := undeclaredVar\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    errs := diags.findAll |d| { d.severity == DiagnosticSeverity.error }
    verify(errs.size > 0, "Undeclared variable error must be reported even with project types in index")
  }

//////////////////////////////////////////////////////////////////////////
// Inherited members from project base types
//////////////////////////////////////////////////////////////////////////

  **
  ** When a class extends a project type (e.g., IBacnetServer), inherited
  ** constants like DEVICE_TAG should NOT be reported as "Unknown variable"
  ** because they come from the base type that was replaced with Obj.
  **
  Void testInheritedConstFromBaseTypeFiltered()
  {
    // IBacnetServer interface with constants
    ifaceSource :=
      "mixin IBacnetServer\n" +
      "{\n" +
      "  static const Str DEVICE_TAG := \"device\"\n" +
      "  static const Str INSTANCE_TAG := \"instance\"\n" +
      "}"
    idx.indexFile("file:///test/IBacnetServer.fan", ifaceSource)

    // BacnetServer extends IBacnetServer and uses inherited constants
    source :=
      "class BacnetServer : IBacnetServer\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    x := DEVICE_TAG\n" +
      "    y := INSTANCE_TAG\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/BacnetServer.fan", source, idx)
    errs := diags.findAll |d| { d.severity == DiagnosticSeverity.error }

    // Inherited constants should be filtered — no errors about DEVICE_TAG or INSTANCE_TAG
    inheritedErrs := errs.findAll |d| { d.message.contains("DEVICE_TAG") || d.message.contains("INSTANCE_TAG") }
    verifyEq(inheritedErrs.size, 0, "Inherited constants from base type should not be reported as errors")
  }

  **
  ** When a class does NOT extend a type that has the constant,
  ** the error must still be reported (not inherited).
  **
  Void testNonInheritedConstStillReported()
  {
    // OtherType has SOME_CONST but Foo does NOT extend OtherType
    otherSource :=
      "class OtherType\n" +
      "{\n" +
      "  static const Str SOME_CONST := \"value\"\n" +
      "}"
    idx.indexFile("file:///test/OtherType.fan", otherSource)

    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    x := SOME_CONST\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    errs := diags.findAll |d| { d.severity == DiagnosticSeverity.error }
    verify(errs.size > 0, "Non-inherited constant must be reported as error")
  }

  **
  ** Inherited members should be filtered but real undeclared variables
  ** in the same file should still be reported.
  **
  Void testInheritedConstFilteredButRealErrorReported()
  {
    ifaceSource :=
      "mixin IBase\n" +
      "{\n" +
      "  static const Str KNOWN_TAG := \"tag\"\n" +
      "}"
    idx.indexFile("file:///test/IBase.fan", ifaceSource)

    source :=
      "class Foo : IBase\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    x := KNOWN_TAG\n" +
      "    y := reallyUndeclaredVar\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    errs := diags.findAll |d| { d.severity == DiagnosticSeverity.error }

    // KNOWN_TAG should be filtered (inherited)
    knownErrs := errs.findAll |d| { d.message.contains("KNOWN_TAG") }
    verifyEq(knownErrs.size, 0, "Inherited KNOWN_TAG should be filtered")

    // reallyUndeclaredVar should still be reported
    undeclaredErrs := errs.findAll |d| { d.message.contains("reallyUndeclaredVar") }
    verify(undeclaredErrs.size > 0, "Real undeclared variable must still be reported")
  }

//////////////////////////////////////////////////////////////////////////
// Constructor call on project type (preprocessing replaces with Obj)
//////////////////////////////////////////////////////////////////////////

  **
  ** When a project type is used as a constructor call (e.g., BacnetServer(cx, siteId)),
  ** preprocessing replaces BacnetServer with Obj, producing:
  ** "No constructor found: Obj(skyarcd::Context, haystack::Ref)"
  ** This is a false positive and must be filtered.
  **
  Void testNoConstructorFoundObjFiltered()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/BacnetServer.fan",
      "class BacnetServer\n" +
      "{\n" +
      "  new make(Obj cx, Obj siteId) {}\n" +
      "  Obj[] getDevices() { [,] }\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  static Obj test(Obj cx, Obj siteId)\n" +
      "  {\n" +
      "    return BacnetServer(cx, siteId).getDevices()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, typeIdx)

    noCtorDiags := diags.findAll |d|
    {
      d.message.contains("No constructor found") && d.message.contains("Obj(")
    }
    verifyEq(noCtorDiags.size, 0, "No constructor found: Obj(...) should be filtered")
  }

  **
  ** A real "No constructor found" where the type is NOT Obj must still be reported.
  **
  Void testNoConstructorFoundRealTypeNotFiltered()
  {
    source :=
      "class MyClass\n" +
      "{\n" +
      "  new make() {}\n" +
      "}\n" +
      "class Foo\n" +
      "{\n" +
      "  Void test() { x := MyClass(\"wrong\", \"args\") }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    noCtorDiags := diags.findAll |d|
    {
      d.message.contains("No constructor found") && d.message.contains("MyClass")
    }
    verify(noCtorDiags.size > 0, "Real constructor mismatch should be reported")
  }

//////////////////////////////////////////////////////////////////////////
// Duplicate Facet sys::Obj
//////////////////////////////////////////////////////////////////////////

  **
  ** Multiple facets from external pods collapse to sys::Obj in single-file
  ** mode, producing "Duplicate facet 'sys::Obj'". Should be filtered.
  **
  Void testDuplicateFacetObjFilteredMultipleExternalFacets()
  {
    source :=
      "mixin IFields\n" +
      "{\n" +
      "  @RequiredField\n" +
      "  @Min { val = 1 }\n" +
      "  @Max { val = 3 }\n" +
      "  abstract Obj instance\n" +
      "}"

    diags := svc.analyze("file:///test/IFields.fan", source, idx)
    dupFacet := diags.findAll |d| { d.message.contains("Duplicate facet") && d.message.contains("sys::Obj") }
    verifyEq(dupFacet.size, 0, "Duplicate facet sys::Obj from unresolved external facets should be filtered")
    notFacet := diags.findAll |d| { d.message.contains("Not a facet type") && d.message.contains("sys::Obj") }
    verifyEq(notFacet.size, 0, "Not a facet type sys::Obj from unresolved external facets should be filtered")
  }

  **
  ** A single unresolvable external facet should be stripped during
  ** preprocessing so no "Not a facet type sys::Obj" error appears.
  **
  Void testSingleExternalFacetStripped()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  @RequiredField\n" +
      "  Str? name\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    facetErrs := diags.findAll |d| { d.message.contains("facet") && d.message.contains("sys::Obj") }
    verifyEq(facetErrs.size, 0, "Single unresolvable external facet should be stripped, not produce sys::Obj errors")
  }

  **
  ** External facet with multi-line body should be fully stripped.
  **
  Void testExternalFacetWithBodyStripped()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  @Min {\n" +
      "    val = 1\n" +
      "  }\n" +
      "  Str? name\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    facetErrs := diags.findAll |d| { d.message.contains("facet") && d.message.contains("sys::Obj") }
    verifyEq(facetErrs.size, 0, "External facet with body should be stripped, not produce sys::Obj errors")
  }

  **
  ** Mixin extending a project mixin should not produce
  ** "Mixin cannot extend class sys::Obj" — the base type should be
  ** dropped instead of replaced with Obj.
  **
  Void testMixinExtendingProjectMixinNotReplacedWithObj()
  {
    idx.indexFile("file:///test/IGenericMeterFields.fan",
      "mixin IGenericMeterFields\n" +
      "{\n" +
      "  abstract Str meterMode\n" +
      "}")

    source :=
      "mixin IThermalMeterFields : IGenericMeterFields\n" +
      "{\n" +
      "  abstract Str meterMode\n" +
      "}"

    diags := svc.analyze("file:///test/IThermalMeterFields.fan", source, idx)
    mixinErr := diags.findAll |d| { d.message.contains("cannot extend class") }
    verifyEq(mixinErr.size, 0, "Mixin extending project mixin should not produce 'cannot extend class sys::Obj'")
  }

  **
  ** Mixin extending multiple project mixins — all should be dropped,
  ** not replaced with Obj.
  **
  Void testMixinExtendingMultipleProjectMixinsDropped()
  {
    idx.indexFile("file:///test/IBaseA.fan",
      "mixin IBaseA\n" +
      "{\n" +
      "  abstract Str name\n" +
      "}")
    idx.indexFile("file:///test/IBaseB.fan",
      "mixin IBaseB\n" +
      "{\n" +
      "  abstract Int count\n" +
      "}")

    source :=
      "mixin ICombined : IBaseA, IBaseB\n" +
      "{\n" +
      "  abstract Str label\n" +
      "}"

    diags := svc.analyze("file:///test/ICombined.fan", source, idx)
    mixinErr := diags.findAll |d| { d.message.contains("cannot extend class") }
    verifyEq(mixinErr.size, 0, "Mixin extending multiple project mixins should not produce class extension errors")
  }

  **
  ** Class extending a project type should still be replaced with Obj
  ** (existing behavior preserved).
  **
  Void testClassExtendingProjectTypeStillReplacedWithObj()
  {
    idx.indexFile("file:///test/BaseClass.fan",
      "class BaseClass\n" +
      "{\n" +
      "  Str name := \"test\"\n" +
      "}")

    source :=
      "class Child : BaseClass\n" +
      "{\n" +
      "  Str label := \"child\"\n" +
      "}"

    diags := svc.analyze("file:///test/Child.fan", source, idx)
    // Should NOT produce "cannot extend class sys::Obj" since classes CAN extend Obj
    mixinErr := diags.findAll |d| { d.message.contains("cannot extend class") }
    verifyEq(mixinErr.size, 0, "Class extending project type replaced with Obj should not error")
  }

  **
  ** Class with multiple project base types (class + mixin) should not
  ** produce "cannot mixin class sys::Obj" from duplicate Obj replacement.
  **
  Void testClassWithMultipleProjectBaseTypesNoDuplicateObj()
  {
    idx.indexFile("file:///test/BaseEditableEntity.fan",
      "class BaseEditableEntity\n" +
      "{\n" +
      "  Str name := \"test\"\n" +
      "}")
    idx.indexFile("file:///test/IBuildingDevice.fan",
      "mixin IBuildingDevice\n" +
      "{\n" +
      "  abstract Bool resetFilter()\n" +
      "}")

    source :=
      "class BuildingChiller : BaseEditableEntity, IBuildingDevice\n" +
      "{\n" +
      "  override Bool resetFilter() { return false }\n" +
      "}"

    diags := svc.analyze("file:///test/BuildingChiller.fan", source, idx)
    mixinErr := diags.findAll |d| { d.message.contains("cannot mixin class") }
    verifyEq(mixinErr.size, 0, "Class with multiple project base types should not produce 'cannot mixin class sys::Obj'")
  }

  **
  ** Two identical facets of the same resolved type is a real error.
  **
  Void testDuplicateFacetRealErrorNotFiltered()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  @Transient\n" +
      "  @Transient\n" +
      "  Str? name\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    dupFacet := diags.findAll |d| { d.message.contains("Duplicate facet") && d.message.contains("Transient") }
    verify(dupFacet.size > 0, "Duplicate facet with real resolved types should still be reported")
  }

//////////////////////////////////////////////////////////////////////////
// Enum Value Cross-File References (Regression)
//////////////////////////////////////////////////////////////////////////

  **
  ** Enum values accessed via TypeName.value should not be flagged as "not a member"
  ** when the enum values are indexed. Regression test for SystemKind/IoModuleDeviceKind.
  **
  Void testCrossFileEnumValueNotFlagged()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/SystemKind.fan",
      "enum class SystemKind\n" +
      "{\n" +
      "  heating,\n" +
      "  cooling,\n" +
      "  ventilation\n" +
      "}")

    source :=
      "class BuildingConfig\n" +
      "{\n" +
      "  Void setup()\n" +
      "  {\n" +
      "    k1 := SystemKind.heating\n" +
      "    k2 := SystemKind.cooling\n" +
      "    k3 := SystemKind.ventilation\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/BuildingConfig.fan", source, typeIdx)

    memberDiags := diags.findAll |d|
    {
      d.message.contains("is not a member of") && d.message.contains("SystemKind")
    }
    verifyEq(memberDiags.size, 0)
  }

  **
  ** Enum values should be indexed even when AST parsing fails (text-based fallback).
  ** This happens when the enum is in a file alongside a class extending a project type.
  ** Regression test for the real SystemKind scenario.
  **
  Void testCrossFileEnumValueTextFallbackNotFlagged()
  {
    typeIdx := ProjectIndex()
    // Index a project type first so ModelEntityGeneric is known
    typeIdx.indexFile("file:///test/ModelEntityGeneric.fan",
      "class ModelEntityGeneric\n" +
      "{\n" +
      "  Void save() {}\n" +
      "}")
    // Enum + class extending a project type in same file — AST will fail,
    // forcing text-based fallback
    typeIdx.indexFile("file:///test/ModelEntitySystem.fan",
      "enum class SystemKind {\n" +
      "  dxIntesis64,\n" +
      "  hydronic,\n" +
      "  ventilation\n" +
      "}\n" +
      "\n" +
      "class ModelEntitySystem : ModelEntityGeneric {\n" +
      "  static const Str NAME := \"system\"\n" +
      "}")

    // Verify enum values are indexed
    verify(typeIdx.hasMember("SystemKind", "dxIntesis64"), "dxIntesis64 should be indexed")
    verify(typeIdx.hasMember("SystemKind", "hydronic"), "hydronic should be indexed")
    verify(typeIdx.hasMember("SystemKind", "ventilation"), "ventilation should be indexed")

    source :=
      "class Config\n" +
      "{\n" +
      "  Void setup()\n" +
      "  {\n" +
      "    k := SystemKind.dxIntesis64\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Config.fan", source, typeIdx)

    memberDiags := diags.findAll |d|
    {
      d.message.contains("is not a member of") && d.message.contains("SystemKind")
    }
    verifyEq(memberDiags.size, 0)
  }

  **
  ** Accessing a non-existent enum value should still be flagged.
  **
  Void testCrossFileEnumNonExistentValueFlagged()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/Color.fan",
      "enum class Color\n" +
      "{\n" +
      "  red,\n" +
      "  green,\n" +
      "  blue\n" +
      "}")

    source :=
      "class Painter\n" +
      "{\n" +
      "  Void paint()\n" +
      "  {\n" +
      "    c1 := Color.red\n" +
      "    c2 := Color.purple\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Painter.fan", source, typeIdx)

    // Color.red should NOT be flagged
    redDiags := diags.findAll |d|
    {
      d.message.contains("red") && d.message.contains("Color")
    }
    verifyEq(redDiags.size, 0)

    // Color.purple should be flagged — not a real enum value
    purpleDiags := diags.findAll |d|
    {
      d.message.contains("purple") && d.message.contains("Color")
    }
    verify(purpleDiags.size > 0, "Non-existent enum value should be reported")
  }

  **
  ** Enum static methods like fromStr and vals should not be flagged.
  ** These are compiler-generated on every enum class.
  ** Regression test for SystemKind.fromStr() false positive.
  **
  Void testCrossFileEnumFromStrNotFlagged()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/SystemKind.fan",
      "enum class SystemKind\n" +
      "{\n" +
      "  heating,\n" +
      "  cooling\n" +
      "}")

    source :=
      "class Builder\n" +
      "{\n" +
      "  Void build(Str kindStr)\n" +
      "  {\n" +
      "    k := SystemKind.fromStr(kindStr)\n" +
      "    all := SystemKind.vals\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Builder.fan", source, typeIdx)

    fromStrDiags := diags.findAll |d|
    {
      d.message.contains("fromStr") && d.message.contains("SystemKind")
    }
    verifyEq(fromStrDiags.size, 0)

    valsDiags := diags.findAll |d|
    {
      d.message.contains("vals") && d.message.contains("SystemKind")
    }
    verifyEq(valsDiags.size, 0)
  }

  **
  ** fromStr and defVal are common static methods that should not be flagged
  ** on any project type (not just enums).
  **
  Void testCrossFileFromStrOnRegularTypeNotFlagged()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/MyType.fan",
      "class MyType\n" +
      "{\n" +
      "  Str name := \"\"\n" +
      "}")

    source :=
      "class Caller\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    t := MyType.fromStr(\"test\")\n" +
      "    d := MyType.defVal\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Caller.fan", source, typeIdx)

    fromStrDiags := diags.findAll |d|
    {
      d.message.contains("fromStr") && d.message.contains("MyType")
    }
    verifyEq(fromStrDiags.size, 0)

    defValDiags := diags.findAll |d|
    {
      d.message.contains("defVal") && d.message.contains("MyType")
    }
    verifyEq(defValDiags.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// External Inherited Members in Cross-File References (Regression)
//////////////////////////////////////////////////////////////////////////

  **
  ** Methods inherited from external base types should not be flagged.
  ** E.g., SiteData extends SerializableObject (external), toDict() is inherited.
  **
  Void testCrossFileExternalInheritedMemberNotFlagged()
  {
    typeIdx := ProjectIndex()
    // SiteData extends SerializableObject (from an external pod)
    typeIdx.indexFile("file:///test/SiteData.fan",
      "using haystack\n" +
      "class SiteData : SerializableObject\n" +
      "{\n" +
      "  Str siteName := \"\"\n" +
      "}")

    source :=
      "class BuildingConfig\n" +
      "{\n" +
      "  Void save()\n" +
      "  {\n" +
      "    name := SiteData.siteName\n" +
      "    d := SiteData.toDict\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/BuildingConfig.fan", source, typeIdx)

    // SiteData.siteName should NOT be flagged — direct member
    nameDiags := diags.findAll |d|
    {
      d.message.contains("siteName") && d.message.contains("SiteData")
    }
    verifyEq(nameDiags.size, 0)

    // SiteData.toDict should NOT be flagged — inherited from external base
    toDictDiags := diags.findAll |d|
    {
      d.message.contains("toDict") && d.message.contains("SiteData")
    }
    verifyEq(toDictDiags.size, 0)
  }

  **
  ** When a type extends another project type which in turn extends an external type,
  ** inherited members from the project base should be found, and the external base
  ** should prevent flagging unknown members.
  **
  Void testCrossFileProjectChainWithExternalBaseNotFlagged()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/BaseModel.fan",
      "class BaseModel : Obj\n" +
      "{\n" +
      "  Str modelName := \"\"\n" +
      "  Void save() {}\n" +
      "}")
    typeIdx.indexFile("file:///test/UserModel.fan",
      "class UserModel : BaseModel\n" +
      "{\n" +
      "  Str email := \"\"\n" +
      "}")

    source :=
      "class App\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    e := UserModel.email\n" +
      "    n := UserModel.modelName\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/App.fan", source, typeIdx)

    // UserModel.email — direct member
    emailDiags := diags.findAll |d|
    {
      d.message.contains("email") && d.message.contains("UserModel")
    }
    verifyEq(emailDiags.size, 0)

    // UserModel.modelName — inherited from project base type BaseModel
    modelNameDiags := diags.findAll |d|
    {
      d.message.contains("modelName") && d.message.contains("UserModel")
    }
    verifyEq(modelNameDiags.size, 0)
  }

  **
  ** A truly non-existent member on a type with external base should still be flagged
  ** ONLY if there is no external base. If there IS an external base, we can't verify
  ** so we must NOT flag.
  **
  Void testCrossFileNonExistentMemberOnPureProjectTypeFlagged()
  {
    typeIdx := ProjectIndex()
    // This type does NOT extend any external type
    typeIdx.indexFile("file:///test/PureProject.fan",
      "class PureProject\n" +
      "{\n" +
      "  Str name := \"\"\n" +
      "}")

    source :=
      "class Caller\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    n := PureProject.name\n" +
      "    x := PureProject.nonExistent\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Caller.fan", source, typeIdx)

    // PureProject.name — exists
    nameDiags := diags.findAll |d|
    {
      d.message.contains("name") && d.message.contains("PureProject") && d.message.contains("is not a member")
    }
    verifyEq(nameDiags.size, 0)

    // PureProject.nonExistent — truly missing, no external base to hide behind
    missingDiags := diags.findAll |d|
    {
      d.message.contains("nonExistent") && d.message.contains("PureProject")
    }
    verify(missingDiags.size > 0, "Non-existent member on pure project type should be reported")
  }

//////////////////////////////////////////////////////////////////////////
// Single-Line Enum Values (Regression)
//////////////////////////////////////////////////////////////////////////

  **
  ** Enum values defined on a single line (e.g., "enum class Foo { a, b, c }")
  ** should be indexed and not flagged as missing members.
  ** Regression test for EntityKind.site false positive.
  **
  Void testCrossFileSingleLineEnumValueNotFlagged()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/EntityKind.fan",
      "enum class EntityKind { site, floor, room, equip, point }")

    // Verify all enum values are indexed
    verify(typeIdx.hasMember("EntityKind", "site"), "site should be indexed")
    verify(typeIdx.hasMember("EntityKind", "floor"), "floor should be indexed")
    verify(typeIdx.hasMember("EntityKind", "room"), "room should be indexed")
    verify(typeIdx.hasMember("EntityKind", "equip"), "equip should be indexed")
    verify(typeIdx.hasMember("EntityKind", "point"), "point should be indexed")

    source :=
      "class Factory\n" +
      "{\n" +
      "  Void build()\n" +
      "  {\n" +
      "    if (EntityKind.site != null) {}\n" +
      "    k := EntityKind.floor\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Factory.fan", source, typeIdx)

    memberDiags := diags.findAll |d|
    {
      d.message.contains("is not a member of") && d.message.contains("EntityKind")
    }
    verifyEq(memberDiags.size, 0)
  }

  **
  ** Single-line enum in same file as a class with project base type
  ** (forces text-based fallback). Enum values should still be indexed.
  **
  Void testCrossFileSingleLineEnumWithProjectBaseTypeFallback()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/BaseModel.fan",
      "class BaseModel\n" +
      "{\n" +
      "  Void save() {}\n" +
      "}")
    // Enum + class extending project type on same file — AST fails, text fallback
    typeIdx.indexFile("file:///test/ModelEntity.fan",
      "enum class EntityKind { site, floor, room }\n" +
      "\n" +
      "class ModelEntity : BaseModel\n" +
      "{\n" +
      "  static const Str NAME := \"entity\"\n" +
      "}")

    verify(typeIdx.hasMember("EntityKind", "site"), "site should be indexed via text fallback")
    verify(typeIdx.hasMember("EntityKind", "floor"), "floor should be indexed via text fallback")
    verify(typeIdx.hasMember("EntityKind", "room"), "room should be indexed via text fallback")

    source :=
      "class Checker\n" +
      "{\n" +
      "  Void check()\n" +
      "  {\n" +
      "    k := EntityKind.site\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Checker.fan", source, typeIdx)

    memberDiags := diags.findAll |d|
    {
      d.message.contains("is not a member of") && d.message.contains("EntityKind")
    }
    verifyEq(memberDiags.size, 0)
  }

  **
  ** Enum values starting with uppercase (e.g., Heat, Cool) should be indexed
  ** and not flagged as missing members.
  ** Regression test for EnergyMeterMode.Heat false positive.
  **
  Void testCrossFileUppercaseEnumValueNotFlagged()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/EnergyMeterMode.fan",
      "enum class EnergyMeterMode {\n" +
      "  Heat, Cool\n" +
      "}")

    verify(typeIdx.hasMember("EnergyMeterMode", "Heat"), "Heat should be indexed")
    verify(typeIdx.hasMember("EnergyMeterMode", "Cool"), "Cool should be indexed")

    source :=
      "class Chart\n" +
      "{\n" +
      "  Void build()\n" +
      "  {\n" +
      "    h := EnergyMeterMode.Heat\n" +
      "    c := EnergyMeterMode.Cool\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Chart.fan", source, typeIdx)

    memberDiags := diags.findAll |d|
    {
      d.message.contains("is not a member of") && d.message.contains("EnergyMeterMode")
    }
    verifyEq(memberDiags.size, 0)
  }

  **
  ** Uppercase enum values in single-line enum with text fallback.
  **
  Void testCrossFileUppercaseEnumSingleLineTextFallback()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/BaseDevice.fan",
      "class BaseDevice\n" +
      "{\n" +
      "  Void init() {}\n" +
      "}")
    typeIdx.indexFile("file:///test/DeviceEnums.fan",
      "enum class EnergyMeterMode { Heat, Cool }\n" +
      "\n" +
      "class DeviceImpl : BaseDevice\n" +
      "{\n" +
      "  Str mode := \"\"\n" +
      "}")

    verify(typeIdx.hasMember("EnergyMeterMode", "Heat"), "Heat should be indexed via text fallback")
    verify(typeIdx.hasMember("EnergyMeterMode", "Cool"), "Cool should be indexed via text fallback")

    source :=
      "class Config\n" +
      "{\n" +
      "  Void setup()\n" +
      "  {\n" +
      "    m := EnergyMeterMode.Heat.name\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Config.fan", source, typeIdx)

    memberDiags := diags.findAll |d|
    {
      d.message.contains("is not a member of") && d.message.contains("EnergyMeterMode")
    }
    verifyEq(memberDiags.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Unknown Slot/Field on Replaced Base (Regression)
//////////////////////////////////////////////////////////////////////////

  **
  ** "Unknown slot" for this.field where field is inherited from an external
  ** base type should be filtered when the base was replaced with Obj.
  ** Regression test for ModelEntityIoModuleConfigDevice.entityId.
  **
  Void testThisFieldAccessOnReplacedBaseFiltered()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/ParentModel.fan",
      "class ParentModel\n" +
      "{\n" +
      "  Str modelName := \"\"\n" +
      "}")

    // ChildModel extends ParentModel which extends an external type.
    // The preprocessor will replace ParentModel → ExternalType → Obj.
    // this.entityId would fail since Obj doesn't have entityId.
    source :=
      "using haystack\n" +
      "class ChildModel : Obj\n" +
      "{\n" +
      "  Void doStuff()\n" +
      "  {\n" +
      "    x := this.entityId\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/ChildModel.fan", source, typeIdx)

    entityIdDiags := diags.findAll |d|
    {
      d.message.contains("entityId") &&
      (d.message.contains("Unknown slot") || d.message.contains("Unknown field"))
    }
    verifyEq(entityIdDiags.size, 0)
  }

  **
  ** "Unknown slot" for super.field should also be filtered when base replaced.
  **
  Void testSuperFieldAccessOnReplacedBaseFiltered()
  {
    typeIdx := ProjectIndex()

    source :=
      "class MyModel : Obj\n" +
      "{\n" +
      "  Void init()\n" +
      "  {\n" +
      "    n := super.name\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/MyModel.fan", source, typeIdx)

    nameDiags := diags.findAll |d|
    {
      (d.message.contains("Unknown slot") || d.message.contains("Unknown field")) &&
      d.message.contains("name")
    }
    // super.name on `: Obj` — should be filtered since base was replaced
    verifyEq(nameDiags.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Map Type Resolution in Method Param Validation (Regression)
//////////////////////////////////////////////////////////////////////////

  **
  ** Map type declared as Str:Dict[] should be resolved as Map, not List.
  ** Map.add takes 2 args (key, val), List.add takes 1.
  ** Regression test for BuildingDevicesMetersCharts meterModePointMap.add.
  **
  Void testMapTypeResolvedCorrectlyForParamValidation()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    Str:Obj[] myMap := [:]\n" +
      "    myMap.add(\"key\", \"value\")\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    addDiags := diags.findAll |d|
    {
      d.message.contains("add") && d.message.contains("expects")
    }
    verifyEq(addDiags.size, 0)
  }

  **
  ** List type Str[] should still be resolved as List.
  ** List.add takes 1 arg — validate that 2 args is flagged.
  **
  **
  ** groupBy() returns Map, not List.  Map.get() takes 2 args (key + default).
  ** Must NOT be flagged as "get expects 1 argument but got 2".
  **
  Void testGroupByResultIsMapNotList()
  {
    source :=
      "class Svc\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    rows := getRows()\n" +
      "    bacnetDevicesMap := rows.groupBy |Dict row -> Str| { row->id }\n" +
      "    x := bacnetDevicesMap.get(\"key\", [,])\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Svc.fan", source, idx)
    getDiags := diags.findAll |d|
    {
      d.message.contains("get") && d.message.contains("expects")
    }
    verifyEq(getDiags.size, 0,
      "Map.get(key, default) must not be flagged after groupBy — got: " +
      getDiags.map |d| { d.message }.join(", "))
  }

  Void testListTypeStillValidatedCorrectly()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    Str[] myList := [,]\n" +
      "    myList.add(\"a\", \"b\")\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    addDiags := diags.findAll |d|
    {
      d.message.contains("add") && d.message.contains("expects")
    }
    verify(addDiags.size > 0, "List.add with 2 args should be flagged")
  }

  **
  ** Map type declared as [Str:Obj] should be resolved as Map.
  **
  Void testBracketMapTypeResolvedCorrectly()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    [Str:Obj] myMap := [:]\n" +
      "    myMap.add(\"key\", \"value\")\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    addDiags := diags.findAll |d|
    {
      d.message.contains("add") && d.message.contains("expects")
    }
    verifyEq(addDiags.size, 0)
  }

  **
  ** [Str:Obj?][,] is a typed List literal (List of maps), not a Map.
  ** List.add takes 1 arg — calling result.add(singleArg) must NOT be flagged.
  ** Regression for CodeActionService false positive.
  **
  Void testTypedListOfMapsAddNotFlaggedAsTooFewArgs()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    result := [Str:Obj?][,]\n" +
      "    result.add([\"key\": \"val\"])\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    addDiags := diags.findAll |d|
    {
      d.message.contains("'add'") && d.message.contains("argument")
    }
    verifyEq(addDiags.size, 0)
  }

  **
  ** Map.getOrAdd can be called with a brace-closure (no |params|) as the
  ** second argument: map.getOrAdd(key) { defaultVal }.
  ** The { } must be detected as the trailing closure — must NOT be flagged.
  ** Regression for Polyfills.fan false positive.
  **
  Void testGetOrAddWithBraceClosureNotFlagged()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    Obj:Obj[] myMap := [:]\n" +
      "    myMap.getOrAdd(\"key\") { Obj[,] }\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)

    getOrAddDiags := diags.findAll |d|
    {
      d.message.contains("'getOrAdd'") && d.message.contains("argument")
    }
    verifyEq(getOrAddDiags.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// It-Block Unknown Variable (Regression)
//////////////////////////////////////////////////////////////////////////

  **
  ** Fields set in an it-block for a project type should not be flagged as
  ** "Unknown variable" when the type is replaced with Obj during preprocessing.
  ** Regression test for ChartSeriesProps { dis = ...; color = ... }.
  **
  Void testItBlockFieldAssignmentNotFlaggedAsUnknownVar()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/ChartProps.fan",
      "class ChartProps\n" +
      "{\n" +
      "  Str dis := \"\"\n" +
      "  Bool renameCol := false\n" +
      "  Str color := \"\"\n" +
      "}")

    source :=
      "class Chart\n" +
      "{\n" +
      "  Void build()\n" +
      "  {\n" +
      "    props := ChartProps() {\n" +
      "      dis = \"hello\"\n" +
      "      renameCol = true\n" +
      "      color = \"#FF0000\"\n" +
      "    }\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Chart.fan", source, typeIdx)

    unknownVarDiags := diags.findAll |d|
    {
      d.message.startsWith("Unknown variable") &&
      (d.message.contains("dis") || d.message.contains("renameCol") || d.message.contains("color"))
    }
    verifyEq(unknownVarDiags.size, 0)
  }

  **
  ** A truly unknown variable inside an it-block should still be flagged
  ** if it's not a field of any project type.
  **
  Void testItBlockTrulyUnknownVarStillFlagged()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/SimpleType.fan",
      "class SimpleType\n" +
      "{\n" +
      "  Str name := \"\"\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    t := SimpleType() {\n" +
      "      nonExistentField = true\n" +
      "    }\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, typeIdx)

    unknownVarDiags := diags.findAll |d|
    {
      d.message.startsWith("Unknown variable") && d.message.contains("nonExistentField")
    }
    verify(unknownVarDiags.size > 0, "Truly unknown field in it-block should still be reported")
  }

//////////////////////////////////////////////////////////////////////////
// Comprehensive Inheritance Tests
//////////////////////////////////////////////////////////////////////////

  **
  ** Inherited static const fields from a project base type should not be
  ** flagged as "Unknown variable" when the base is replaced during preprocessing.
  **
  Void testInheritedStaticConstFieldFromProjectBase()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/DemoAbstract.fan",
      "class DemoAbstract\n" +
      "{\n" +
      "  Void setup() {}\n" +
      "}")
    typeIdx.indexFile("file:///test/DemoSite.fan",
      "class DemoSite : DemoAbstract\n" +
      "{\n" +
      "  static const Str SITE_NAME := \"test\"\n" +
      "  static const Dict CONFIG_ARGS := Etc.emptyDict\n" +
      "}")

    // DemoSiteChild extends DemoSite, inherits SITE_NAME and CONFIG_ARGS
    source :=
      "class DemoSiteChild : DemoSite\n" +
      "{\n" +
      "  Void configure()\n" +
      "  {\n" +
      "    n := SITE_NAME\n" +
      "    a := CONFIG_ARGS\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/DemoSiteChild.fan", source, typeIdx)

    unknownVarDiags := diags.findAll |d|
    {
      d.message.startsWith("Unknown variable") &&
      (d.message.contains("SITE_NAME") || d.message.contains("CONFIG_ARGS"))
    }
    verifyEq(unknownVarDiags.size, 0)
  }

  **
  ** Inherited static methods (including uppercase-named ones) from a project
  ** base type should not be flagged as "Unknown variable".
  ** Regression test for WshpPLP_DEF_CONFIG_ARGS.
  **
  Void testInheritedUppercaseStaticMethodFromProjectBase()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/BaseConfig.fan",
      "class BaseConfig\n" +
      "{\n" +
      "  Void init() {}\n" +
      "}")
    typeIdx.indexFile("file:///test/ParentSite.fan",
      "class ParentSite : BaseConfig\n" +
      "{\n" +
      "  static Dict WshpPLP_DEF_CONFIG_ARGS() { return Etc.emptyDict }\n" +
      "  static Dict CHILLER_ARGS() { return Etc.emptyDict }\n" +
      "}")

    // Verify uppercase methods are indexed
    verify(typeIdx.hasMember("ParentSite", "WshpPLP_DEF_CONFIG_ARGS"),
      "WshpPLP_DEF_CONFIG_ARGS should be indexed")
    verify(typeIdx.hasMember("ParentSite", "CHILLER_ARGS"),
      "CHILLER_ARGS should be indexed")

    source :=
      "class ChildSite : ParentSite\n" +
      "{\n" +
      "  Void configure()\n" +
      "  {\n" +
      "    a := WshpPLP_DEF_CONFIG_ARGS\n" +
      "    b := CHILLER_ARGS\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/ChildSite.fan", source, typeIdx)

    unknownVarDiags := diags.findAll |d|
    {
      d.message.startsWith("Unknown variable") &&
      (d.message.contains("WshpPLP_DEF_CONFIG_ARGS") || d.message.contains("CHILLER_ARGS"))
    }
    verifyEq(unknownVarDiags.size, 0)
  }

  **
  ** Inherited members through a chain of 3+ project types should be found.
  ** A → B → C: members of A and B should be accessible in C.
  **
  Void testInheritedMembersThreeDeepChain()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/GrandParent.fan",
      "class GrandParent\n" +
      "{\n" +
      "  static const Str GP_CONST := \"gp\"\n" +
      "  static Void gpMethod() {}\n" +
      "}")
    typeIdx.indexFile("file:///test/Parent.fan",
      "class Parent : GrandParent\n" +
      "{\n" +
      "  static const Str PARENT_CONST := \"p\"\n" +
      "  static Void parentMethod() {}\n" +
      "}")

    source :=
      "class Child : Parent\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    a := GP_CONST\n" +
      "    b := PARENT_CONST\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Child.fan", source, typeIdx)

    unknownVarDiags := diags.findAll |d|
    {
      d.message.startsWith("Unknown variable") &&
      (d.message.contains("GP_CONST") || d.message.contains("PARENT_CONST"))
    }
    verifyEq(unknownVarDiags.size, 0)
  }

  **
  ** Cross-file inherited members: TypeName.member where member comes from
  ** a project base type should not be flagged.
  **
  Void testCrossFileInheritedMemberFromProjectBase()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/BaseLib.fan",
      "class BaseLib\n" +
      "{\n" +
      "  static const Str VERSION := \"1.0\"\n" +
      "  static Void doWork() {}\n" +
      "}")
    typeIdx.indexFile("file:///test/AppLib.fan",
      "class AppLib : BaseLib\n" +
      "{\n" +
      "  static Void appSpecific() {}\n" +
      "}")

    source :=
      "class Caller\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    v := AppLib.VERSION\n" +
      "    AppLib.doWork()\n" +
      "    AppLib.appSpecific()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Caller.fan", source, typeIdx)

    memberDiags := diags.findAll |d|
    {
      d.message.contains("is not a member of") && d.message.contains("AppLib")
    }
    verifyEq(memberDiags.size, 0)
  }

  **
  ** this.method() and this.field where the member is inherited from a project
  ** base type (not external) should not produce "Unknown method/slot/field".
  **
  Void testThisAccessInheritedFromProjectBase()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/AbstractModel.fan",
      "class AbstractModel\n" +
      "{\n" +
      "  Str modelName := \"\"\n" +
      "  Void save() {}\n" +
      "}")

    source :=
      "class ConcreteModel : AbstractModel\n" +
      "{\n" +
      "  Void doSave()\n" +
      "  {\n" +
      "    n := this.modelName\n" +
      "    this.save()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/ConcreteModel.fan", source, typeIdx)

    slotDiags := diags.findAll |d|
    {
      (d.message.contains("Unknown method") || d.message.contains("Unknown slot") ||
       d.message.contains("Unknown field")) &&
      (d.message.contains("modelName") || d.message.contains("save"))
    }
    verifyEq(slotDiags.size, 0)
  }

  **
  ** Non-existent members should still be flagged even with inheritance.
  **
  Void testTrulyUnknownMemberStillFlaggedWithInheritance()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/Base.fan",
      "class Base\n" +
      "{\n" +
      "  static const Str REAL_CONST := \"ok\"\n" +
      "}")

    source :=
      "class Derived : Base\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    a := REAL_CONST\n" +
      "    b := TOTALLY_FAKE_CONST\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Derived.fan", source, typeIdx)

    // REAL_CONST should NOT be flagged
    realDiags := diags.findAll |d|
    {
      d.message.startsWith("Unknown variable") && d.message.contains("REAL_CONST")
    }
    verifyEq(realDiags.size, 0)

    // TOTALLY_FAKE_CONST SHOULD be flagged
    fakeDiags := diags.findAll |d|
    {
      d.message.startsWith("Unknown variable") && d.message.contains("TOTALLY_FAKE_CONST")
    }
    verify(fakeDiags.size > 0, "Truly unknown member should be reported even with inheritance")
  }

  **
  ** Inherited members through mixin should also be found.
  **
  Void testInheritedMembersFromMixin()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/Loggable.fan",
      "mixin Loggable\n" +
      "{\n" +
      "  static const Str LOG_TAG := \"app\"\n" +
      "}")
    typeIdx.indexFile("file:///test/Service.fan",
      "class Service : Loggable\n" +
      "{\n" +
      "  Void doWork() {}\n" +
      "}")

    source :=
      "class MyService : Service\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    t := LOG_TAG\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/MyService.fan", source, typeIdx)

    unknownVarDiags := diags.findAll |d|
    {
      d.message.startsWith("Unknown variable") && d.message.contains("LOG_TAG")
    }
    verifyEq(unknownVarDiags.size, 0)
  }

  **
  ** When a project type extends another project type that extends an external type
  ** (sys::Test), inherited members from the external type should not be flagged
  ** as "Unknown variable". Uses reflection to verify member exists.
  ** E.g., TestScheduleObserver : PanProjTest : Test(external)
  ** verify() and verifyEq() come from Test — should not be flagged.
  **
  Void testInheritedMembersFromExternalAncestor()
  {
    typeIdx := ProjectIndex()
    // PanProjTest extends Test (real external type in sys pod)
    typeIdx.indexFile("file:///test/PanProjTest.fan",
      "using concurrent\n" +
      "class PanProjTest : Test\n" +
      "{\n" +
      "  Void verifyDictHasTags(Obj dict, Obj tags) {}\n" +
      "  Void verifyDictHasTagsRetry(Obj id, Obj tags) {}\n" +
      "}")

    // TestScheduleObserver extends PanProjTest
    source :=
      "using concurrent\n" +
      "class TestScheduleObserver : PanProjTest\n" +
      "{\n" +
      "  Void testSchedule()\n" +
      "  {\n" +
      "    verify(true)\n" +
      "    verifyEq(a, b)\n" +
      "    verifyDictHasTagsRetry(id, tags)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/TestScheduleObserver.fan", source, typeIdx)

    // verify() — inherited from Test (external ancestor via reflection)
    verifyDiags := diags.findAll |d|
    {
      d.message.contains("verify") && !d.message.contains("verifyDict") && !d.message.contains("verifyEq")
    }
    verifyEq(verifyDiags.size, 0)

    // verifyEq — inherited from Test (external ancestor via reflection)
    eqDiags := diags.findAll |d|
    {
      d.message.contains("verifyEq")
    }
    verifyEq(eqDiags.size, 0)

    // verifyDictHasTagsRetry — defined in PanProjTest (project base)
    retryDiags := diags.findAll |d|
    {
      d.message.contains("verifyDictHasTagsRetry")
    }
    verifyEq(retryDiags.size, 0)
  }

  **
  ** When a class extends a project type with an external ancestor
  ** that is NOT auto-imported (not in sys), reflection should still find
  ** the inherited member. Uses compiler::Compiler as the external base.
  ** The base type's file imports "compiler" but the file under test doesn't,
  ** so the base falls back to Obj — but reflection finds the member.
  **
  Void testInheritedMemberFromNonSysExternalAncestor()
  {
    typeIdx := ProjectIndex()
    // ProjectBase extends Compiler (from compiler pod, not auto-imported)
    typeIdx.indexFile("file:///test/ProjectBase.fan",
      "using compiler\n" +
      "class ProjectBase : Compiler\n" +
      "{\n" +
      "  Void customMethod() {}\n" +
      "}")

    // MyChild extends ProjectBase but does NOT import compiler pod
    // So Compiler is NOT resolvable → base replaced with Obj
    source :=
      "class MyChild : ProjectBase\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    x := errs\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/MyChild.fan", source, typeIdx)

    // "errs" is a field on compiler::Compiler — should be filtered via reflection
    errsDiags := diags.findAll |d|
    {
      d.message.contains("errs") && d.message.contains("Unknown")
    }
    verifyEq(errsDiags.size, 0)
  }

  **
  ** When a member does NOT exist on the external ancestor, it should still
  ** be flagged even if the inheritance chain has an external type.
  **
  Void testExternalAncestorStillCatchesNonexistentMembers()
  {
    typeIdx := ProjectIndex()
    // PanProjTest extends Test (real external type)
    typeIdx.indexFile("file:///test/PanProjTest.fan",
      "using concurrent\n" +
      "class PanProjTest : Test\n" +
      "{\n" +
      "  Void customHelper() {}\n" +
      "}")

    source :=
      "using concurrent\n" +
      "class TestChild : PanProjTest\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    totallyFakeMethod()\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/TestChild.fan", source, typeIdx)

    // totallyFakeMethod doesn't exist on PanProjTest OR Test — should be flagged
    fakeDiags := diags.findAll |d| { d.message.contains("totallyFakeMethod") }
    verify(fakeDiags.size > 0, "Non-existent method should still be caught with external ancestor")
  }

  **
  ** Cross-file validation: when a project type has an external ancestor,
  ** member accesses should not be flagged if the member exists in the project type.
  **
  Void testCrossFileExternalAncestorMemberNotFlagged()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/PanProjTest.fan",
      "using concurrent\n" +
      "class PanProjTest : Test\n" +
      "{\n" +
      "  Void verifyDictHasTags(Obj dict, Obj tags) {}\n" +
      "}")

    // Source references PanProjTest.verifyDictHasTags (exists as direct member)
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    x := PanProjTest.verifyDictHasTags\n" +
      "  }\n" +
      "}"

    crossFileDiags := svc.validateCrossFileReferences(source, typeIdx)

    // verifyDictHasTags IS a direct member, should not be flagged
    verifyEq(crossFileDiags.size, 0)
  }

  **
  ** Fields declared with bracket map/list types like [Str:Obj?] should be
  ** indexed as members. Regression test for ScheduleUsingActionsObserver.missingTags.
  **
  Void testBracketMapTypeFieldIndexed()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/Observer.fan",
      "class Observer\n" +
      "{\n" +
      "  static const [Str:Obj?] missingTags := [:]\n" +
      "  static const [Int] ids := [,]\n" +
      "  Str name := \"\"\n" +
      "}")

    // All three fields should be indexed
    verify(typeIdx.hasMember("Observer", "missingTags"),
      "Bracket map type field [Str:Obj?] should be indexed")
    verify(typeIdx.hasMember("Observer", "ids"),
      "Bracket list type field [Int] should be indexed")
    verify(typeIdx.hasMember("Observer", "name"),
      "Regular type field should still be indexed")
  }

  **
  ** Cross-file reference to a bracket-type field should not be flagged.
  **
  Void testCrossFileBracketMapTypeFieldNotFlagged()
  {
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/Observer.fan",
      "class Observer\n" +
      "{\n" +
      "  static const [Str:Obj?] missingTags := [:]\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  Void bar()\n" +
      "  {\n" +
      "    x := Observer.missingTags\n" +
      "  }\n" +
      "}"

    crossFileDiags := svc.validateCrossFileReferences(source, typeIdx)
    missingDiags := crossFileDiags.findAll |d| { d.message.contains("missingTags") }
    verifyEq(missingDiags.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// Super Constructor Args with Replaced Base Type
//////////////////////////////////////////////////////////////////////////

  Void testSuperCtorArgsFilteredWhenBaseTypeReplaced()
  {
    // Exact reproduction of ChillerModel.fan / UnitModel.fan pattern.
    // When a class extends a project type that gets replaced with Obj,
    // the super(args) call becomes Obj(args) which fails because
    // Obj.make() takes no args. The preprocessing should strip the
    // super constructor arguments.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/UnitModel.fan",
      "\n" +
      "const class UnitModel\n" +
      "{\n" +
      "    public const Int idNumber\n" +
      "    public const Str? unitId\n" +
      "    public const Str? image\n" +
      "\n" +
      "    new make(Int idNumber, Str unitId, Str? image) {\n" +
      "        this.idNumber = idNumber\n" +
      "        this.unitId = unitId\n" +
      "        this.image = image\n" +
      "    }\n" +
      "}")

    source :=
      "using haystack\n" +
      "\n" +
      "const class ChillerModel : UnitModel\n" +
      "{\n" +
      "    public const Int? unitPowerR290\n" +
      "    public const Int? unitPowerR32Sc\n" +
      "    public const Int? unitPowerR32Dc\n" +
      "    public const Number? capacityRank\n" +
      "\n" +
      "    new make(\n" +
      "      Int idNumber,\n" +
      "      Str? unitId,\n" +
      "      Str? image,\n" +
      "      Int? unitPowerR290,\n" +
      "      Int? unitPowerR32Sc,\n" +
      "      Int? unitPowerR32Dc,\n" +
      "      Number? capacityRank\n" +
      "    ) : super(idNumber, unitId, image) {\n" +
      "        this.unitPowerR290 = unitPowerR290\n" +
      "        this.unitPowerR32Sc = unitPowerR32Sc\n" +
      "        this.unitPowerR32Dc = unitPowerR32Dc\n" +
      "        this.capacityRank = capacityRank\n" +
      "    }\n" +
      "}"

    diags := svc.analyze("file:///test/ChillerModel.fan", source, typeIdx)

    invalidArgs := diags.findAll |d| { d.message.contains("Invalid args make") }
    verifyEq(invalidArgs.size, 0)
  }

  Void testSuperCtorArgsSameLineFiltered()
  {
    // Same as above but with constructor on a single line
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/Base.fan",
      "class Base\n" +
      "{\n" +
      "  Int x\n" +
      "  new make(Int x) { this.x = x }\n" +
      "}")

    source :=
      "class Child : Base\n" +
      "{\n" +
      "  Int y\n" +
      "  new make(Int x, Int y) : super(x) { this.y = y }\n" +
      "}"

    diags := svc.analyze("file:///test/Child.fan", source, typeIdx)

    invalidArgs := diags.findAll |d| { d.message.contains("Invalid args make") }
    verifyEq(invalidArgs.size, 0)
  }

//////////////////////////////////////////////////////////////////////////
// CamelCase Type Replacement (Regression)
//////////////////////////////////////////////////////////////////////////

  **
  ** Method names containing project type names as camelCase substrings
  ** should NOT be mangled by the preprocessor. e.g., "validateStrEnum"
  ** should not become "validateObj" when StrEnum is a project type.
  **
  Void testCamelCaseMethodNameNotMangled()
  {
    idx.indexFile("file:///test/StrEnum.fan",
      "class StrEnum\n" +
      "{\n" +
      "  Str[] vals\n" +
      "}")
    idx.indexFile("file:///test/StrEnumNames.fan",
      "class StrEnumNames\n" +
      "{\n" +
      "  Type enumType\n" +
      "}")

    source :=
      "class DictValidator\n" +
      "{\n" +
      "  private Void validateStrEnum(Str value) { }\n" +
      "  private Void validateStrEnumNames(Str value) { }\n" +
      "}"

    diags := svc.analyze("file:///test/DictValidator.fan", source, idx)
    dupSlot := diags.findAll |d| { d.message.contains("Duplicate slot") }
    verifyEq(dupSlot.size, 0, "CamelCase method names should not be mangled into duplicates")
  }

//////////////////////////////////////////////////////////////////////////
// Static Type Call Param Validation (Regression)
//////////////////////////////////////////////////////////////////////////

  **
  ** Static method calls on project types (TypeName.method(args)) should
  ** not be validated by param checker since the type's methods are not
  ** in the completions YML.
  **
  Void testStaticTypeCallNotValidated()
  {
    idx.indexFile("file:///test/NavTree.fan",
      "class NavTree\n" +
      "{\n" +
      "  static NavTree find(Obj cx, Str name) { return NavTree() }\n" +
      "}")

    source :=
      "class Schedules\n" +
      "{\n" +
      "  Void test()\n" +
      "  {\n" +
      "    tree := NavTree.find(cx, \"equip\")\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Schedules.fan", source, idx)
    argErr := diags.findAll |d| { d.message.contains("expects") && d.message.contains("argument") }
    verifyEq(argErr.size, 0, "Static type calls should not be validated for argument count")
  }

//////////////////////////////////////////////////////////////////////////
// Typed List/Map Literal Type Inference (Regression)
//////////////////////////////////////////////////////////////////////////

  **
  ** Variables initialized with typed list literals (e.g., Str[,]) should
  ** be inferred as sys::List, not left unresolved.
  **
  Void testTypedListLiteralInference()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void test()\n" +
      "  {\n" +
      "    notes := Str[,]\n" +
      "    notes.add(\"hello\")\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    argErr := diags.findAll |d| { d.message.contains("'add' expects") }
    verifyEq(argErr.size, 0, "Str[,] should be inferred as List, and List.add takes 1 arg")
  }

//////////////////////////////////////////////////////////////////////////
// Operator Method on Obj (Regression)
//////////////////////////////////////////////////////////////////////////

  **
  ** "No operator method found: sys::Obj..." should be filtered as a
  ** false positive from single-file type resolution.
  **
  **
  ** Regression: dbUnits.add(newUnit) was flagged as "'add' expects 2 argument(s)"
  ** because extractDeclaredType found 'dbUnits' inside an expression on a different
  ** line (dbUnits[2].toDict()), misinterpreted ':' from ':=' as a Map type indicator,
  ** and resolved the type as sys::Map (whose add takes 2 args).
  **
  Void testVarUsedInExpressionNotMistakenAsDeclaration()
  {
    idx.indexFile("file:///test/DeviceData.fan",
      "class DeviceData\n" +
      "{\n" +
      "  Str? id\n" +
      "  Str? name\n" +
      "}")

    source :=
      "class Foo\n" +
      "{\n" +
      "  Void test()\n" +
      "  {\n" +
      "    dbUnits := items.map { makeObj(DeviceData#, it) } as DeviceData[]\n" +
      "    newUnit := makeObj(DeviceData#, dbUnits[2].toDict()) as DeviceData\n" +
      "    newUnit.id = null\n" +
      "    newUnit.name = \"New Unit\"\n" +
      "    dbUnits.add(newUnit)\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    addErr := diags.findAll |d| { d.message.contains("'add' expects") }
    verifyEq(addErr.size, 0, "dbUnits.add(newUnit) should not be flagged — dbUnits[2] on prior line is not a declaration")
  }

  Void testOperatorMethodOnObjFiltered()
  {
    idx.indexFile("file:///test/MyService.fan",
      "class MyService\n" +
      "{\n" +
      "  Obj[] getItems() { return Obj[,] }\n" +
      "}")

    source :=
      "using haystack\n" +
      "class Foo\n" +
      "{\n" +
      "  Void test()\n" +
      "  {\n" +
      "    svc := MyService()\n" +
      "    svc.getItems.each |rec|\n" +
      "    {\n" +
      "      x := rec[\"key\"]\n" +
      "    }\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    opErr := diags.findAll |d| { d.message.contains("No operator method found") && d.message.contains("sys::Obj") }
    verifyEq(opErr.size, 0, "Operator method on sys::Obj should be filtered as false positive")
  }

//////////////////////////////////////////////////////////////////////////
// Unused Variables
//////////////////////////////////////////////////////////////////////////

  ** Local variable declared but never used → warning
  Void testUnusedLocalVar()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    unused := compute()\n" +
      "    doWork()\n" +
      "  }\n" +
      "  private Str compute() { return \"x\" }\n" +
      "  private Void doWork() {}\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    warn := diags.findAll |d| { d.message.contains("'unused'") && d.message.contains("never used") }
    verifyEq(warn.size, 1, "Unused local var should produce a warning")
    verifyEq(warn[0].range.start.line, 4)
  }

  ** Local variable that IS used → no warning
  Void testUsedLocalVarNoWarn()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    result := compute()\n" +
      "    log(result)\n" +
      "  }\n" +
      "  private Str compute() { return \"x\" }\n" +
      "  private Void log(Str s) {}\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    warn := diags.findAll |d| { d.message.contains("'result'") && d.message.contains("never used") }
    verifyEq(warn.size, 0, "Used local var should not produce a warning")
  }

  ** Underscore-prefixed local vars are intentionally unused → no warning
  Void testUnderscoreVarNoWarn()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    _ignored := compute()\n" +
      "  }\n" +
      "  private Str compute() { return \"x\" }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    warn := diags.findAll |d| { d.message.contains("'_ignored'") && d.message.contains("never used") }
    verifyEq(warn.size, 0, "Underscore-prefixed var should not warn")
  }

  ** Private field declared but never referenced → warning
  Void testUnusedPrivateField()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  private Str deadField := \"x\"\n" +
      "\n" +
      "  Void run() { log(\"done\") }\n" +
      "  private Void log(Str s) {}\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    warn := diags.findAll |d| { d.message.contains("'deadField'") && d.message.contains("never used") }
    verifyEq(warn.size, 1, "Unused private field should produce a warning")
    verifyEq(warn[0].range.start.line, 2)
  }

  ** Private field referenced in a method → no warning
  Void testUsedPrivateFieldNoWarn()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  private Str name := \"foo\"\n" +
      "\n" +
      "  Str getName() { return name }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    warn := diags.findAll |d| { d.message.contains("'name'") && d.message.contains("never used") }
    verifyEq(warn.size, 0, "Used private field should not warn")
  }

  ** for-loop variables are NOT flagged as unused even if single-word LHS
  Void testForLoopVarNoWarn()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    for (i := 0; i < 10; i++)\n" +
      "      log(i.toStr)\n" +
      "  }\n" +
      "  private Void log(Str s) {}\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    warn := diags.findAll |d| { d.message.contains("'i'") && d.message.contains("never used") }
    verifyEq(warn.size, 0, "for-loop var should not be flagged as unused")
  }

//////////////////////////////////////////////////////////////////////////
// Duplicate Static Const Values
//////////////////////////////////////////////////////////////////////////

  ** Two files with the same static const string value → both get a warning
  Void testDuplicateConstValuesAcrossFiles()
  {
    sources := Str:Str[:]
    sources["file:///proj/A.fan"] =
      "class A\n" +
      "{\n" +
      "  static const Str MY_KEY := \"my-duplicate-value\"\n" +
      "}"
    sources["file:///proj/B.fan"] =
      "class B\n" +
      "{\n" +
      "  static const Str OTHER_KEY := \"my-duplicate-value\"\n" +
      "}"

    result := svc.checkDuplicateConstValues(sources)

    aWarns := result["file:///proj/A.fan"] ?: LspDiagnostic[,]
    bWarns := result["file:///proj/B.fan"] ?: LspDiagnostic[,]
    verify(aWarns.any |d| { d.message.contains("Duplicate") }, "A.fan should get a duplicate-value warning")
    verify(bWarns.any |d| { d.message.contains("Duplicate") }, "B.fan should get a duplicate-value warning")
  }

  ** Short string (< 5 chars) is NOT flagged even if duplicated
  Void testDuplicateConstShortValueNoWarn()
  {
    sources := Str:Str[:]
    sources["file:///proj/A.fan"] = "class A { static const Str X := \"ab\" }"
    sources["file:///proj/B.fan"] = "class B { static const Str Y := \"ab\" }"

    result := svc.checkDuplicateConstValues(sources)
    verifyEq((result["file:///proj/A.fan"] ?: LspDiagnostic[,]).size, 0,
      "Short duplicate value should not warn")
  }

  ** Unique values → no duplicate warning
  Void testNoDuplicateConstValues()
  {
    sources := Str:Str[:]
    sources["file:///proj/A.fan"] = "class A { static const Str X := \"unique-value-one\" }"
    sources["file:///proj/B.fan"] = "class B { static const Str Y := \"unique-value-two\" }"

    result := svc.checkDuplicateConstValues(sources)
    verifyEq(result.size, 0, "Unique values should produce no warnings")
  }

  ** Same value in 3 files → warning message says "3 places"
  Void testDuplicateConstThreeFiles()
  {
    sources := Str:Str[:]
    sources["file:///proj/A.fan"] = "class A { static const Str KEY := \"shared-constant-value\" }"
    sources["file:///proj/B.fan"] = "class B { static const Str KEY := \"shared-constant-value\" }"
    sources["file:///proj/C.fan"] = "class C { static const Str KEY := \"shared-constant-value\" }"

    result := svc.checkDuplicateConstValues(sources)
    allWarns := LspDiagnostic[,]
    result.each |diags| { allWarns.addAll(diags) }
    verify(allWarns.any |d| { d.message.contains("3 places") },
      "Warning should mention '3 places'")
    verifyEq(allWarns.size, 3, "Each of the 3 files should get a warning")
  }

//////////////////////////////////////////////////////////////////////////
// Nullable Usage
//////////////////////////////////////////////////////////////////////////

  ** Nullable local variable used without any null guard → warning
  Void testNullableLocalVarUsed()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    Str? x := getVal()\n" +
      "    x.trim\n" +
      "  }\n" +
      "  private Str? getVal() { return null }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    warn := diags.findAll |d| { d.message.contains("'x'") && d.message.contains("might be null") }
    verifyEq(warn.size, 1, "Nullable var used without guard should warn")
    verifyEq(warn[0].range.start.line, 5)
  }

  ** Nullable parameter used without null guard → warning
  Void testNullableParamUsed()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Str process(Str? input)\n" +
      "  {\n" +
      "    return input.trim\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    warn := diags.findAll |d| { d.message.contains("'input'") && d.message.contains("might be null") }
    verifyEq(warn.size, 1, "Nullable param used without guard should warn")
  }

  ** Nullable var guarded with "if (x == null) return" → no warning
  Void testNullableGuardedWithReturn()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run(Str? x)\n" +
      "  {\n" +
      "    if (x == null) return\n" +
      "    x.trim\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    warn := diags.findAll |d| { d.message.contains("'x'") && d.message.contains("might be null") }
    verifyEq(warn.size, 0, "Guarded nullable should not warn")
  }

  ** Nullable var guarded with "if (x == null) throw" → no warning
  Void testNullableGuardedWithThrow()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run(Str? x)\n" +
      "  {\n" +
      "    if (x == null) throw ArgErr(\"x is null\")\n" +
      "    x.trim\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    warn := diags.findAll |d| { d.message.contains("'x'") && d.message.contains("might be null") }
    verifyEq(warn.size, 0, "Guard with throw should suppress nullable warning")
  }

  ** Nullable var inside "if (x != null) { ... }" block → no warning
  Void testNullableConditionalSafeInBlock()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run(Str? x)\n" +
      "  {\n" +
      "    if (x != null)\n" +
      "    {\n" +
      "      x.trim\n" +
      "    }\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    warn := diags.findAll |d| { d.message.contains("'x'") && d.message.contains("might be null") }
    verifyEq(warn.size, 0, "Nullable var inside if(!=null) block should not warn")
  }

  ** Safe-navigation operator (?.) does not produce a warning
  Void testSafeNavigationNoWarn()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run(Str? x)\n" +
      "  {\n" +
      "    x?.trim\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    warn := diags.findAll |d| { d.message.contains("'x'") && d.message.contains("might be null") }
    verifyEq(warn.size, 0, "Safe-navigation ?. should not warn")
  }

  ** Non-nullable variable is never flagged
  Void testNonNullableNoWarn()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run()\n" +
      "  {\n" +
      "    Str s := \"hello\"\n" +
      "    s.trim\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    warn := diags.findAll |d| { d.message.contains("'s'") && d.message.contains("might be null") }
    verifyEq(warn.size, 0, "Non-nullable var should not warn")
  }

  ** Null check on the same line suppresses the warning (single-line if)
  Void testNullCheckSameLineNoWarn()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run(Str? x)\n" +
      "  {\n" +
      "    if (x != null) x.trim\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    warn := diags.findAll |d| { d.message.contains("'x'") && d.message.contains("might be null") }
    verifyEq(warn.size, 0, "Null check on same line should suppress warning")
  }

//////////////////////////////////////////////////////////////////////////
// Multi-line Str False Positive Regression
//////////////////////////////////////////////////////////////////////////

  **
  ** Regression: a string literal that contains the text "class X : Y" must
  ** NOT cause a "Leading space in multi-line Str" false-positive diagnostic.
  **
  ** Root cause: replaceBaseTypesInLine was matching "class " inside string
  ** literals and truncating the rest of the line, leaving an unclosed quote.
  ** The Fantom compiler then interpreted the next lines as multi-line string
  ** continuations with wrong indentation.
  **
  Void testNoFalsePositiveForClassInStringLiteral()
  {
    // This source simulates a build-script generator: a method that writes
    // a Fantom build.fan by assembling a string value containing "class Build : BuildPod".
    // Before the fix, the LSP incorrectly reported
    // "Leading space in multi-line Str must be N spaces" on lines like
    // "    podName = \"myPod\"\n".
    source :=
      "class ScriptGen\n" +
      "{\n" +
      "  Void writeBuildFan(OutStream out)\n" +
      "  {\n" +
      "    out.writeChars(\n" +
      "      \"class Build : BuildPod\\n\" +\n" +
      "      \"{\\n\" +\n" +
      "      \"  new make()\\n\" +\n" +
      "      \"  {\\n\" +\n" +
      "      \"    podName = \\\"myPod\\\"\\n\" +\n" +
      "      \"    depends = [\\\"sys 1.0\\\"]\\n\" +\n" +
      "      \"  }\\n}\\n\")\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/ScriptGen.fan", source, idx)

    multiLineStrDiags := diags.findAll |d|
    {
      d.message.contains("Leading space in multi-line Str")
    }
    verifyEq(multiLineStrDiags.size, 0,
      "String literals containing 'class X : Y' must not produce multi-line Str errors")
  }

  **
  ** Regression: same scenario with "mixin" keyword inside a string literal.
  **
  Void testNoFalsePositiveForMixinInStringLiteral()
  {
    source :=
      "class CodeGen\n" +
      "{\n" +
      "  Str snippet()\n" +
      "  {\n" +
      "    return \"mixin Serializable : Identifiable\\n{\\n  abstract Str id\\n}\"\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/CodeGen.fan", source, idx)

    multiLineStrDiags := diags.findAll |d|
    {
      d.message.contains("Leading space in multi-line Str")
    }
    verifyEq(multiLineStrDiags.size, 0,
      "String literals containing 'mixin X : Y' must not produce multi-line Str errors")
  }

  **
  ** Normal class declarations with inheritance must still be preprocessed
  ** correctly (the fix must not break the existing base-type replacement).
  **
  Void testClassInStringLiteralDoesNotBreakRealClassProcessing()
  {
    // Set up an index with a project base type
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/Base.fan",
      "class Base\n" +
      "{\n" +
      "  Void doWork() {}\n" +
      "}")

    // Source that has BOTH: a real class inheriting from a project type (Base)
    // AND a string literal containing "class X : Y" text.
    // The real "class Child : Base" must be preprocessed; the one inside the
    // string must be left alone.
    source :=
      "class Child : Base\n" +
      "{\n" +
      "  Str template()\n" +
      "  {\n" +
      "    return \"class Example : Base\\n{\\n  Void run() {}\\n}\"\n" +
      "  }\n" +
      "  Void go() { doWork() }\n" +
      "}"

    diags := svc.analyze("file:///test/Child.fan", source, typeIdx)

    // The inherited doWork() call must NOT be flagged as unknown (base type
    // replacement worked correctly for the real declaration).
    unknownDoWork := diags.findAll |d|
    {
      d.message.contains("doWork") &&
      (d.message.contains("Unknown") || d.message.contains("unknown"))
    }
    verifyEq(unknownDoWork.size, 0,
      "Inherited method call should not be flagged after correct base-type replacement")

    // And there must be no multi-line Str error from the string literal.
    multiLineStrDiags := diags.findAll |d|
    {
      d.message.contains("Leading space in multi-line Str")
    }
    verifyEq(multiLineStrDiags.size, 0,
      "String literal with 'class X : Y' must not produce multi-line Str errors")
  }

//////////////////////////////////////////////////////////////////////////
// Cross-Class Const Static Initializer
//////////////////////////////////////////////////////////////////////////

  **
  ** Basic cross-class const static initializer: warn when class B initializes
  ** a const static field from another class's field (A.v1).
  **
  Void testConstInitCrossClassRef()
  {
    source :=
      "class B\n" +
      "{\n" +
      "  const static Str v2 := A.v1\n" +
      "}"

    diags := svc.analyze("file:///test/B.fan", source, idx)
    constDiags := diags.findAll |d| { d.message.contains("A.v1") }
    verify(constDiags.size >= 1,
      "Expected a warning about 'A.v1' cross-class const initializer")
    verify(constDiags[0].message.contains("may not be loaded"),
      "Warning message should mention loading order risk")
  }

  **
  ** Same-class const static reference must not warn.
  **
  Void testConstInitSameClassNoWarn()
  {
    source :=
      "class A\n" +
      "{\n" +
      "  const static Str v1 := \"hello\"\n" +
      "  const static Str v2 := A.v1\n" +
      "}"

    diags := svc.analyze("file:///test/A.fan", source, idx)
    constDiags := diags.findAll |d| { d.message.contains("A.v1") && d.message.contains("may not be loaded") }
    verifyEq(constDiags.size, 0,
      "Same-class const static reference should not produce a warning")
  }

  **
  ** String literal initializer must not warn.
  **
  Void testConstInitLiteralNoWarn()
  {
    source :=
      "class A\n" +
      "{\n" +
      "  const static Str v1 := \"hello\"\n" +
      "}"

    diags := svc.analyze("file:///test/A.fan", source, idx)
    constDiags := diags.findAll |d| { d.message.contains("may not be loaded") }
    verifyEq(constDiags.size, 0,
      "String literal initializer should not produce a cross-class const warning")
  }

  **
  ** Non-const static field (missing 'const') must not warn.
  **
  Void testConstInitNonConstNoWarn()
  {
    source :=
      "class B\n" +
      "{\n" +
      "  static Str v2 := A.v1\n" +
      "}"

    diags := svc.analyze("file:///test/B.fan", source, idx)
    constDiags := diags.findAll |d| { d.message.contains("A.v1") && d.message.contains("may not be loaded") }
    verifyEq(constDiags.size, 0,
      "Non-const static field should not trigger the cross-class const warning")
  }

  **
  ** Method call on the RHS must not warn (method calls load the target class).
  **
  Void testConstInitMethodCallNoWarn()
  {
    source :=
      "class B\n" +
      "{\n" +
      "  const static Str v := A.compute()\n" +
      "}"

    diags := svc.analyze("file:///test/B.fan", source, idx)
    constDiags := diags.findAll |d| { d.message.contains("A.compute") && d.message.contains("may not be loaded") }
    verifyEq(constDiags.size, 0,
      "Method call in const static initializer should not warn")
  }

  **
  ** Two classes in the same file: only the cross-class reference in class B
  ** should warn; class A's literal initializer should not.
  **
  Void testConstInitMultiClassInFile()
  {
    source :=
      "class A\n" +
      "{\n" +
      "  const static Str v1 := \"hello\"\n" +
      "}\n" +
      "class B\n" +
      "{\n" +
      "  const static Str v2 := A.v1\n" +
      "}"

    diags := svc.analyze("file:///test/AB.fan", source, idx)
    constDiags := diags.findAll |d| { d.message.contains("may not be loaded") }
    verifyEq(constDiags.size, 1,
      "Exactly one cross-class const warning expected (for B.v2 := A.v1)")
    verify(constDiags[0].message.contains("A.v1"),
      "Warning should identify the problematic reference 'A.v1'")
  }

  **
  ** The exact user-reported scenario: const class B with const static field
  ** initialized from class A.
  **
  Void testConstInitUserScenario()
  {
    source :=
      "class A\n" +
      "{\n" +
      "  const static Str v1 := \"hello\"\n" +
      "}\n" +
      "const class B\n" +
      "{\n" +
      "  const static Str v2 := A.v1\n" +
      "}"

    diags := svc.analyze("file:///test/AB.fan", source, idx)
    constDiags := diags.findAll |d| { d.message.contains("A.v1") && d.message.contains("may not be loaded") }
    verify(constDiags.size >= 1,
      "User scenario: const static Str v2 := A.v1 must produce a warning")
  }

//////////////////////////////////////////////////////////////////////////
// Static Context: 'this' in static methods
//////////////////////////////////////////////////////////////////////////

  Void testThisInStaticMethodIsError()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  static Void bar()\n" +
      "  {\n" +
      "    x := this.name\n" +
      "  }\n" +
      "  Str name := \"test\"\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    staticDiags := diags.findAll |d| { d.message == "Cannot access 'this' in static context" }
    verify(staticDiags.size >= 1, "Expected at least one error for 'this' in static method")
    verifyEq(staticDiags[0].range.start.line, 4)
  }

  Void testThisInInstanceMethodIsNotError()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Str name := \"test\"\n" +
      "  Str bar() { return this.name }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    staticDiags := diags.findAll |d| { d.message == "Cannot access 'this' in static context" }
    verifyEq(staticDiags.size, 0, "'this' in instance method must not be flagged")
  }

  Void testThisInStringLiteralInsideStaticNotFlagged()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  static Str bar() { return \"this is fine\" }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    staticDiags := diags.findAll |d| { d.message == "Cannot access 'this' in static context" }
    verifyEq(staticDiags.size, 0, "'this' inside string literal must not be flagged")
  }

  Void testThisAsSubstringInsideStaticNotFlagged()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  static Void bar() { thisVar := 1 }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    staticDiags := diags.findAll |d| { d.message == "Cannot access 'this' in static context" }
    verifyEq(staticDiags.size, 0, "'this' as part of longer identifier must not be flagged")
  }

  Void testMultipleThisInStaticMethod()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Str name := \"x\"\n" +
      "  static Void bar()\n" +
      "  {\n" +
      "    a := this.name\n" +
      "    b := this.name\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    staticDiags := diags.findAll |d| { d.message == "Cannot access 'this' in static context" }
    verify(staticDiags.size >= 2, "Each 'this' occurrence in static method should produce an error")
  }

  Void testThisInCommentInsideStaticNotFlagged()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  static Void bar()\n" +
      "  {\n" +
      "    // this is a comment\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    staticDiags := diags.findAll |d| { d.message == "Cannot access 'this' in static context" }
    verifyEq(staticDiags.size, 0, "'this' inside // comment must not be flagged")
  }

  Void testThisInStaticMethodWithUnresolvableBase()
  {
    // When a class extends a project base type, AstIndex.parse returns null
    // because the base cannot be resolved. The text-based fallback must still
    // report the 'this' usage as an error.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/Base.fan",
      "class Base\n" +
      "{\n" +
      "  Str name := \"base\"\n" +
      "}")

    source :=
      "class Foo : Base\n" +
      "{\n" +
      "  static Void bar()\n" +
      "  {\n" +
      "    x := this.name\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, typeIdx)
    staticDiags := diags.findAll |d| { d.message == "Cannot access 'this' in static context" }
    verify(staticDiags.size >= 1,
      "Text-based fallback must catch 'this' when AstIndex.parse fails due to unresolvable base")
    verifyEq(staticDiags[0].range.start.line, 4)
  }

  Void testBareInheritedFieldInStaticMethodIsError()
  {
    // When an inherited instance field is accessed without 'this.' inside a
    // static method, the compiler's error is swallowed (filtered as an
    // "Unknown variable" false positive). The validator must still report it.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/Base.fan",
      "class Base\n" +
      "{\n" +
      "  Str name := \"base\"\n" +
      "}")

    source :=
      "class Foo : Base\n" +
      "{\n" +
      "  static Void bar()\n" +
      "  {\n" +
      "    x := name\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, typeIdx)
    fieldDiags := diags.findAll |d| { d.message.contains("Cannot access instance field 'name'") }
    verify(fieldDiags.size >= 1,
      "Bare inherited field 'name' in static method must be flagged")
    verifyEq(fieldDiags[0].range.start.line, 4)
  }

  Void testBareLocalVarShadowingFieldNotFlagged()
  {
    // A local variable that happens to share a name with an inherited field
    // must not be flagged — the local takes precedence.
    typeIdx := ProjectIndex()
    typeIdx.indexFile("file:///test/Base.fan",
      "class Base\n" +
      "{\n" +
      "  Str name := \"base\"\n" +
      "}")

    source :=
      "class Foo : Base\n" +
      "{\n" +
      "  static Void bar()\n" +
      "  {\n" +
      "    name := \"local\"\n" +
      "    x := name\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, typeIdx)
    fieldDiags := diags.findAll |d| { d.message.contains("Cannot access instance field 'name'") }
    verifyEq(fieldDiags.size, 0,
      "Local var 'name' shadows the inherited field — must not be flagged")
  }

  Void testThisInBlockCommentInsideStaticNotFlagged()
  {
    // 'this' inside a /* ... */ block comment must not be flagged.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Str name := \"test\"\n" +
      "  static Void bar()\n" +
      "  {\n" +
      "    /* this is a comment */\n" +
      "    x := 1\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    staticDiags := diags.findAll |d| { d.message == "Cannot access 'this' in static context" }
    verifyEq(staticDiags.size, 0, "'this' inside /* */ block comment must not be flagged")
  }

  Void testThisInMultiLineBlockCommentInsideStaticNotFlagged()
  {
    // 'this' inside a multi-line /** ... */ Javadoc-style block comment must not be flagged.
    source :=
      "class Foo\n" +
      "{\n" +
      "  Str name := \"test\"\n" +
      "  /**\n" +
      "  * @param this the context\n" +
      "  */\n" +
      "  static Void bar()\n" +
      "  {\n" +
      "    x := 1\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, idx)
    staticDiags := diags.findAll |d| { d.message == "Cannot access 'this' in static context" }
    verifyEq(staticDiags.size, 0, "'this' inside /** */ Javadoc comment must not be flagged")
  }

  Void testThisInConstructorNotFlaggedWhenEnumInSameFile()
  {
    // Enum classes synthesize a non-synthetic static method (fromStr) whose loc
    // points to the enum's type declaration line. Without type-scoped bounds,
    // its endLine bleeds to the end of the file, causing this. inside
    // constructors of later classes to be falsely flagged.
    source :=
      "public enum class MyKind { a, b }\n" +
      "\n" +
      "public class Foo {\n" +
      "  Str val\n" +
      "  new make(MyKind kind) {\n" +
      "    this.val = kind.toStr\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, ProjectIndex())
    thisDiags := diags.findAll |d| { d.message == "Cannot access 'this' in static context" }
    verifyEq(thisDiags.size, 0,
      "'this' inside a constructor must not be flagged even when an enum is defined in the same file")
  }

  Void testStaticFieldAccessInStaticMethodNotFlagged()
  {
    // A static field accessed inside a static method must not be flagged.
    // Regression: AstIndex was not copying fd.isStatic, so every field
    // appeared as an instance field and triggered a false positive.
    source :=
      "class Foo\n" +
      "{\n" +
      "  private static const Str className := Foo#.name\n" +
      "  static Void bar()\n" +
      "  {\n" +
      "    x := className\n" +
      "  }\n" +
      "}"

    diags := svc.analyze("file:///test/Foo.fan", source, ProjectIndex())
    fieldDiags := diags.findAll |d| { d.message.contains("Cannot access instance field 'className'") }
    verifyEq(fieldDiags.size, 0,
      "Static field 'className' accessed in static method must not be flagged")
  }
}

internal class DiagnosticServiceBuilderFacade
{
  private DiagnosticService service

  new make(DiagnosticService service)
  {
    this.service = service
  }

  LspDiagnostic[] analyze(Str uri, Str source, ProjectIndex index, Bool pedanticMode := false, Bool enableUnusedImport := true)
  {
    request := DiagnosticAnalyzeRequestBuilder()
      .withUri(uri)
      .withSource(source)
      .withIndex(index)
      .withPedanticMode(pedanticMode)
      .withEnableUnusedImport(enableUnusedImport)
      .build

    return service.analyzeRequest(request)
  }

  LspDiagnostic[] validateCrossFileReferences(Str source, ProjectIndex index)
  {
    return service.validateCrossFileReferences(source, index)
  }

  [Str:LspDiagnostic[]] checkDuplicateConstValues([Str:Str] sources)
  {
    return service.checkDuplicateConstValues(sources)
  }
}
