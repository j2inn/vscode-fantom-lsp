
**
** Default implementation of IFanFileAnalyzer.
**
** Extracts type declarations, slot declarations, and type/slot references
** from a .fan source file using line-by-line heuristic pattern matching.
**
** Identifies:
**   - class/mixin declarations with their line ranges
**   - method/field (slot) declarations with their line ranges
**   - "TypeName" references (uppercase identifiers)
**   - "TypeName.slotName" call patterns
**   - test classes (extend Test or have Void testXxx() methods)
**
internal class TiFanFileAnalyzer : IFanFileAnalyzer
{
  override FanFileInfo analyzeFile(File f)
  {
    lines := f.readAllStr.splitLines

    definedTypes          := Str[,]
    testTypes             := Str[,]
    Str:Bool referencedSet    := [:]
    Str:Bool currentTypeIsTest := [:]
    Str:Bool typeSlotRefSet   := [:]
    Str:Int[] typeLineRanges  := [:]
    Str:Int[] slotLineRanges  := [:]

    Str? currentType      := null
    Str? currentSlot      := null
    Int  currentTypeStart := 1
    Int  currentSlotStart := 1

    for (i := 0; i < lines.size; i++)
    {
      lineNo  := i + 1
      line    := lines[i]
      trimmed := line.trim
      if (trimmed.isEmpty || trimmed.startsWith("//") || trimmed.startsWith("**")) continue

      // Non-indented line may be a new top-level type declaration
      if (line.size > 0 && !line[0].isSpace)
      {
        typeName := matchTypeDecl(trimmed)
        if (typeName != null)
        {
          // Close current slot range
          if (currentType != null && currentSlot != null)
          {
            slotLineRanges[currentType + "." + currentSlot] = [currentSlotStart, lineNo - 1]
            currentSlot = null
          }
          // Close current type range
          if (currentType != null)
            typeLineRanges[currentType] = [currentTypeStart, lineNo - 1]

          definedTypes.add(typeName)
          currentType      = typeName
          currentTypeStart = lineNo
          currentSlot      = null
          if (extendsTest(trimmed))
            currentTypeIsTest[typeName] = true
        }
      }
      else if (currentType != null)
      {
        if (hasTestMethod(trimmed))
          currentTypeIsTest[currentType] = true

        slotName := matchSlotDecl(line, trimmed)
        if (slotName != null)
        {
          if (currentSlot != null)
            slotLineRanges[currentType + "." + currentSlot] = [currentSlotStart, lineNo - 1]
          currentSlot      = slotName
          currentSlotStart = lineNo
        }
      }

      extractUppercaseIdents(line).each |ident| { referencedSet[ident] = true }
      extractTypeSlotRefs(line).each |ref| { typeSlotRefSet[ref] = true }
    }

    // Close trailing ranges
    lastLine := lines.size
    if (currentType != null)
    {
      if (currentSlot != null)
        slotLineRanges[currentType + "." + currentSlot] = [currentSlotStart, lastLine]
      typeLineRanges[currentType] = [currentTypeStart, lastLine]
    }

    currentTypeIsTest.keys.each |t| { testTypes.add(t) }
    definedTypes.each |t| { referencedSet.remove(t) }

    return FanFileInfo(f, definedTypes, testTypes, referencedSet.keys,
                       typeSlotRefSet.keys, typeLineRanges, slotLineRanges)
  }

  // ---- Type-declaration matching ----

  private static Str? matchTypeDecl(Str trimmed)
  {
    keywords := ["class ", "mixin "]
    for (i := 0; i < keywords.size; i++)
    {
      idx := trimmed.index(keywords[i])
      if (idx == null) continue
      afterKeyword := trimmed[idx + keywords[i].size..-1].trim
      name := extractIdentifier(afterKeyword)
      if (name != null && name.size > 0 && name[0].isUpper)
        return name
    }
    return null
  }

  private static Bool extendsTest(Str trimmed)
  {
    return trimmed.contains(": Test")     ||
           trimmed.contains(":Test")      ||
           trimmed.contains(": sys::Test")
  }

  // ---- Test-method detection ----

  private static Bool hasTestMethod(Str trimmed)
  {
    // Match "Void testXxx(" where Xxx starts with uppercase
    idx := trimmed.index("Void test")
    if (idx == null) return false
    after := idx + 9  // len("Void test") == 9
    return after < trimmed.size && trimmed[after].isUpper
  }

  // ---- Slot-declaration matching ----

  **
  ** Match a slot (method/field) declaration inside a type body.
  ** Returns the slot name or null.
  ** Uses a heuristic: indented by exactly 2 or 4 spaces + ReturnType name(... pattern.
  **
  private static Str? matchSlotDecl(Str line, Str trimmed)
  {
    if (line.size < 2 || !line[0].isSpace) return null

    indent := 0
    while (indent < line.size && line[indent] == ' ') indent++
    if (indent != 2 && indent != 4) return null

    // Strip access modifiers
    modifiers := ["override ", "static ", "abstract ", "virtual ", "native ",
                  "private ", "protected ", "internal ", "once ", "readonly "]
    work    := trimmed
    changed := true
    while (changed)
    {
      changed = false
      modifiers.each |mod|
      {
        if (work.startsWith(mod)) { work = work[mod.size..-1].trim; changed = true }
      }
    }

    spIdx := work.index(" ")
    if (spIdx == null) return null
    returnType := work[0..<spIdx]
    if (returnType.size < 1) return null

    rest     := work[spIdx + 1..-1].trim
    parenIdx := rest.index("(")
    eqIdx    := rest.index(" ")

    Str? name := null
    if (parenIdx != null)      name = rest[0..<parenIdx].trim
    else if (eqIdx != null)    name = rest[0..<eqIdx].trim
    else                       name = rest.trim

    if (name == null || name.isEmpty) return null
    if (!name[0].isAlpha) return null

    // Validate identifier characters
    valid := true
    name.each |c| { if (!c.isAlphaNum && c != '_') valid = false }
    if (!valid || name.size < 2) return null
    return name
  }

  // ---- Reference extraction ----

  **
  ** Extract "TypeName.slotName" call patterns from a line.
  ** E.g. "Foo.bar" is extracted as the string "Foo.bar".
  **
  private static Str[] extractTypeSlotRefs(Str line)
  {
    result := Str[,]
    i := 0
    while (i < line.size)
    {
      c := line[i]
      if (c == '"')
      {
        i++
        while (i < line.size && line[i] != '"') i++
        i++
        continue
      }
      if (c == '/' && i + 1 < line.size && line[i+1] == '/') break

      if (c.isUpper)
      {
        end := i + 1
        while (end < line.size && (line[end].isAlphaNum || line[end] == '_')) end++
        typeName := line[i..<end]
        if (end < line.size && line[end] == '.')
        {
          slotStart := end + 1
          slotEnd   := slotStart
          while (slotEnd < line.size && (line[slotEnd].isAlphaNum || line[slotEnd] == '_')) slotEnd++
          if (slotEnd > slotStart)
          {
            slotName := line[slotStart..<slotEnd]
            if (typeName.size >= 2 && slotName.size >= 1)
              result.add(typeName + "." + slotName)
          }
        }
        i = end
      }
      else i++
    }
    return result
  }

  **
  ** Extract all uppercase identifiers from a line (potential type references).
  **
  private static Str[] extractUppercaseIdents(Str line)
  {
    result := Str[,]
    i := 0
    while (i < line.size)
    {
      c := line[i]
      if (c == '"')
      {
        i++
        while (i < line.size && line[i] != '"') i++
        i++
        continue
      }
      if (c == '/' && i + 1 < line.size && line[i+1] == '/') break
      if (c.isUpper)
      {
        end := i + 1
        while (end < line.size && (line[end].isAlphaNum || line[end] == '_')) end++
        ident := line[i..<end]
        if (ident.size >= 2) result.add(ident)
        i = end
      }
      else i++
    }
    return result
  }

  private static Str? extractIdentifier(Str text)
  {
    end := 0
    while (end < text.size && (text[end].isAlphaNum || text[end] == '_')) end++
    return end > 0 ? text[0..<end] : null
  }
}
