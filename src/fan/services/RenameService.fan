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

    // Collect every location (declarations + usages) across all files
    locs := [Str:Obj?][,]
    index.allFileSources.each |src, fileUri|
    {
      locs.addAll(scanner.scan(fileUri, src, target, index))
    }

    // Group text edits by file URI
    seenUris := Str:Bool[:]
    locs.each |l| { u := l["uri"] as Str; if (u != null) seenUris[u] = true }

    docChanges := [Str:Obj?][,]
    seenUris.each |_, fileUri|
    {
      edits := [Str:Obj?][,]
      locs.each |l| { if (l["uri"] == fileUri) edits.add(makeEdit(l, newName)) }
      docChanges.add(["textDocument": ["uri": fileUri, "version": null], "edits": edits])
    }

    // For type renames: add file-rename operations for matching single-class files
    if (target.kind == "type")
    {
      index.allFileSources.each |src, fileUri|
      {
        newUri := singleClassFileUri(src, fileUri, target.name, newName)
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
