
**
** LSP message data structures
**

**************************************************************************
** Position
**************************************************************************

**
** Position in a text document expressed as zero-based line and column
**
class LspPosition
{
  ** Zero-based line number
  Int line

  ** Zero-based character offset on a line
  Int character

  new make(Int line, Int character)
  {
    this.line = line
    this.character = character
  }

  Str:Obj? toMap()
  {
    ["line": line, "character": character]
  }

  static LspPosition fromMap(Str:Obj? map)
  {
    LspPosition(map["line"], map["character"])
  }
}

**************************************************************************
** Range
**************************************************************************

**
** Range in a text document expressed as start and end positions
**
class LspRange
{
  ** Start position (inclusive)
  LspPosition start

  ** End position (exclusive)
  LspPosition end

  new make(LspPosition start, LspPosition end)
  {
    this.start = start
    this.end = end
  }

  Str:Obj? toMap()
  {
    ["start": start.toMap, "end": end.toMap]
  }

  static LspRange fromMap(Str:Obj? map)
  {
    LspRange(LspPosition.fromMap(map["start"]), LspPosition.fromMap(map["end"]))
  }
}

**************************************************************************
** Diagnostic
**************************************************************************

**
** Diagnostic represents a compiler error or warning
**
class LspDiagnostic
{
  ** Range of the diagnostic
  LspRange range

  ** Severity: 1=Error, 2=Warning, 3=Information, 4=Hint
  Int severity

  ** Diagnostic message
  Str message

  ** Source of diagnostic (e.g., "fantom")
  Str? source := null

  new make(LspRange range, Int severity, Str message, Str? source := null)
  {
    this.range = range
    this.severity = severity
    this.message = message
    this.source = source
  }

  Str:Obj? toMap()
  {
    map := Str:Obj?["range": range.toMap, "severity": severity, "message": message]
    if (source != null) map["source"] = source
    return map
  }
}

**************************************************************************
** DiagnosticSeverity
**************************************************************************

**
** Diagnostic severity constants
**
class DiagnosticSeverity
{
  static const Int error := 1
  static const Int warning := 2
  static const Int information := 3
  static const Int hint := 4
}

**************************************************************************
** CompletionItem
**************************************************************************

**
** Completion item
**
class CompletionItem
{
  ** The label of this completion item
  Str label

  ** The kind of this completion item (Method, Field, Class, etc.)
  Int? kind := null

  ** A human-readable string with additional information
  Str? detail := null

  ** Documentation string
  Str? documentation := null

  ** The text to insert (can be a snippet)
  Str? insertText := null

  ** The format of insertText: 1=PlainText, 2=Snippet
  Int? insertTextFormat := null

  ** A string used by the client to sort completion items.
  Str? sortText := null

  new make(Str label, Int? kind := null, Str? detail := null, Str? documentation := null, Str? insertText := null, Int? insertTextFormat := null, Str? sortText := null)
  {
    this.label = label
    this.kind = kind
    this.detail = detail
    this.documentation = documentation
    this.insertText = insertText
    this.insertTextFormat = insertTextFormat
    this.sortText = sortText
  }

  Str:Obj? toMap()
  {
    map := Str:Obj?["label": label]
    if (kind != null) map["kind"] = kind
    if (detail != null) map["detail"] = detail
    if (documentation != null)
      map["documentation"] = Str:Obj["kind": "markdown", "value": documentation]
    if (insertText != null) map["insertText"] = insertText
    if (insertTextFormat != null) map["insertTextFormat"] = insertTextFormat
    if (sortText != null) map["sortText"] = sortText
    return map
  }
}

**************************************************************************
** CompletionItemKind
**************************************************************************

**
** Completion item kind constants
**
class CompletionItemKind
{
  static const Int text := 1
  static const Int method := 2
  static const Int function := 3
  static const Int constructor := 4
  static const Int field := 5
  static const Int variable := 6
  static const Int classKind := 7
  static const Int interface := 8
  static const Int module := 9
  static const Int property := 10
  static const Int unit := 11
  static const Int value := 12
  static const Int enum := 13
  static const Int keyword := 14
  static const Int snippet := 15
  static const Int color := 16
  static const Int file := 17
  static const Int reference := 18
}

**************************************************************************
** TextDocumentIdentifier
**************************************************************************

**
** Text document identifier
**
class TextDocumentIdentifier
{
  ** The URI of the document
  Str uri

  new make(Str uri)
  {
    this.uri = uri
  }

  static TextDocumentIdentifier? fromMap(Str:Obj? map)
  {
    uri := map["uri"] as Str
    return uri == null ? null : TextDocumentIdentifier(uri)
  }
}

**************************************************************************
** VersionedTextDocumentIdentifier
**************************************************************************

**
** Versioned text document identifier
**
class VersionedTextDocumentIdentifier : TextDocumentIdentifier
{
  ** The version number of this document
  Int version

  new make(Str uri, Int version) : super(uri)
  {
    this.version = version
  }

  static VersionedTextDocumentIdentifier? fromMapVersioned(Str:Obj? map)
  {
    uri := map["uri"] as Str
    version := map["version"] as Int
    return uri == null || version == null ? null : VersionedTextDocumentIdentifier(uri, version)
  }
}

**************************************************************************
** TextDocumentItem
**************************************************************************

**
** Text document item
**
class TextDocumentItem
{
  ** The URI of the document
  Str uri

  ** The language identifier (e.g., "fantom")
  Str languageId

  ** The version number of this document
  Int version

  ** The content of the opened text document
  Str text

  new make(Str uri, Str languageId, Int version, Str text)
  {
    this.uri = uri
    this.languageId = languageId
    this.version = version
    this.text = text
  }

  static TextDocumentItem? fromMap(Str:Obj? map)
  {
    rawUri := map["uri"] as Str
    languageId := map["languageId"] as Str
    version := map["version"] as Int
    text := map["text"] as Str
    if (rawUri == null || languageId == null || version == null || text == null)
      return null
    uri := LspUtil.normalizeFileUri(rawUri)
    return TextDocumentItem(uri, languageId, version, text)
  }
}

**************************************************************************
** TextDocumentContentChangeEvent
**************************************************************************

**
** Text document content change event
**
class TextDocumentContentChangeEvent
{
  ** The range of the document that changed (null for full document)
  LspRange? range := null

  ** The new text of the range (or full document)
  Str text

  new make(Str text, LspRange? range := null)
  {
    this.text = text
    this.range = range
  }

  static TextDocumentContentChangeEvent fromMap(Str:Obj? map)
  {
    text := map["text"] as Str
    rangeMap := map["range"] as Str:Obj?
    range := rangeMap == null ? null : LspRange.fromMap(rangeMap)
    return TextDocumentContentChangeEvent(text, range)
  }
}
