
**
** Per-file structural analysis result, produced by an IFanFileAnalyzer implementation.
** Holds all information extracted from a single .fan source file.
**
internal class FanFileInfo
{
  ** Absolute file reference.
  File      file

  ** Top-level class/mixin names defined in this file.
  Str[]     definedTypes

  ** Subset of definedTypes recognised as test classes
  ** (extend Test or contain Void testXxx() methods).
  Str[]     testTypes

  ** Uppercase identifiers used in this file (external type dependencies).
  Str[]     referencedTypes

  ** "TypeName.slotName" call patterns found in this file (slot-level deps).
  Str[]     typeSlotRefs

  ** typeName -> [startLine, endLine], 1-based line numbers, inclusive.
  Str:Int[] typeLineRanges

  ** "TypeName.slotName" -> [startLine, endLine], 1-based, inclusive.
  Str:Int[] slotLineRanges

  new make(File      file,
           Str[]     definedTypes,
           Str[]     testTypes,
           Str[]     referencedTypes,
           Str[]     typeSlotRefs,
           Str:Int[] typeLineRanges,
           Str:Int[] slotLineRanges)
  {
    this.file            = file
    this.definedTypes    = definedTypes
    this.testTypes       = testTypes
    this.referencedTypes = referencedTypes
    this.typeSlotRefs    = typeSlotRefs
    this.typeLineRanges  = typeLineRanges
    this.slotLineRanges  = slotLineRanges
  }
}
