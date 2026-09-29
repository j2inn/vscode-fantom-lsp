
**
** SourceStubberTest - Tests for signature-only stub generation
**
class SourceStubberTest : Test
{
  private static const Str stubBody := SourceStubber.stubBody

//////////////////////////////////////////////////////////////////////////
// Body Replacement
//////////////////////////////////////////////////////////////////////////

  Void testMethodAndCtorBodiesReplaced()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  const Str name := \"x\"\n" +
      "  new make(Str name) { this.name = name }\n" +
      "  Str greet(Str who) { return \"hi \$who\" }\n" +
      "}"

    stub := SourceStubber.stub("file:///test/Foo.fan", source)?.source

    verifyEq(stub,
      "class Foo\n" +
      "{\n" +
      "  const Str name := \"x\"\n" +
      "  new make(Str name) $stubBody\n" +
      "  Str greet(Str who) $stubBody\n" +
      "}")
  }

  Void testCtorChainKept()
  {
    source :=
      "class Child : Base\n" +
      "{\n" +
      "  new make(Int x) : super(x) { echo(x) }\n" +
      "}"

    stub := SourceStubber.stub("file:///test/Child.fan", source)?.source

    verifyEq(stub,
      "class Child : Base\n" +
      "{\n" +
      "  new make(Int x) : super(x) $stubBody\n" +
      "}")
  }

  Void testMultiLineBodyWithClosuresAndBraceStrings()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Int[] run(Int[] items)\n" +
      "  {\n" +
      "    s := \"} not a brace {\"\n" +
      "    return items.map |i| { i + 1 }\n" +
      "  }\n" +
      "  Void other() {}\n" +
      "}"

    stub := SourceStubber.stub("file:///test/Foo.fan", source)?.source

    verifyEq(stub,
      "class Foo\n" +
      "{\n" +
      "  Int[] run(Int[] items)\n" +
      "  $stubBody\n" +
      "  Void other() $stubBody\n" +
      "}")
  }

  Void testAbstractMethodsAndUsingsUntouched()
  {
    source :=
      "using concurrent\n" +
      "\n" +
      "abstract class Foo\n" +
      "{\n" +
      "  abstract Str name()\n" +
      "  @Deprecated Void old() { echo(1) }\n" +
      "}"

    stub := SourceStubber.stub("file:///test/Foo.fan", source)?.source

    verifyEq(stub,
      "using concurrent\n" +
      "\n" +
      "abstract class Foo\n" +
      "{\n" +
      "  abstract Str name()\n" +
      "  @Deprecated Void old() $stubBody\n" +
      "}")
  }

  Void testEnumCtorAndValuesKept()
  {
    source :=
      "enum class Color\n" +
      "{\n" +
      "  red(\"R\"), green(\"G\")\n" +
      "  private new make(Str code) { this.code = code }\n" +
      "  const Str code\n" +
      "}"

    stub := SourceStubber.stub("file:///test/Color.fan", source)?.source

    verifyEq(stub,
      "enum class Color\n" +
      "{\n" +
      "  red(\"R\"), green(\"G\")\n" +
      "  private new make(Str code) $stubBody\n" +
      "  const Str code\n" +
      "}")
  }

  **
  ** Types from other files are unknown while stubbing a single file:
  ** only a syntax error prevents stubbing.
  **
  Void testUnresolvedTypesStillStubbed()
  {
    source :=
      "class Foo : OtherBase\n" +
      "{\n" +
      "  OtherType make2() { return OtherType() }\n" +
      "}"

    stub := SourceStubber.stub("file:///test/Foo.fan", source)?.source

    verifyEq(stub,
      "class Foo : OtherBase\n" +
      "{\n" +
      "  OtherType make2() $stubBody\n" +
      "}")
  }

  Void testFieldAccessorBodiesReplaced()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Int count := 0 { set { &count = it.max(0) } }\n" +
      "  Str label { get { return \"n=\$count\" } }\n" +
      "}"

    stub := SourceStubber.stub("file:///test/Foo.fan", source)?.source

    verifyEq(stub,
      "class Foo\n" +
      "{\n" +
      "  Int count := 0 { set $stubBody }\n" +
      "  Str label { get $stubBody }\n" +
      "}")
  }

  **
  ** Without placeholders, 'Other x := ...' in a body stops the parser;
  ** with the other project type names declared, the file is stubbed.
  **
  Void testPlaceholdersAllowTypedLocalsOfOtherTypes()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run() { Other x := Other(); echo(Other#) }\n" +
      "}"

    verifyNull(SourceStubber.stub("file:///test/Foo.fan", source))
    stub := SourceStubber.stub("file:///test/Foo.fan", source, ["Other"])?.source
    verifyEq(stub,
      "class Foo\n" +
      "{\n" +
      "  Void run() $stubBody\n" +
      "}")
  }

  **
  ** Referenced types come from the compiled part of the stub only:
  ** signatures, base types, facets and parameter defaults, not method
  ** bodies or field initializers.
  **
  Void testReferencedTypesFromSignaturesOnly()
  {
    others := ["Base", "Mix", "RetT", "ParamT", "ListT", "MapK", "MapV",
      "FuncP", "FieldT", "DefT", "BodyT", "InitT"]
    source :=
      "class Foo : Base, Mix\n" +
      "{\n" +
      "  const FieldT? field := InitT.make\n" +
      "  RetT? run(ParamT p, ListT[] l, [MapK:MapV] m, |FuncP| f, Str s := DefT.name)\n" +
      "  {\n" +
      "    return BodyT.make\n" +
      "  }\n" +
      "}"

    refs := SourceStubber.stub("file:///test/Foo.fan", source, others).referencedTypes

    ["Base", "Mix", "RetT", "ParamT", "ListT", "MapK", "MapV", "FuncP",
     "FieldT", "DefT"].each |name| { verify(refs.contains(name), name) }
    verifyFalse(refs.contains("BodyT"))
    verifyFalse(refs.contains("InitT"))
  }

  Void testPlaceholdersSkipSyntheticNames()
  {
    verifyEq(SourceStubber.placeholders(["Foo", "Foo\$0", "Bar_1"]),
      "class Foo {}\nclass Bar_1 {}")
  }

  Void testSyntaxErrorReturnsNull()
  {
    source :=
      "class Foo\n" +
      "{\n" +
      "  Void run( { }\n" +
      "}"

    verifyNull(SourceStubber.stub("file:///test/Foo.fan", source)?.source)
  }
}
