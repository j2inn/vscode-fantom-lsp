
**
** Builds and holds the reverse dependency graph for a set of analysed files.
** Supports two levels of granularity:
**   - type-level:  type A references type B  →  changing B may affect A
**   - slot-level:  type A calls B.slot       →  changing that slot may affect A
**
internal class TiDependencyGraph
{
  ** type → [types that reference it]
  const Str:Str[] reverseDeps

  ** "Type.slot" → [types that call that slot]
  const Str:Str[] reverseSlotDeps

  private new make(Str:Str[] reverseDeps, Str:Str[] reverseSlotDeps)
  {
    this.reverseDeps     = reverseDeps
    this.reverseSlotDeps = reverseSlotDeps
  }

  **
  ** Build a TiDependencyGraph from the given per-file analysis results.
  **
  static TiDependencyGraph build(FanFileInfo[] fileInfos)
  {
    Str:Str[] rev     := [:]
    Str:Str[] revSlot := [:]

    fileInfos.each |fi|
    {
      fi.definedTypes.each |defType|
      {
        // Type-level reverse edges
        fi.referencedTypes.each |refType|
        {
          list := rev[refType]
          if (list == null) { list = Str[,]; rev[refType] = list }
          if (!list.contains(defType)) list.add(defType)
        }

        // Slot-level reverse edges
        fi.typeSlotRefs.each |slotRef|
        {
          list := revSlot[slotRef]
          if (list == null) { list = Str[,]; revSlot[slotRef] = list }
          if (!list.contains(defType)) list.add(defType)
        }
      }
    }

    return TiDependencyGraph(rev, revSlot)
  }
}
