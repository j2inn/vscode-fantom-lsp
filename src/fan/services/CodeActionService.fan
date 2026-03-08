
**
** CodeActionService - Provides LSP quick-fix code actions.
**
** Currently supports "Add using <podName>" for unknown type names: when the
** user invokes Quick Fix on an identifier, this service searches all pods in
** lib/fan for a public type that matches and returns one code action per
** matching pod.  Accepting the action inserts the appropriate 'using' line.
**
class CodeActionService
{
  **
  ** Return LSP CodeAction objects for inserting a missing 'using' statement.
  **
  ** Searches all pods in lib/fan for a public type matching typeName,
  ** excluding pods that are already imported in the source.
  **
  [Str:Obj?][] suggestUsingFixes(Str typeName, Str source, Str uri)
  {
    result := [Str:Obj?][,]

    pods := findPodsForType(typeName, source)
    if (pods.isEmpty) return result

    insertLine := findUsingInsertLine(source)
    pods.each |podName|
    {
      result.add(buildAddUsingAction(podName, uri, insertLine))
    }

    return result
  }

  **
  ** Find all pods in lib/fan that export a public type with the given simple
  ** name, excluding pods already imported in the source or the 'sys' pod
  ** (which is always implicitly available).
  **
  private Str[] findPodsForType(Str typeName, Str source)
  {
    // Collect already-imported pod names
    imported := Str:Bool[:]
    imported["sys"] = true
    source.splitLines.each |line|
    {
      trimmed := line.trim
      if (!trimmed.startsWith("using ")) return
      if (trimmed.contains("[java]")) return
      rest := trimmed["using ".size..-1].trim
      podName := rest
      colonIdx := rest.index("::")
      if (colonIdx != null) podName = rest[0..<colonIdx]
      spaceIdx := podName.index(" ")
      if (spaceIdx != null) podName = podName[0..<spaceIdx]
      imported[podName] = true
    }

    result := Str[,]
    LspUtil.allPodFiles.each |f|
    {
      podName := f.basename
      if (imported.containsKey(podName)) return
      try
      {
        pod := Pod.find(podName, false)
        if (pod == null) return
        t := pod.type(typeName, false)
        if (t != null && t.isPublic)
          result.add(podName)
      }
      catch (Err e) {}
    }

    return result
  }

  **
  ** Find the 0-based line at which to insert a new 'using' statement.
  ** Returns the line AFTER the last existing 'using' line, or 0 if there
  ** are no using statements yet.
  **
  private Int findUsingInsertLine(Str source)
  {
    lines := source.splitLines
    lastUsing := -1
    lines.each |line, i|
    {
      if (line.trim.startsWith("using "))
        lastUsing = i
    }
    return lastUsing >= 0 ? lastUsing + 1 : 0
  }

  **
  ** Build an LSP CodeAction map that inserts "using <podName>\n" at the
  ** given 0-based line (an empty insert = cursor-at-start-of-line).
  **
  private Str:Obj? buildAddUsingAction(Str podName, Str uri, Int insertLine)
  {
    pos := Str:Obj?["line": insertLine, "character": 0]
    textEdit := Str:Obj?[
      "range": Str:Obj?["start": pos, "end": pos],
      "newText": "using ${podName}\n"
    ]
    changesMap := Str:Obj?[:]
    changesMap[uri] = [textEdit]

    return Str:Obj?[
      "title": "Add 'using ${podName}'",
      "kind": "quickfix",
      "edit": Str:Obj?["changes": changesMap]
    ]
  }
}
