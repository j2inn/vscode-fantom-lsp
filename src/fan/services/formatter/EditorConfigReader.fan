**
** EditorConfigReader - reads .editorconfig files and applies matched
** properties to FormatterOptions.
**
** Walks up the directory tree from a given file to the workspace root,
** collecting rules from each .editorconfig found (outermost files applied
** first so closer files override).  Stops ascending at the first file
** that declares "root = true".
**
class EditorConfigReader
{
  **
  ** Return a copy of 'base' with .editorconfig properties applied
  ** for the given file URI.  Returns 'base' unchanged if no
  ** .editorconfig is found or if an error occurs.
  **
  FormatterOptions apply(Str fileUri, Str? workspaceRootUri, FormatterOptions base)
  {
    try
    {
      filePath := uriToFile(fileUri)
      if (filePath == null) return base

      rootPath := workspaceRootUri != null ? uriToFile(workspaceRootUri) : null

      // Walk upward from file's directory, collecting .editorconfig files.
      // We insert at position 0 so the list ends up outermost-first.
      configs := File[,]
      isRoot := false
      dir := filePath.parent
      while (dir != null && !isRoot)
      {
        candidate := dir + `.editorconfig`
        if (candidate.exists)
        {
          configs.insert(0, candidate)
          isRoot = checkIsRoot(candidate)
        }
        if (rootPath != null && dir.osPath == rootPath.osPath) break
        parent := dir.parent
        if (parent == null || parent.osPath == dir.osPath) break
        dir = parent
      }

      if (configs.isEmpty) return base

      result := base.copy
      relPath := filePath.osPath.replace("\\", "/")

      configs.each |cfg| { parseConfig(cfg, relPath, result) }
      return result
    }
    catch (Err e)
    {
      return base
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  ** Check if an .editorconfig file declares root = true (without fully parsing it)
  private Bool checkIsRoot(File cfg)
  {
    found := false
    try
    {
      cfg.eachLine |line|
      {
        t := line.trim.lower
        if (t == "root = true" || t == "root=true") found = true
      }
    }
    catch (Err e) {}
    return found
  }

  ** Parse one .editorconfig file and apply matching-section properties to opts
  private Void parseConfig(File cfg, Str relPath, FormatterOptions opts)
  {
    currentSection := ""
    matches := false

    cfg.eachLine |line|
    {
      t := line.trim
      if (t.isEmpty || t.startsWith("#") || t.startsWith(";")) return

      // root declaration (already handled) – skip
      tl := t.lower
      if (tl == "root = true" || tl == "root=true") return

      // Section header [pattern]
      if (t.startsWith("[") && t.endsWith("]"))
      {
        currentSection = t[1..<t.size-1]
        matches = sectionMatches(currentSection, relPath)
        return
      }

      if (!matches) return

      // key = value
      eq := t.index("=")
      if (eq == null) return
      key := t[0..<eq].trim.lower
      val := t[eq+1..-1].trim.lower

      applyProperty(key, val, opts)
    }
  }

  ** Apply a single editorconfig property to opts
  private Void applyProperty(Str key, Str val, FormatterOptions opts)
  {
    switch (key)
    {
      case "indent_style":
        if (val == "tab")   opts.useTabs = true
        else if (val == "space") opts.useTabs = false

      case "indent_size":
        if (val == "tab") opts.useTabs = true
        else { n := Int.fromStr(val, 10, false); if (n != null && n > 0) opts.indentSize = n }

      case "tab_width":
        n := Int.fromStr(val, 10, false)
        if (n != null && n > 0 && !opts.useTabs) opts.indentSize = n

      case "trim_trailing_whitespace":
        if (val == "true")  opts.trimTrailingWhitespace = true
        else if (val == "false") opts.trimTrailingWhitespace = false

      case "insert_final_newline":
        if (val == "true")  opts.insertFinalNewline = true
        else if (val == "false") opts.insertFinalNewline = false

      case "max_blank_lines":
        n := Int.fromStr(val, 10, false)
        if (n != null && n >= 0) opts.maxBlankLines = n
    }
  }

  ** Return true if the editorconfig section pattern matches the given file path
  private Bool sectionMatches(Str pattern, Str filePath)
  {
    // Expand {a,b} alternatives
    if (pattern.contains("{") && pattern.contains("}"))
    {
      expanded := expandBraces(pattern)
      return expanded.any |p| { matchPattern(p, filePath) }
    }
    return matchPattern(pattern, filePath)
  }

  ** Expand {a,b,c} brace alternatives into a list of patterns
  private Str[] expandBraces(Str pattern)
  {
    s := pattern.index("{")
    e := pattern.index("}")
    if (s == null || e == null || e < s) return [pattern]
    pre  := pattern[0..<s]
    post := pattern[e+1..-1]
    inner := pattern[s+1..<e]
    result := Str[,]
    inner.split(',').each |alt| { result.add(pre + alt.trim + post) }
    return result
  }

  ** Match one (already expanded) glob pattern against a file path
  private Bool matchPattern(Str pattern, Str path)
  {
    // Patterns without a slash match only the filename
    if (!pattern.contains("/") && !pattern.startsWith("**"))
    {
      slash := path.indexr("/")
      filename := slash != null ? path[slash+1..-1] : path
      return fnmatch(pattern.chars, 0, filename.chars, 0)
    }
    return fnmatch(pattern.chars, 0, path.chars, 0)
  }

  **
  ** Recursive glob match.
  ** pat / str are Int[] (Fantom char arrays).
  ** Supports * (any chars except /), ** (any chars including /), ? (one char).
  **
  private Bool fnmatch(Int[] pat, Int pi, Int[] str, Int si)
  {
    while (pi < pat.size)
    {
      pc := pat[pi]

      if (pc == '*')
      {
        doubleStar := (pi + 1 < pat.size && pat[pi+1] == '*')
        if (doubleStar)
        {
          pi += 2
          // Skip optional path separator after **
          if (pi < pat.size && pat[pi] == '/') pi++
          if (pi >= pat.size) return true
          for (i := si; i <= str.size; i++)
            if (fnmatch(pat, pi, str, i)) return true
          return false
        }
        else
        {
          pi++
          if (pi >= pat.size)
          {
            // * at end: must not span a /
            for (i := si; i < str.size; i++)
              if (str[i] == '/') return false
            return true
          }
          for (i := si; i <= str.size; i++)
          {
            // * cannot match /
            if (i > si && str[i-1] == '/') break
            if (fnmatch(pat, pi, str, i)) return true
          }
          return false
        }
      }
      else if (pc == '?')
      {
        if (si >= str.size || str[si] == '/') return false
        pi++; si++
      }
      else
      {
        if (si >= str.size || str[si] != pc) return false
        pi++; si++
      }
    }
    return si == str.size
  }

  ** Convert file URI to File, or return null on error
  private File? uriToFile(Str uri)
  {
    try
    {
      Str? path := null
      if (uri.startsWith("file:///")) path = uri[7..-1]
      else if (uri.startsWith("file://")) path = uri[6..-1]
      else path = uri
      return File.os(path)
    }
    catch (Err e) { return null }
  }
}
