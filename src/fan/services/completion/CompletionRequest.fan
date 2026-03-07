**
** CompletionRequest - Structured input for CompletionService completion.
**
class CompletionRequest
{
  Str uri
  LspPosition pos
  Str source
  ProjectIndex index

  new make(Str uri, LspPosition pos, Str source, ProjectIndex index)
  {
    this.uri = uri
    this.pos = pos
    this.source = source
    this.index = index
  }
}

**
** CompletionRequestBuilder - Builder pattern for CompletionRequest.
**
class CompletionRequestBuilder
{
  private Str? _uri
  private LspPosition? _pos
  private Str? _source
  private ProjectIndex? _index

  This withUri(Str uri)
  {
    this._uri = uri
    return this
  }

  This withPos(LspPosition pos)
  {
    this._pos = pos
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

  CompletionRequest build()
  {
    uri := _uri
    if (uri == null) throw ArgErr("CompletionRequestBuilder: uri is required")

    pos := _pos
    if (pos == null) throw ArgErr("CompletionRequestBuilder: pos is required")

    source := _source
    if (source == null) throw ArgErr("CompletionRequestBuilder: source is required")

    index := _index
    if (index == null) throw ArgErr("CompletionRequestBuilder: index is required")

    return CompletionRequest(uri, pos, source, index)
  }
}
