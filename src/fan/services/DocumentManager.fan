
**
** DocumentManager - Tracks open documents in memory
**
class DocumentManager
{
  **
  ** Map of URI to Document
  **
  private Str:Document docs := [:]

  **
  ** Open a document
  **
  Void open(TextDocumentItem item)
  {
    docs[item.uri] = Document(item.uri, item.text, item.version)
    LspProtocol.logInfo("Opened document: ${item.uri}")
  }

  **
  ** Change a document
  **
  Void change(Str uri, TextDocumentContentChangeEvent[] changes, Int version)
  {
    doc := docs[uri]
    if (doc == null)
    {
      LspProtocol.logInfo("Document not found for change: $uri")
      return
    }

    doc.applyChanges(changes)
    doc.version = version
    LspProtocol.logInfo("Changed document: $uri (version $version)")
  }

  **
  ** Close a document
  **
  Void close(Str uri)
  {
    docs.remove(uri)
    LspProtocol.logInfo("Closed document: $uri")
  }

  **
  ** Get a document by URI
  **
  Document? get(Str uri)
  {
    return docs[uri]
  }

  **
  ** Get all open documents
  **
  Document[] getAll()
  {
    return docs.vals
  }
}

**************************************************************************
** Document
**************************************************************************

**
** Document - Represents an open text document
**
class Document
{
  ** Document URI
  Str uri

  ** Document text content
  Str text

  ** Document version number
  Int version

  new make(Str uri, Str text, Int version)
  {
    this.uri = uri
    this.text = text
    this.version = version
  }

  **
  ** Apply changes to the document
  **
  Void applyChanges(TextDocumentContentChangeEvent[] changes)
  {
    LspProtocol.logInfo("Applying ${changes.size} changes to document $uri")
    LspProtocol.logInfo("Current text length: ${text.size}")
    text = LspUtil.applyChanges(text, changes)
    LspProtocol.logInfo("New text length: ${text.size}")

    // Debug: show lines 5-7 with character codes
    lines := text.splitLines
    if (lines.size > 6)
    {
      LspProtocol.logInfo("  DEBUG Line 5: '${lines[5]}' len=${lines[5].size}")
      LspProtocol.logInfo("  DEBUG Line 6: '${lines[6]}' len=${lines[6].size}")
      if (lines.size > 7)
        LspProtocol.logInfo("  DEBUG Line 7: '${lines[7]}' len=${lines[7].size}")
    }
  }

  **
  ** Get document as URI object
  **
  Uri getUri()
  {
    return Uri.decode(uri)
  }
}
