**
** ProjectIndexInitRequest - Immutable input for ProjectIndex init.
**
const class ProjectIndexInitRequest
{
  const Str workspaceRootUri

  new make(Str workspaceRootUri)
  {
    this.workspaceRootUri = workspaceRootUri
  }
}

**
** ProjectIndexInitRequestBuilder - Builder pattern for ProjectIndexInitRequest.
**
class ProjectIndexInitRequestBuilder
{
  private Str? _workspaceRootUri

  This withWorkspaceRootUri(Str workspaceRootUri)
  {
    this._workspaceRootUri = workspaceRootUri
    return this
  }

  ProjectIndexInitRequest build()
  {
    workspaceRootUri := _workspaceRootUri
    if (workspaceRootUri == null)
      throw ArgErr("ProjectIndexInitRequestBuilder: workspaceRootUri is required")

    return ProjectIndexInitRequest(workspaceRootUri)
  }
}
