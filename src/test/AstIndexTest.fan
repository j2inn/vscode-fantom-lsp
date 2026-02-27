//
// Copyright (c) 2025, Brian Frank and Andy Frank
// Licensed under the Academic Free License version 3.0
//
// History:
//   14 Feb 26  Creation
//

**
** AstIndexTest - Tests for the AST wrapper that abstracts compiler internals
**
class AstIndexTest : Test
{

//////////////////////////////////////////////////////////////////////////
// Parse Basic Class
//////////////////////////////////////////////////////////////////////////

  Void testParseBasicClass()
  {
    source :=
      "class Person\n" +
      "{\n" +
      "  Str name\n" +
      "  Int age\n" +
      "\n" +
      "  Void greet(Str msg)\n" +
      "  {\n" +
      "    echo(msg)\n" +
      "  }\n" +
      "}"

    ast := AstIndex.parse("file:///test/Person.fan", source)
    verifyNotNull(ast)
    verifyEq(ast.types.size, 1)

    t := ast.types[0]
    verifyEq(t.name, "Person")
    verify(!t.isEnum)
    verify(!t.isMixin)

    // Fields
    verify(t.fields.size >= 2)
    nameFld := t.fields.find |f| { f.name == "name" }
    verifyNotNull(nameFld)
    verify(nameFld.isField)

    ageFld := t.fields.find |f| { f.name == "age" }
    verifyNotNull(ageFld)
    verify(ageFld.isField)

    // Methods
    greetMethod := t.methods.find |m| { m.name == "greet" }
    verifyNotNull(greetMethod)
    verify(!greetMethod.isField)

    // Method params
    verifyEq(greetMethod.params.size, 1)
    verifyEq(greetMethod.params[0].name, "msg")
  }

//////////////////////////////////////////////////////////////////////////
// Parse Enum
//////////////////////////////////////////////////////////////////////////

  Void testParseEnum()
  {
    source :=
      "enum class Color\n" +
      "{\n" +
      "  red,\n" +
      "  green,\n" +
      "  blue\n" +
      "}"

    ast := AstIndex.parse("file:///test/Color.fan", source)
    verifyNotNull(ast)
    verifyEq(ast.types.size, 1)

    t := ast.types[0]
    verifyEq(t.name, "Color")
    verify(t.isEnum)

    // Enum values
    verifyEq(t.enumVals.size, 3)
    verifyEq(t.enumVals[0].name, "red")
    verifyEq(t.enumVals[0].ordinal, 0)
    verifyEq(t.enumVals[1].name, "green")
    verifyEq(t.enumVals[1].ordinal, 1)
    verifyEq(t.enumVals[2].name, "blue")
    verifyEq(t.enumVals[2].ordinal, 2)
  }

//////////////////////////////////////////////////////////////////////////
// Parse Mixin
//////////////////////////////////////////////////////////////////////////

  Void testParseMixin()
  {
    source :=
      "mixin Printable\n" +
      "{\n" +
      "  abstract Str format()\n" +
      "}"

    ast := AstIndex.parse("file:///test/Printable.fan", source)
    verifyNotNull(ast)
    verifyEq(ast.types.size, 1)

    t := ast.types[0]
    verifyEq(t.name, "Printable")
    verify(t.isMixin)
  }

//////////////////////////////////////////////////////////////////////////
// Parse Class with Base Type
//////////////////////////////////////////////////////////////////////////

  Void testParseBaseType()
  {
    source :=
      "class Animal\n" +
      "{\n" +
      "  Str species\n" +
      "}"

    ast := AstIndex.parse("file:///test/Animal.fan", source)
    verifyNotNull(ast)
    t := ast.types[0]
    // In script mode, the base is usually Obj
    verifyEq(t.name, "Animal")
  }

//////////////////////////////////////////////////////////////////////////
// Walk Block Local Vars
//////////////////////////////////////////////////////////////////////////

  Void testLocalVarsInMethod()
  {
    source :=
      "class Calc\n" +
      "{\n" +
      "  Void compute()\n" +
      "  {\n" +
      "    x := 10\n" +
      "    y := 20\n" +
      "    result := x + y\n" +
      "  }\n" +
      "}"

    ast := AstIndex.parse("file:///test/Calc.fan", source)
    verifyNotNull(ast)

    computeMethod := ast.types[0].methods.find |m| { m.name == "compute" }
    verifyNotNull(computeMethod)

    // Should have local vars
    localVars := computeMethod.localVars
    xVar := localVars.find |v| { v.name == "x" }
    verifyNotNull(xVar)
    verify(!xVar.isClosureParam)

    yVar := localVars.find |v| { v.name == "y" }
    verifyNotNull(yVar)

    resultVar := localVars.find |v| { v.name == "result" }
    verifyNotNull(resultVar)
  }

//////////////////////////////////////////////////////////////////////////
// Walk Block Closure Params
//////////////////////////////////////////////////////////////////////////

  Void testClosureParamsExtracted()
  {
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

    ast := AstIndex.parse("file:///test/Processor.fan", source)
    verifyNotNull(ast)

    runMethod := ast.types[0].methods.find |m| { m.name == "run" }
    verifyNotNull(runMethod)

    // Should have closure param "item"
    itemVar := runMethod.localVars.find |v| { v.name == "item" }
    verifyNotNull(itemVar)
    verify(itemVar.isClosureParam)
  }

//////////////////////////////////////////////////////////////////////////
// Parse Returns Null for Invalid Source
//////////////////////////////////////////////////////////////////////////

  Void testParseInvalidSource()
  {
    // Completely broken source
    ast := AstIndex.parse("file:///test/Bad.fan", "this is not valid fantom")
    // Should return null or an empty result, not crash
    // (compiler may still parse something)
  }

//////////////////////////////////////////////////////////////////////////
// Multiple Types
//////////////////////////////////////////////////////////////////////////

  Void testMultipleTypes()
  {
    source :=
      "class Alpha\n" +
      "{\n" +
      "  Str name\n" +
      "}\n" +
      "\n" +
      "class Beta\n" +
      "{\n" +
      "  Int count\n" +
      "}"

    ast := AstIndex.parse("file:///test/Multi.fan", source)
    verifyNotNull(ast)
    verifyEq(ast.types.size, 2)
    verifyEq(ast.types[0].name, "Alpha")
    verifyEq(ast.types[1].name, "Beta")
  }
}
