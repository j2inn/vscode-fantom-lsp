**
** RenameService - Builds a WorkspaceEdit for LSP textDocument/rename.
**
** Reuses ReferencesScanner to locate every occurrence of the target symbol
** (declarations + usages + override declarations) across all project files.
** For type renames, also emits a RenameFile operation when the file is named
** after the single class it contains.
**
class RenameService
{
  private ReferencesScanner scanner := ReferencesScanner()

  **
  ** Compute the WorkspaceEdit for renaming the symbol at pos to newName.
  ** Returns null when no renameable symbol is found at the cursor.
  **
  [Str:Obj?]? rename(Str uri, LspPosition pos, Str source,
                     Str newName, ProjectIndex index)
  {
    target := ReferencesTarget.resolve(uri, pos, source, index)
    if (target == null) return null

    // Collect every location (declarations + usages) across all files.
    // Use the caller-supplied source for the active file so that rename
    // works correctly on unsaved buffers whose index may be stale.
    locs := [Str:Obj?][,]
    index.allFileSources.each |src, fileUri|
    {
      fileSrc := fileUri == uri ? source : src
      locs.addAll(scanner.scan(fileUri, fileSrc, target, index))
    }

    // Group text edits by file URI, sorted bottom-to-top so VS Code applies
    // them without offset shift between successive edits in the same document.
    seenUris := Str:Bool[:]
    locs.each |l| { u := l["uri"] as Str; if (u != null) seenUris[u] = true }

    docChanges := [Str:Obj?][,]
    seenUris.each |_, fileUri|
    {
      edits := [Str:Obj?][,]
      locs.each |l| { if (l["uri"] == fileUri) edits.add(makeEdit(l, newName)) }
      edits = sortEditsDescending(edits)
      docChanges.add(["textDocument": ["uri": fileUri, "version": null], "edits": edits])
    }

    // For type renames: add file-rename operations for matching single-class files
    if (target.kind == "type")
    {
      index.allFileSources.each |src, fileUri|
      {
        fileSrc := fileUri == uri ? source : src
        newUri := singleClassFileUri(fileSrc, fileUri, target.name, newName)
        if (newUri != null)
          docChanges.add(["kind": "rename", "oldUri": fileUri, "newUri": newUri])
      }
    }

    return ["documentChanges": docChanges]
  }

  **
  ** Return the range + placeholder for the symbol at pos (prepareRename).
  ** Returns null when no identifier is at the cursor.
  **
  [Str:Obj?]? prepareRename(Str uri, LspPosition pos, Str source)
  {
    word := LspUtil.getWordAtPosition(source, pos)
    if (word == null || word.isEmpty) return null
    line := LspUtil.getLine(source, pos.line)
    if (line == null) return null
    start := pos.character
    while (start > 0 && LspUtil.isIdentifierChar(line[start - 1])) start--
    return [
      "range": [
        "start": ["line": pos.line, "character": start],
        "end":   ["line": pos.line, "character": start + word.size]
      ],
      "placeholder": word
    ]
  }

  // ---------------------------------------------------------------------------

  private [Str:Obj?] makeEdit([Str:Obj?] loc, Str newName)
  {
    return ["range": loc["range"], "newText": newName]
  }

  ** Sort edits in reverse document order (bottom-to-top, right-to-left).
  ** The LSP spec requires edits within a TextDocumentEdit to be applied
  ** without overlapping; providing them in descending position order
  ** ensures each edit's range refers to the original document positions
  ** and no earlier edit can shift a later edit's character offset.
  private [Str:Obj?][] sortEditsDescending([Str:Obj?][] edits)
  {
    sorted := edits.dup
    sorted.sort |a, b|
    {
      aLine := editStartLine(a); bLine := editStartLine(b)
      aChar := editStartChar(a); bChar := editStartChar(b)
      if (bLine != aLine) return bLine <=> aLine
      return bChar <=> aChar
    }
    return sorted
  }

  private Int editStartLine([Str:Obj?] edit)
  {
    r := edit["range"] as Str:Obj?
    if (r == null) return 0
    s := r["start"] as Str:Obj?
    if (s == null) return 0
    v := s["line"] as Int
    return v ?: 0
  }

  private Int editStartChar([Str:Obj?] edit)
  {
    r := edit["range"] as Str:Obj?
    if (r == null) return 0
    s := r["start"] as Str:Obj?
    if (s == null) return 0
    v := s["character"] as Int
    return v ?: 0
  }

  **
  ** If source contains exactly one class/mixin named oldName and the file is
  ** named OldName.fan, return the new URI with newName.fan; else null.
  **
  private Str? singleClassFileUri(Str source, Str fileUri,
                                  Str oldName, Str newName)
  {
    classes := Str[,]
    source.splitLines.each |line|
    {
      trimmed := line.trim
      Str? kw := null
      if (trimmed.startsWith("class ")) kw = "class "
      else if (trimmed.startsWith("mixin ")) kw = "mixin "
      if (kw == null) return
      rest := trimmed[kw.size..-1].trim
      end := 0
      while (end < rest.size && LspUtil.isIdentifierChar(rest[end])) end++
      if (end > 0) classes.add(rest[0..<end])
    }
    if (classes.size != 1 || classes[0] != oldName) return null

    slashIdx := fileUri.indexr("/")
    if (slashIdx == null) return null
    dir   := fileUri[0..slashIdx]
    fname := fileUri[slashIdx + 1 ..-1]
    if (fname != oldName + ".fan") return null
    return dir + newName + ".fan"
  }
}
