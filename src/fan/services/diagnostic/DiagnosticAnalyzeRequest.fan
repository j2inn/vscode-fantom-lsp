**
** DiagnosticAnalyzeRequest - Structured input for DiagnosticService analysis.
**
class DiagnosticAnalyzeRequest
{
  Str uri
  Str source
  ProjectIndex index
  Bool pedanticMode
  Bool enableUnusedImport

  new make(Str uri, Str source, ProjectIndex index, Bool pedanticMode := false, Bool enableUnusedImport := true)
  {
    this.uri = uri
    this.source = source
    this.index = index
    this.pedanticMode = pedanticMode
    this.enableUnusedImport = enableUnusedImport
  }
}

**
** DiagnosticAnalyzeRequestBuilder - Builder pattern for DiagnosticAnalyzeRequest.
**
class DiagnosticAnalyzeRequestBuilder
{
  private Str? _uri
  private Str? _source
  private ProjectIndex? _index
  private Bool _pedanticMode := false
  private Bool _enableUnusedImport := true

  This withUri(Str uri)
  {
    this._uri = uri
    return this
  }

  This withSource(Str source)
  {
    this._source = source
    return this
  }

  This withIndex(ProjectIndex index)
  {
    this._index = index
    return this
  }

  This withPedanticMode(Bool pedanticMode := true)
  {
    this._pedanticMode = pedanticMode
    return this
  }

  This withEnableUnusedImport(Bool enableUnusedImport := true)
  {
    this._enableUnusedImport = enableUnusedImport
    return this
  }

  DiagnosticAnalyzeRequest build()
  {
    uri := _uri
    if (uri == null) throw ArgErr("DiagnosticAnalyzeRequestBuilder: uri is required")

    source := _source
    if (source == null) throw ArgErr("DiagnosticAnalyzeRequestBuilder: source is required")

    index := _index
    if (index == null) throw ArgErr("DiagnosticAnalyzeRequestBuilder: index is required")

    return DiagnosticAnalyzeRequest(uri, source, index, _pedanticMode, _enableUnusedImport)
  }
}
