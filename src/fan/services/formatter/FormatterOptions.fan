**
** FormatterOptions - configuration for the Fantom source formatter.
**
class FormatterOptions
{
  ** Number of spaces per indent level (used when useTabs is false)
  Int indentSize := 2

  ** Use tab characters for indentation instead of spaces
  Bool useTabs := false

  ** Insert a trailing newline at the end of the file
  Bool insertFinalNewline := true

  ** Trim trailing whitespace from each line
  Bool trimTrailingWhitespace := true

  ** Maximum consecutive blank lines to preserve (0 = keep all)
  Int maxBlankLines := 1

  ** Whether to override these settings with values from .editorconfig files
  Bool respectEditorConfig := true

  **
  ** Collapse runs of two or more spaces into a single space in code regions
  ** (outside string literals and // comments).
  ** Default: true.
  **
  Bool collapseSpaces := true

  **
  ** Maximum line length before the formatter wraps long lines.
  ** Wrapping splits at: commas inside parentheses, '&&', '||', or ternary '?'.
  ** Set to 0 to disable wrapping entirely.
  ** Default: 100.
  **
  Int maxLineLength := 100

  ** Merge overrides from a Str:Obj? map (e.g. from initializationOptions)
  Void mergeMap(Str:Obj? map)
  {
    v := map["indentSize"]
    if (v is Int) indentSize = (Int)v
    v = map["useTabs"]
    if (v is Bool) useTabs = (Bool)v
    v = map["insertFinalNewline"]
    if (v is Bool) insertFinalNewline = (Bool)v
    v = map["trimTrailingWhitespace"]
    if (v is Bool) trimTrailingWhitespace = (Bool)v
    v = map["maxBlankLines"]
    if (v is Int) maxBlankLines = (Int)v
    v = map["respectEditorConfig"]
    if (v is Bool) respectEditorConfig = (Bool)v
    v = map["collapseSpaces"]
    if (v is Bool) collapseSpaces = (Bool)v
    v = map["maxLineLength"]
    if (v is Int) maxLineLength = (Int)v
  }

  ** Deep copy
  FormatterOptions copy()
  {
    dst := FormatterOptions()
    dst.indentSize             = indentSize
    dst.useTabs                = useTabs
    dst.insertFinalNewline     = insertFinalNewline
    dst.trimTrailingWhitespace = trimTrailingWhitespace
    dst.maxBlankLines          = maxBlankLines
    dst.respectEditorConfig    = respectEditorConfig
    dst.collapseSpaces         = collapseSpaces
    dst.maxLineLength          = maxLineLength
    return dst
  }
}
