
**
** Performs BFS traversal through the dependency graph, seeded from the
** types and slots whose source lines overlap the changed hunks.
**
** Produces the complete TestImpactAnalysis result including dependency chains.
**
internal class TiBfsEngine
{
  **
  ** Run the impact BFS and return the complete analysis result.
  **
  TestImpactAnalysis run(DiffHunk[]         hunks,
                         FanFileInfo[]       fileInfos,
                         TiDependencyGraph   graph,
                         File                testDir)
  {
    Str:Str  parent  := [:]
    Str:Bool visited := [:]
    queue := Str[,]

    // ---- Seed phase: find types/slots that overlap changed hunks ----
    hunks.each |hunk|
    {
      hunkFilePath := hunk.file.normalize.osPath
      fileInfos.each |fi|
      {
        if (!filesMatch(fi.file, hunk.file, hunkFilePath)) return

        // Seed types whose declaration range overlaps the hunk
        fi.typeLineRanges.each |range, typeName|
        {
          if (range[0] <= hunk.endLine && range[1] >= hunk.startLine)
          {
            if (!visited.containsKey(typeName))
            {
              visited[typeName] = true
              queue.add(typeName)
            }
          }
        }

        // Seed callers of slots that overlap the hunk
        fi.slotLineRanges.each |range, slotKey|
        {
          if (range[0] <= hunk.endLine && range[1] >= hunk.startLine)
          {
            // Any type that references this slot is immediately affected
            callers := graph.reverseSlotDeps[slotKey]
            if (callers != null)
            {
              callers.each |caller|
              {
                if (!visited.containsKey(caller))
                {
                  visited[caller] = true
                  parent[caller]  = slotKey   // slot edge shown in --graph output
                  queue.add(caller)
                }
              }
            }
            // Also seed the owning type so it propagates through type-level edges
            dotIdx    := slotKey.index(".")
            ownerType := dotIdx != null ? slotKey[0..<dotIdx] : slotKey
            if (!visited.containsKey(ownerType))
            {
              visited[ownerType] = true
              queue.add(ownerType)
            }
          }
        }
      }
    }

    // ---- BFS phase: propagate through type-level reverse deps ----
    while (!queue.isEmpty)
    {
      current := queue.removeAt(0)
      deps    := graph.reverseDeps[current]
      if (deps == null) continue
      deps.each |dep|
      {
        if (!visited.containsKey(dep))
        {
          visited[dep] = true
          parent[dep]  = current
          queue.add(dep)
        }
      }
    }

    // ---- Collect affected test types ----
    testDirNorm := testDir.normalize.osPath
    tests       := Str[,]
    Str:Str[] paths := [:]
    fileInfos.each |fi|
    {
      if (!isUnderDir(fi.file, testDirNorm)) return
      fi.testTypes.each |t|
      {
        if (visited.containsKey(t) && !tests.contains(t))
        {
          tests.add(t)
          paths[t] = reconstructPath(t, parent)
        }
      }
    }

    // ---- Build type → source filename map ----
    Str:Str typeToFile := [:]
    fileInfos.each |fi| { fi.definedTypes.each |t| { typeToFile[t] = fi.file.name } }

    return TestImpactAnalysis(tests, paths, typeToFile)
  }

  // ---- Private helpers ----

  private Str[] reconstructPath(Str testType, Str:Str parent)
  {
    path := Str[,]
    Str current := testType
    path.add(current)
    while (parent.containsKey(current))
    {
      current = parent[current]
      path.insert(0, current)
    }
    return path
  }

  private static Bool filesMatch(File indexed, File changed, Str changedNorm)
  {
    if (indexed.normalize.osPath == changedNorm) return true
    if (indexed.osPath.endsWith(changed.osPath)) return true
    return indexed.name == changed.name
  }

  private static Bool isUnderDir(File f, Str dirNorm)
  {
    p := f.normalize.osPath
    return p == dirNorm ||
           p.startsWith(dirNorm + "/") ||
           p.startsWith(dirNorm + "\\")
  }
}
