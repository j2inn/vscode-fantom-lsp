
**
** SemanticTokensServiceTest - Tests for SemanticTokensService.
**
class SemanticTokensServiceTest : Test
{
  private ProjectIndex makeIndex([Str:Str] files)
  {
    idx := ProjectIndex()
    files.each |src, uri| { idx.indexFile(uri, src) }
    return idx
  }

//////////////////////////////////////////////////////////////////////////
// Helpers
//////////////////////////////////////////////////////////////////////////

  ** Decode flat data array into list of [deltaLine, deltaCol, len, type, mods] tuples
  private Int[][] decode(Int[] data)
  {
    result := Int[][,]
    i := 0
    while (i + 4 < data.size)
    {
      result.add([data[i], data[i+1], data[i+2], data[i+3], data[i+4]])
      i += 5
    }
    return result
  }

  ** Reconstruct absolute positions from delta-encoded data
  private Int[][] absolute(Int[] data)
  {
    result := Int[][,]
    line := 0
    col  := 0
    i    := 0
    while (i + 4 < data.size)
    {
      dLine := data[i]
      dCol  := data[i+1]
      len   := data[i+2]
      tt    := data[i+3]
      mods  := data[i+4]
      line = line + dLine
      col  = dLine == 0 ? col + dCol : dCol
      result.add([line, col, len, tt, mods])
      i += 5
    }
    return result
  }

//////////////////////////////////////////////////////////////////////////
// Basic encoding
//////////////////////////////////////////////////////////////////////////

  Void testEmptyFileReturnsEmptyData()
  {
    src := "class Empty {}\n"
    idx := makeIndex(["file:///Empty.fan": src])
    svc := SemanticTokensService()
    result := svc.fullTokens("file:///Empty.fan", idx)
    verifyNotNull(result, "result must not be null")
    data := result["data"] as Int[]
    verifyNotNull(data)
    // "Empty" type token — at minimum one token expected
    verify(data.size >= 5, "at least one token expected for the type declaration")
  }

  Void testUnindexedFileReturnsEmptyData()
  {
    idx := ProjectIndex()
    svc := SemanticTokensService()
    result := svc.fullTokens("file:///Missing.fan", idx)
    data := result["data"] as Int[]
    verifyNotNull(data)
    verifyEq(data.size, 0, "unindexed file must return empty data")
  }

//////////////////////////////////////////////////////////////////////////
// Token types
//////////////////////////////////////////////////////////////////////////

  Void testTypeDeclarationProducesTypeToken()
  {
    src := "class Widget {}\n"
    idx := makeIndex(["file:///Widget.fan": src])
    svc := SemanticTokensService()
    result := svc.fullTokens("file:///Widget.fan", idx)
    data := result["data"] as Int[]
    verifyNotNull(data)

    tokens := absolute(data)
    typeTokens := tokens.findAll |t| { t[3] == SemanticTokenTypes.typeToken }
    verify(typeTokens.size >= 1, "must have at least one type token")
    widgetToken := typeTokens.find |t| { t[2] == "Widget".size }
    verifyNotNull(widgetToken, "type token for 'Widget' (len 6) must be present")
  }

  Void testMethodProducesMethodToken()
  {
    src :=
      "class Svc {\n" +
      "  Void run() {}\n" +
      "}\n"
    idx := makeIndex(["file:///Svc.fan": src])
    svc := SemanticTokensService()
    result := svc.fullTokens("file:///Svc.fan", idx)
    data := result["data"] as Int[]

    tokens := absolute(data)
    methodTokens := tokens.findAll |t| { t[3] == SemanticTokenTypes.method }
    verify(methodTokens.size >= 1, "must have at least one method token")
    runToken := methodTokens.find |t| { t[2] == "run".size }
    verifyNotNull(runToken, "method token for 'run' (len 3) must be present")
  }

  Void testFieldProducesFieldToken()
  {
    src :=
      "class Cfg {\n" +
      "  Str host := \"localhost\"\n" +
      "}\n"
    idx := makeIndex(["file:///Cfg.fan": src])
    svc := SemanticTokensService()
    result := svc.fullTokens("file:///Cfg.fan", idx)
    data := result["data"] as Int[]

    tokens := absolute(data)
    fieldTokens := tokens.findAll |t| { t[3] == SemanticTokenTypes.field }
    verify(fieldTokens.size >= 1, "must have at least one field token")
    hostToken := fieldTokens.find |t| { t[2] == "host".size }
    verifyNotNull(hostToken, "field token for 'host' (len 4) must be present")
  }

  Void testLocalVarProducesVariableToken()
  {
    src :=
      "class Svc {\n" +
      "  Void run() {\n" +
      "    Str msg := \"hi\"\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///Svc.fan": src])
    svc := SemanticTokensService()
    result := svc.fullTokens("file:///Svc.fan", idx)
    data := result["data"] as Int[]

    tokens := absolute(data)
    varTokens := tokens.findAll |t| { t[3] == SemanticTokenTypes.variable }
    msgToken := varTokens.find |t| { t[2] == "msg".size }
    verifyNotNull(msgToken, "variable token for 'msg' must be present")
  }

  Void testParamProducesParameterToken()
  {
    src :=
      "class Svc {\n" +
      "  Void run(Str name) {}\n" +
      "}\n"
    idx := makeIndex(["file:///Svc.fan": src])
    svc := SemanticTokensService()
    result := svc.fullTokens("file:///Svc.fan", idx)
    data := result["data"] as Int[]

    tokens := absolute(data)
    paramTokens := tokens.findAll |t| { t[3] == SemanticTokenTypes.parameter }
    nameToken := paramTokens.find |t| { t[2] == "name".size }
    verifyNotNull(nameToken, "parameter token for 'name' must be present")
  }

  Void testEnumValProducesEnumMemberToken()
  {
    src :=
      "enum class Color { red, green, blue }\n"
    idx := makeIndex(["file:///Color.fan": src])
    svc := SemanticTokensService()
    result := svc.fullTokens("file:///Color.fan", idx)
    data := result["data"] as Int[]

    tokens := absolute(data)
    enumTokens := tokens.findAll |t| { t[3] == SemanticTokenTypes.enumMember }
    verify(enumTokens.size >= 3, "must have tokens for red, green, blue")
    redToken := enumTokens.find |t| { t[2] == "red".size }
    verifyNotNull(redToken, "enumMember token for 'red' must be present")
  }

//////////////////////////////////////////////////////////////////////////
// Modifiers
//////////////////////////////////////////////////////////////////////////

  Void testStaticMethodHasStaticModifier()
  {
    src :=
      "class Util {\n" +
      "  static Str build(Str s) { return s }\n" +
      "}\n"
    idx := makeIndex(["file:///Util.fan": src])
    svc := SemanticTokensService()
    result := svc.fullTokens("file:///Util.fan", idx)
    data := result["data"] as Int[]

    tokens := absolute(data)
    buildTokens := tokens.findAll |t| {
      t[3] == SemanticTokenTypes.method && t[2] == "build".size
    }
    verify(buildTokens.size >= 1, "must find 'build' method token")
    mods := buildTokens.first[4]
    verify((mods.and(SemanticTokenModifiers.staticMod)) != 0,
      "static method must have static modifier bit set")
  }

  Void testInstanceMethodHasNoStaticModifier()
  {
    src :=
      "class Svc {\n" +
      "  Str label() { return \"x\" }\n" +
      "}\n"
    idx := makeIndex(["file:///Svc.fan": src])
    svc := SemanticTokensService()
    result := svc.fullTokens("file:///Svc.fan", idx)
    data := result["data"] as Int[]

    tokens := absolute(data)
    labelTokens := tokens.findAll |t| {
      t[3] == SemanticTokenTypes.method && t[2] == "label".size
    }
    verify(labelTokens.size >= 1, "must find 'label' method token")
    mods := labelTokens.first[4]
    verifyEq(mods.and(SemanticTokenModifiers.staticMod), 0,
      "instance method must NOT have static modifier bit set")
  }

//////////////////////////////////////////////////////////////////////////
// Delta encoding correctness
//////////////////////////////////////////////////////////////////////////

  Void testDeltaEncodingIsCorrect()
  {
    // Verify that the delta->absolute reconstruction is self-consistent:
    // two tokens on different lines must encode with deltaLine > 0 for the second one.
    src :=
      "class Svc {\n" +
      "  Str host := \"x\"\n" +
      "  Str port := \"y\"\n" +
      "}\n"
    idx := makeIndex(["file:///Svc.fan": src])
    svc := SemanticTokensService()
    result := svc.fullTokens("file:///Svc.fan", idx)
    data := result["data"] as Int[]
    verify(data.size % 5 == 0, "data length must be a multiple of 5")

    // Reconstruct and verify lines are non-decreasing
    tokens := absolute(data)
    prevLine := -1
    tokens.each |t|
    {
      verify(t[0] >= prevLine, "token lines must be non-decreasing")
      prevLine = t[0]
    }
  }

  Void testDataLengthMultipleOfFive()
  {
    src :=
      "class App {\n" +
      "  Void run(Str name) {\n" +
      "    Str msg := name\n" +
      "  }\n" +
      "}\n"
    idx := makeIndex(["file:///App.fan": src])
    svc := SemanticTokensService()
    result := svc.fullTokens("file:///App.fan", idx)
    data := result["data"] as Int[]
    verifyEq(data.size % 5, 0, "semantic token data array length must be a multiple of 5")
  }
}
