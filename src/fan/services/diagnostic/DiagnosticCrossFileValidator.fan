**
** DiagnosticCrossFileValidator - Validates cross-file type.member references.
**
class DiagnosticCrossFileValidator
{
  ** Built-in slots inherited from Obj/Enum that types commonly have
  private static const Str[] builtinSlots := [
    "make", "typeof", "toStr", "hash", "equals",
    "compare", "with", "trap", "isImmutable", "toImmutable",
    "type", "fromStr", "defVal"
  ]

  ** Slots that only enum types inherit (compiler-generated)
  private static const Str[] enumBuiltinSlots := [
    "vals", "fromStr", "name", "ordinal"
  ]

  private Bool isBuiltinSlot(Str name) { builtinSlots.contains(name) }

  private Bool isEnumBuiltinSlot(Str name) { enumBuiltinSlots.contains(name) }

  **
  ** Validate cross-file references: check that ProjectType.member patterns
  ** reference members that actually exist in the project index.
  **
  LspDiagnostic[] validateCrossFileReferences(Str source, ProjectIndex index)
  {
    diagnostics := LspDiagnostic[,]
    lines := source.splitLines

    for (i := 0; i < lines.size; i++)
    {
      line := lines[i]
      trimmed := line.trim

      // Skip comment lines
      if (trimmed.startsWith("//") || trimmed.startsWith("**")) continue
      // Skip import lines
      if (trimmed.startsWith("using ")) continue
      // Skip class/mixin declaration lines (inheritance handled elsewhere)
      if (trimmed.startsWith("class ") || trimmed.startsWith("mixin ")) continue

      // Scan for TypeName.memberName patterns
      pos := 0
      while (pos < line.size)
      {
        // Skip string literals
        if (line[pos] == '"')
        {
          pos++
          while (pos < line.size && line[pos] != '"')
          {
            if (line[pos] == '\\') pos++  // skip escaped char
            pos++
          }
          pos++
          continue
        }

        // Skip Uri literals (backtick-delimited strings)
        if (line[pos] == '`')
        {
          pos++
          while (pos < line.size && line[pos] != '`')
          {
            if (line[pos] == '\\') pos++
            pos++
          }
          pos++
          continue
        }

        // Skip single-line comments
        if (pos + 1 < line.size && line[pos] == '/' && line[pos + 1] == '/')
          break

        // Look for an uppercase letter that could start a type name
        if (line[pos].isUpper)
        {
          // Extract the identifier
          nameStart := pos
          while (pos < line.size && (line[pos].isAlphaNum || line[pos] == '_'))
            pos++
          typeName := line[nameStart ..< pos]

          // Must be followed by a dot
          if (pos < line.size && line[pos] == '.')
          {
            pos++

            // Must be followed by an identifier (member name)
            if (pos < line.size && (line[pos].isAlpha || line[pos] == '_'))
            {
              memberStart := pos
              while (pos < line.size && (line[pos].isAlphaNum || line[pos] == '_'))
                pos++
              memberName := line[memberStart ..< pos]

              // Check: is typeName a project type with the member missing?
              if (index.hasType(typeName) && !index.hasMember(typeName, memberName))
              {
                if (!isBuiltinSlot(memberName) &&
                    !(index.isEnumType(typeName) && isEnumBuiltinSlot(memberName)))
                {
                  // Check if the member might be inherited from a project base type
                  baseTypes := index.getBaseTypeChain(typeName)
                  memberInherited := baseTypes.any |bt| { index.hasMember(bt, memberName) }

                  // If not found in project base types, check if there's an external
                  // base type that could provide the member (we can't verify those)
                  if (!memberInherited)
                  {
                    externalBase := index.findResolvableBaseType(typeName)
                    if (externalBase != null) memberInherited = true
                  }

                  if (!memberInherited)
                  {
                    col := nameStart
                    range := LspRange(
                      LspPosition(i, col),
                      LspPosition(i, col + typeName.size + 1 + memberName.size)
                    )
                    diagnostics.add(LspDiagnostic(range, DiagnosticSeverity.error,
                      "'${memberName}' is not a member of '${typeName}'", "fantom"))
                  }
                }
              }
            }
          }
          continue
        }
        pos++
      }
    }
    return diagnostics
  }
}
