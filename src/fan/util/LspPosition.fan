
using compiler

**
** Position conversion utilities between LSP (0-based) and Fantom (1-based)
**
class LspUtil
{
  **
  ** Convert a File to a proper file:// URI string.
  ** On Windows, osPath uses backslashes (C:\Users\...) but URIs need
  ** forward slashes (file:///C:/Users/...). Also normalizes the drive
  ** letter to lowercase to match VSCode's convention.
  **
  static Str fileToUri(File f)
  {
    // Use Fantom's URI which always uses forward slashes
    path := f.uri.toStr

    // Fantom file URIs are already in file:/ format
    // but we need file:// (or file:/// on Windows with drive letter)
    if (path.startsWith("file:/"))
    {
      // Normalize: file:/ -> file://, file:// stays, file:/// stays
      afterScheme := path["file:/".size ..-1]
      // Strip leading slashes to get the path
      while (afterScheme.startsWith("/")) afterScheme = afterScheme[1..-1]

      // On Windows, path starts with drive letter (C:/...)
      // On Unix, path starts with directory name
      hasDrive := afterScheme.size >= 2 && afterScheme[1] == ':'
      if (hasDrive)
      {
        // Lowercase the drive letter to match VSCode
        drive := afterScheme[0].lower.toChar
        return "file:///${drive}${afterScheme[1..-1]}"
      }
      else
      {
        return "file:///${afterScheme}"
      }
    }

    // Fallback: construct from osPath
    osPath := f.osPath
    // Replace backslashes with forward slashes (Windows)
    normalized := osPath.replace("\\", "/")
    // Ensure it starts with /
    if (!normalized.startsWith("/"))
    {
      // Windows absolute path: C:/... -> lowercase drive
      if (normalized.size >= 2 && normalized[1] == ':')
      {
        drive := normalized[0].lower.toChar
        normalized = "/${drive}${normalized[1..-1]}"
      }
      else
        normalized = "/${normalized}"
    }
    return "file://${normalized}"
  }

  **
  ** Normalize a file URI for comparison. Ensures consistent format:
  ** forward slashes, lowercase drive letter on Windows.
  **
  static Str normalizeFileUri(Str uri)
  {
    if (!uri.startsWith("file://")) return uri

    // Replace backslashes
    normalized := uri.replace("\\", "/")

    // Decode percent-encoded colons in drive letters (e.g., c%3A -> c:)
    // VSCode on Windows may send file:///c%3A/Users/... or file:///C%3a/Users/...
    normalized = normalized.replace("%3A", ":").replace("%3a", ":")

    // Normalize file:/// prefix
    afterScheme := normalized["file://".size ..-1]
    while (afterScheme.startsWith("/")) afterScheme = afterScheme[1..-1]

    // Lowercase drive letter if present
    if (afterScheme.size >= 2 && afterScheme[1] == ':')
    {
      drive := afterScheme[0].lower.toChar
      return "file:///${drive}${afterScheme[1..-1]}"
    }
    return "file:///${afterScheme}"
  }

  **
  ** Convert a file:// URI string to a Fantom File.
  ** Normalizes the URI first to handle Windows drive letters and backslashes.
  **
  ** Uses File.os(osPath) rather than File(Uri.decode(uri)) to avoid a Java
  ** issue on Windows where new java.io.File("/c:/foo") creates a path at
  ** the wrong location — the leading "/" before a drive letter is treated
  ** as the current-drive root, producing "C:\c:\foo" instead of "C:\foo".
  **
  static File uriToFile(Str uri)
  {
    normalized := normalizeFileUri(uri)

    // Decode the normalized URI and extract its path component.
    // Uri.decode() handles percent-encoded characters (e.g. %20 → space).
    // pathStr returns "/c:/Users/foo" (Windows) or "/home/foo" (Unix).
    // Strip all leading slashes → "c:/Users/foo" or "home/foo".
    afterScheme := Uri.decode(normalized).pathStr
    while (afterScheme.startsWith("/")) afterScheme = afterScheme[1..-1]

    // Reconstruct the OS-native path and create the File via File.os()
    if (afterScheme.size >= 2 && afterScheme[1] == ':')
    {
      // Windows drive path: "c:/Users/foo" is a valid java.io.File path
      return File.os(afterScheme)
    }
    else
    {
      // Unix absolute path: restore the leading slash stripped above
      return File.os("/" + afterScheme)
    }
  }

  **
  ** Convert an OS path string (e.g. from build output) to a file:// URI.
  ** Handles Windows backslashes, drive letters, and Unix paths.
  **
  static Str pathToFileUri(Str osPath)
  {
    normalized := osPath.replace("\\", "/")
    if (!normalized.startsWith("/"))
    {
      if (normalized.size >= 2 && normalized[1] == ':')
      {
        drive := normalized[0].lower.toChar
        normalized = "/${drive}${normalized[1..-1]}"
      }
      else
        normalized = "/${normalized}"
    }
    return "file://${normalized}"
  }

  **
  ** Cross-platform temp directory. Uses Fantom's Env.cur.tempDir
  ** instead of hardcoded /tmp/ which doesn't exist on Windows.
  **
  static File tempDir()
  {
    return Env.cur.tempDir
  }

  **
  ** Convert Fantom Loc to LSP Range
  ** Fantom uses 1-based line/col, LSP uses 0-based
  **
  static LspRange locToRange(Loc loc)
  {
    // Fantom line/col is 1-based, LSP is 0-based
    line := (loc.line ?: 1) - 1
    col := (loc.col ?: 1) - 1

    // For now, create a single-character range
    // In a more sophisticated implementation, we'd calculate token length
    start := LspPosition(line, col)
    end := LspPosition(line, col + 1)

    return LspRange(start, end)
  }

  **
  ** Convert LSP Position to Fantom Loc
  ** LSP uses 0-based line/col, Fantom uses 1-based
  **
  static Loc positionToLoc(Str file, LspPosition pos)
  {
    // LSP is 0-based, Fantom is 1-based
    return Loc(file, pos.line + 1, pos.character + 1)
  }

  **
  ** Convert LSP Range to Fantom Loc (using start position)
  **
  static Loc rangeToLoc(Str file, LspRange range)
  {
    return positionToLoc(file, range.start)
  }

  **
  ** Apply text document changes to source text
  ** Handles both full and incremental sync
  **
  static Str applyChanges(Str text, TextDocumentContentChangeEvent[] changes)
  {
    LspProtocol.logInfo("applyChanges: processing ${changes.size} changes")

    // If any change has no range, it's a full document sync
    fullChange := changes.find |c| { c.range == null }
    if (fullChange != null)
    {
      LspProtocol.logInfo("Full document sync, new text: '${fullChange.text}'")
      return fullChange.text
    }

    // Apply incremental changes
    // For now, we'll use full document sync for simplicity
    // A full implementation would apply each change to its range
    result := text
    changes.each |TextDocumentContentChangeEvent change|
    {
      LspProtocol.logInfo("Change: range=${change.range}, text='${change.text}'")
      if (change.range == null)
      {
        result = change.text
      }
      else
      {
        // For now, just replace entire document
        // TODO: Implement proper incremental sync with ranges
        result = change.text
      }
    }
    LspProtocol.logInfo("applyChanges: final text='$result'")
    return result
  }

  **
  ** Get line from text at given line number (0-based)
  **
  static Str? getLine(Str text, Int lineNum)
  {
    LspProtocol.logInfo("start getLine")
    lines := text.splitLines
    LspProtocol.logInfo(lines.toStr)
    result := lineNum < lines.size ? lines[lineNum] : null
    LspProtocol.logInfo("getLine: lineNum=$lineNum, total lines=${lines.size}, result='$result', result.size=${result?.size}")

    // Debug: show all lines around the target
    if (result != null && lineNum > 0 && lineNum < lines.size)
    {
      LspProtocol.logInfo("  Line ${lineNum-1}: '${lines[lineNum-1]}'")
      LspProtocol.logInfo("  Line ${lineNum}: '$result' (requested)")
      if (lineNum + 1 < lines.size)
        LspProtocol.logInfo("  Line ${lineNum+1}: '${lines[lineNum+1]}'")
    }
    LspProtocol.logInfo("END getLine")
    return result
  }

  **
  ** Get word at position in text
  ** Returns the identifier at the given position
  **
  static Str? getWordAtPosition(Str text, LspPosition pos)
  {
    line := getLine(text, pos.line)
    if (line == null) return null
    // Find start of word (go backwards from position)
    start := pos.character
    LspProtocol.logInfo("getWordAtPosition line=${line}, start=${start}")
    while (start > 0 && isIdentifierChar(line[start - 1]))
      start--

    // Find end of word (go forwards from position)
    end := pos.character
    while (end < line.size && isIdentifierChar(line[end]))
      end++

    // Return the word
    return start < end ? line[start..<end] : null
  }

  **
  ** Check if character is valid in an identifier
  **
  static Bool isIdentifierChar(Int ch)
  {
    return ch.isAlphaNum || ch == '_'
  }

  **
  ** Return all .pod files visible to the current Fantom environment.
  ** Searches every directory in Env.cur.path when available (Fantom ≥ 1.0.79),
  ** otherwise falls back to Env.cur.homeDir only.
  ** Duplicates (same basename in multiple path entries) are de-duplicated
  ** so that the first path entry wins, matching Fantom's own pod resolution.
  **
  static File[] allPodFiles()
  {
    result := File[,]
    seen   := Str:Bool[:]
    fanPath(Env.cur).each |dir|
    {
      libFan := dir + `lib/fan/`
      if (!libFan.exists) return
      libFan.list.each |f|
      {
        if (f.ext == "pod" && !seen.containsKey(f.basename))
        {
          seen[f.basename] = true
          result.add(f)
        }
      }
    }
    return result
  }

  **
  ** Return the Fantom environment search path.
  ** Env.path() was added in a later Fantom version; we call it via reflection
  ** so that the code compiles and runs on older runtimes (falls back to
  ** [homeDir] when the method is not present).
  **
  static File[] fanPath(Env env)
  {
    try
    {
      method := Env#.method("path", false)
      if (method != null)
        return method.callOn(env, [,])
      return [env.homeDir]
    }
    catch (Err e) { return [env.homeDir] }
  }
}
