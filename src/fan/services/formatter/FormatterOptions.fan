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
  }

  ** Deep copy
  FormatterOptions copy()
  {
    dst := FormatterOptions()
    dst.indentSize = indentSize
    dst.useTabs = useTabs
    dst.insertFinalNewline = insertFinalNewline
    dst.trimTrailingWhitespace = trimTrailingWhitespace
    dst.maxBlankLines = maxBlankLines
    dst.respectEditorConfig = respectEditorConfig
    return dst
  }
}
