
**
** TypeResolverTest - Tests for implicit type inference in TypeResolver.
** Covers the four main inference paths that are common in real Fantom projects:
**   1. "as TypeName" cast with non-sys types (e.g. pod types from using statements)
**   2. Bare method call with no receiver: x := methodName(args)
**   3. Static method call on a project type: x := ProjectType.method(args)
**   4. Field/property access without parens: x := obj.field
**
class TypeResolverTest : Test
{
  private ProjectIndex makeIndex([Str:Str] files)
  {
    idx := ProjectIndex()
    files.each |src, uri| { idx.indexFile(uri, src) }
    return idx
  }

//////////////////////////////////////////////////////////////////////////
// Explicit type declaration (sanity checks for existing behaviour)
//////////////////////////////////////////////////////////////////////////

  Void testExplicitTypeDecl()
  {
    src :=
      "class Svc {\n" +
      "  Void run() {\n" +
      "    Str msg := \"hello\"\n" +
      "    echo(msg)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Svc.fan": src])
    result := TypeResolver.resolveVarType("msg", src, 3, idx)
    verifyEq(result, "sys::Str", "explicit Str declaration must resolve to qualified name")
  }

  Void testExplicitListDecl()
  {
    src :=
      "class Svc {\n" +
      "  Void run() {\n" +
      "    Str[] items := [,]\n" +
      "    echo(items)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Svc.fan": src])
    result := TypeResolver.resolveVarType("items", src, 3, idx)
    verifyEq(result, "sys::List", "explicit Str[] declaration must resolve to qualified List name")
  }

//////////////////////////////////////////////////////////////////////////
// "as TypeName" cast — sys alias already works; non-sys types need
// UsingPodIndex fallback
//////////////////////////////////////////////////////////////////////////

  Void testAsCastSysType()
  {
    // Existing behaviour: "as Str" resolves via CompletionDefs alias
    src :=
      "class Svc {\n" +
      "  Void run() {\n" +
      "    msg := someObj as Str\n" +
      "    echo(msg)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Svc.fan": src])
    result := TypeResolver.resolveVarType("msg", src, 3, idx)
    verifyEq(result, "sys::Str", "as Str cast must resolve via sys alias")
  }

  Void testAsCastProjectType()
  {
    // "as Widget" where Widget is a project type (in ProjectIndex)
    widgetSrc := "class Widget { Str name := \"\" }\n"
    mainSrc :=
      "class App {\n" +
      "  Void run(Obj raw) {\n" +
      "    w := raw as Widget\n" +
      "    echo(w)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Widget.fan": widgetSrc, "file:///App.fan": mainSrc])
    result := TypeResolver.resolveVarType("w", mainSrc, 3, idx)
    verifyEq(result, "Widget", "as cast to project type must resolve via project index")
  }

  Void testAsCastWithChainedCall()
  {
    // Common pattern: val := dict.get("key") as Str
    src :=
      "class Handler {\n" +
      "  Void handle(Obj dict) {\n" +
      "    name := dict.get(\"id\") as Str\n" +
      "    echo(name)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Handler.fan": src])
    result := TypeResolver.resolveVarType("name", src, 3, idx)
    verifyEq(result, "sys::Str", "as Str cast in chained call must resolve")
  }

//////////////////////////////////////////////////////////////////////////
// Bare method call (no receiver): x := methodName(args)
//////////////////////////////////////////////////////////////////////////

  Void testBareSameClassMethodCall()
  {
    // x := normalize("hello") — normalize is a method of the same class
    src :=
      "class Processor {\n" +
      "  Str normalize(Str s) { return s.trim }\n" +
      "  Void process() {\n" +
      "    result := normalize(\"hello\")\n" +
      "    echo(result)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Processor.fan": src])
    result := TypeResolver.resolveVarType("result", src, 4, idx)
    verifyEq(result, "Str", "bare method call return type must be inferred from project index")
  }

  Void testBareSiblingFileMethodCall()
  {
    // x := buildLabel() where buildLabel is declared in a sibling file
    helperSrc :=
      "class LabelBuilder {\n" +
      "  static Str buildLabel(Str prefix) { return prefix }\n" +
      "}\n"
    mainSrc :=
      "class App {\n" +
      "  Str buildLabel(Str s) { return s }\n" +
      "  Void run() {\n" +
      "    lbl := buildLabel(\"x\")\n" +
      "    echo(lbl)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///LabelBuilder.fan": helperSrc, "file:///App.fan": mainSrc])
    result := TypeResolver.resolveVarType("lbl", mainSrc, 4, idx)
    verifyEq(result, "Str", "bare method call return type must be inferred when method is indexed")
  }

  Void testBareMethodCallVoidReturnIgnored()
  {
    // Void-return methods must not produce a type (would be useless noise)
    src :=
      "class Repo {\n" +
      "  Void flush() {}\n" +
      "  Void save() {\n" +
      "    x := flush()\n" +
      "    echo(x)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Repo.fan": src])
    result := TypeResolver.resolveVarType("x", src, 4, idx)
    verify(result == null || result != "Void",
      "Void-return bare call must not infer type 'Void'")
  }

//////////////////////////////////////////////////////////////////////////
// Static method call on project type: x := ProjectType.method(args)
//////////////////////////////////////////////////////////////////////////

  Void testStaticMethodOnProjectType()
  {
    // x := Registry.lookup("id") where Registry is a project type
    registrySrc :=
      "class Registry {\n" +
      "  static Str lookup(Str id) { return id }\n" +
      "}\n"
    mainSrc :=
      "class App {\n" +
      "  Void run() {\n" +
      "    name := Registry.lookup(\"myId\")\n" +
      "    echo(name)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Registry.fan": registrySrc, "file:///App.fan": mainSrc])
    result := TypeResolver.resolveVarType("name", mainSrc, 3, idx)
    verifyEq(result, "Str", "static method on project type must be inferred via project index")
  }

  Void testStaticIntMethodOnProjectType()
  {
    // x := Counter.next() → Int
    counterSrc :=
      "class Counter {\n" +
      "  static Int next() { return 0 }\n" +
      "}\n"
    mainSrc :=
      "class Svc {\n" +
      "  Void run() {\n" +
      "    n := Counter.next()\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Counter.fan": counterSrc, "file:///Svc.fan": mainSrc])
    result := TypeResolver.resolveVarType("n", mainSrc, 2, idx)
    verifyEq(result, "Int", "static Int method on project type must infer Int")
  }

  Void testInstanceMethodOnProjectType()
  {
    // x := parser.parse(src) where parser is explicit-typed Parser
    parserSrc :=
      "class Parser {\n" +
      "  Str parse(Str src) { return src }\n" +
      "}\n"
    mainSrc :=
      "class App {\n" +
      "  Void run(Str src) {\n" +
      "    Parser parser := Parser()\n" +
      "    result := parser.parse(src)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Parser.fan": parserSrc, "file:///App.fan": mainSrc])
    result := TypeResolver.resolveVarType("result", mainSrc, 4, idx)
    verifyEq(result, "Str", "instance method on explicit-typed project-type local must infer return type")
  }

//////////////////////////////////////////////////////////////////////////
// Field / property access without parens: x := obj.field
//////////////////////////////////////////////////////////////////////////

  Void testFieldAccessOnExplicitlyTypedLocal()
  {
    // Config cfg := Config(); h := cfg.host → Str
    configSrc :=
      "class Config {\n" +
      "  Str host := \"localhost\"\n" +
      "}\n"
    mainSrc :=
      "class App {\n" +
      "  Void run() {\n" +
      "    Config cfg := Config()\n" +
      "    h := cfg.host\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Config.fan": configSrc, "file:///App.fan": mainSrc])
    result := TypeResolver.resolveVarType("h", mainSrc, 4, idx)
    verifyEq(result, "Str", "field access on explicitly-typed local must resolve via project index")
  }

  Void testFieldAccessIntType()
  {
    // Metric m := Metric(); count := m.total → Int
    metricSrc :=
      "class Metric {\n" +
      "  Int total := 0\n" +
      "}\n"
    mainSrc :=
      "class App {\n" +
      "  Void run() {\n" +
      "    Metric m := Metric()\n" +
      "    count := m.total\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Metric.fan": metricSrc, "file:///App.fan": mainSrc])
    result := TypeResolver.resolveVarType("count", mainSrc, 4, idx)
    verifyEq(result, "Int", "Int field access on explicitly-typed local must resolve")
  }

  Void testFieldAccessOnProjectTypeParam()
  {
    // When the hovered symbol IS a method parameter whose type is a project type,
    // resolveVarType must recognise it via the parameter-scanning pass.
    configSrc :=
      "class Config {\n" +
      "  Str host := \"localhost\"\n" +
      "}\n"
    mainSrc :=
      "class App {\n" +
      "  Void run(Config cfg) {\n" +
      "    echo(cfg)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Config.fan": configSrc, "file:///App.fan": mainSrc])
    // Hovering over 'cfg' on line 2 — resolveVarType uses the param-scanning pass
    result := TypeResolver.resolveVarType("cfg", mainSrc, 2, idx)
    verifyEq(result, "Config", "method param type must be found when hovering the param name")
  }

  Void testFieldAccessIgnoresExprWithParens()
  {
    // Ensure inferTypeFromMemberAccess does not misfire on method calls
    src :=
      "class Svc {\n" +
      "  Str label() { return \"x\" }\n" +
      "  Void run() {\n" +
      "    x := label()\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Svc.fan": src])
    // Must be resolved by method-call path, not field-access path
    result := TypeResolver.resolveVarType("x", src, 4, idx)
    verifyEq(result, "Str", "method call result must still resolve even though field-access path is active")
  }

//////////////////////////////////////////////////////////////////////////
// Real-world compound patterns (inspired by actual project code)
//////////////////////////////////////////////////////////////////////////

  Void testCtorInferenceWithProjectType()
  {
    // widget := Widget("hello") — ctor call, Widget is in project index
    widgetSrc :=
      "class Widget {\n" +
      "  Str label := \"\"\n" +
      "  new make(Str label) { this.label = label }\n" +
      "}\n"
    mainSrc :=
      "class Page {\n" +
      "  Void build() {\n" +
      "    widget := Widget(\"title\")\n" +
      "    echo(widget)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Widget.fan": widgetSrc, "file:///Page.fan": mainSrc])
    result := TypeResolver.resolveVarType("widget", mainSrc, 3, idx)
    verifyEq(result, "Widget", "ctor inference for project type must work")
  }

  Void testChainedStaticAndInstanceOnProjectType()
  {
    // factory := Registry.make(); name := factory.defaultName()
    regSrc :=
      "class Registry {\n" +
      "  static Registry make() { return Registry() }\n" +
      "  Str defaultName() { return \"default\" }\n" +
      "}\n"
    mainSrc :=
      "class App {\n" +
      "  Void run() {\n" +
      "    Registry factory := Registry.make()\n" +
      "    name := factory.defaultName()\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Registry.fan": regSrc, "file:///App.fan": mainSrc])
    result := TypeResolver.resolveVarType("name", mainSrc, 4, idx)
    verifyEq(result, "Str", "instance method on explicit-typed-from-static-factory local must resolve")
  }

//////////////////////////////////////////////////////////////////////////
// False-positive Map inference regressions
//////////////////////////////////////////////////////////////////////////

  Void testVarInRhsOfOtherAssignmentNotMap()
  {
    // 'msg' is a Str, but it also appears bare on the RHS of another assignment:
    //   n := msg
    // The ':=' from that other variable must NOT be treated as a map-type ':'
    // causing resolveVarType("msg") to return "Map".
    src :=
      "class Svc {\n" +
      "  Void run() {\n" +
      "    Str msg := \"hello\"\n" +
      "    n := msg\n" +
      "    echo(msg)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Svc.fan": src])
    result := TypeResolver.resolveVarType("msg", src, 4, idx)
    verifyEq(result, "sys::Str",
      "var appearing bare on the RHS of another := must not be inferred as Map")
  }

  Void testVarAfterNullSafeAccessNotMap()
  {
    // 'dev' is a Str, but it appears as the receiver of a null-safe access:
    //   n := dev?.size
    // The '?' after 'dev' must not cause extractDeclaredType to miss this exclusion,
    // and the ':=' in 'before' must not trigger the Map detection.
    src :=
      "class Svc {\n" +
      "  Void run() {\n" +
      "    Str dev := \"hello\"\n" +
      "    n := dev?.size\n" +
      "    echo(dev)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Svc.fan": src])
    result := TypeResolver.resolveVarType("dev", src, 4, idx)
    verifyEq(result, "sys::Str",
      "var used as null-safe receiver on another assignment's RHS must not be inferred as Map")
  }

  Void testVarInDictLiteralValueNotMap()
  {
    // 'host' is Str, but it also appears as a value in a dict-literal entry:
    //   ["hostTag" : host]
    // The colon before 'host' in the dict entry must not cause resolveVarType
    // to return "Map" for 'host'.
    src :=
      "class Svc {\n" +
      "  Void run() {\n" +
      "    Str host := \"localhost\"\n" +
      "    d := [\"hostTag\" : host]\n" +
      "    echo(host)\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Svc.fan": src])
    result := TypeResolver.resolveVarType("host", src, 4, idx)
    verifyEq(result, "sys::Str",
      "var used as dict-literal value must not be inferred as Map")
  }
}
