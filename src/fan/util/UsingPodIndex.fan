
**
** UsingPodIndex - Loads and indexes public types from pods referenced in
** 'using' statements plus the sys pod.  Built once per analysis pass so that
** Pod.find() is called only once per pod rather than once per type name.
**
** Types from loadable pods stay in source code (the single-file compiler can
** also resolve them).  Types from unloadable pods must be replaced with Obj
** during preprocessing, since the compiler cannot find them either.
**
** Pod types are served through PodTypeCache (see below) so that the
** pod.types enumeration is only done once per pod per mtime epoch.
**
class UsingPodIndex
{
  ** Map: simple type name → reflected sys/using-pod Type
  private Str:Type typeIndex := [:]

  ** Pod names from using statements that could not be loaded
  private Str[] unloadablePods := [,]

  **
  ** Build index from the using statements in source.
  ** Loads each referenced pod and indexes its public types.
  ** Pods that cannot be found are tracked in unloadablePods.
  **
  static UsingPodIndex fromSource(Str source)
  {
    idx := UsingPodIndex()

    // Always include sys pod types (via cache)
    try
    {
      types := PodTypeCache.cur.typesFor("sys")
      types?.each |t| { idx.typeIndex[t.name] = t }
    }
    catch (Err e) {}

    // Parse every "using podName" line and try to load the pod
    source.splitLines.each |line|
    {
      trimmed := line.trim
      if (!trimmed.startsWith("using ")) return
      if (trimmed.contains("[java]")) return   // skip FFI using statements

      // "using podName" or "using podName::TypeName" or "using podName as Alias"
      rest := trimmed["using ".size..-1].trim
      podName := rest
      colonIdx := rest.index("::")
      if (colonIdx != null) podName = rest[0..<colonIdx]
      // Also strip "as Alias" suffix
      spaceIdx := podName.index(" ")
      if (spaceIdx != null) podName = podName[0..<spaceIdx]

      if (podName == "sys") return  // already loaded above

      try
      {
        types := PodTypeCache.cur.typesFor(podName)
        if (types == null)
        {
          idx.unloadablePods.add(podName)
          return
        }
        types.each |t| { idx.typeIndex[t.name] = t }
      }
      catch (Err e) { idx.unloadablePods.add(podName) }
    }

    return idx
  }

  ** Is this type name known from sys or any loadable using pod?
  Bool hasType(Str name) { typeIndex.containsKey(name) }

  ** Get the reflected Type for a known type name, or null.
  Type? getType(Str name) { typeIndex[name] }

  ** All reflected types indexed (sys + using pods).
  Type[] allTypes() { typeIndex.vals }

  ** Does the given type have a public slot with this name?
  Bool hasSlot(Str typeName, Str slotName)
  {
    typeIndex[typeName]?.slot(slotName, false) != null
  }

  ** True if any using pod could not be loaded.
  ** When true, some type names in the source may be unknown to us.
  Bool hasUnloadablePods() { !unloadablePods.isEmpty }

  ** Names of pods from using statements that could not be loaded.
  Str[] getUnloadablePods() { unloadablePods.ro }

  **
  ** Compute a cheap fingerprint of the using-pod names in source.
  ** Used by callers to decide whether to reuse a cached UsingPodIndex.
  ** The fingerprint is the sorted, space-joined list of pod names
  ** (always includes "sys").
  **
  static Str fingerprintFor(Str source)
  {
    pods := Str["sys"]
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
      if (!pods.contains(podName)) pods.add(podName)
    }
    pods.sort
    return pods.join(" ")
  }
}

**************************************************************************
** PodTypeCache
**************************************************************************

**
** Process-level cache mapping pod name → public Type[].
** Each entry also stores the pod file's modification time so that if the
** pod is rebuilt on disk the stale entry is evicted on the next access
** and the fresh types are loaded from the new pod.
**
** Note: Fantom loads pods into the JVM class-loader once.  A changed pod
** file cannot be *reloaded* within the same JVM process — the types will
** only update after the LSP is restarted.  The mtime check therefore serves
** as a correctness signal (the cache is never "more stale than disk") rather
** than a live-reload mechanism.
**
** Thread-safety: the LSP message-dispatch loop is single-threaded, so the
** inner map is mutated without locks.  The Unsafe wrapper allows the map
** to live inside a const singleton.
**
const class PodTypeCache
{
  ** Singleton instance
  static const PodTypeCache cur := PodTypeCache()

  ** Unsafe wrapper around Str:PodCacheEntry (mutable, single-threaded access only)
  private const Unsafe store := Unsafe(Str:PodCacheEntry[:])

  **
  ** Return public types for the named pod, using the cache.
  ** Returns null if the pod cannot be found or loaded.
  ** If the pod file's mtime has changed since the last load, the entry is
  ** evicted and the pod's types are re-fetched (Pod.find is idempotent
  ** once the pod is in the JVM; the types will be identical until restart).
  **
  Type[]? typesFor(Str podName)
  {
    m := (Str:PodCacheEntry)store.val
    entry := m[podName]
    mtime := podFileMtime(podName)

    if (entry != null && entry.mtime == mtime)
      return entry.types

    // Cache miss or stale pod file — (re-)load
    pod := Pod.find(podName, false)
    if (pod == null) return null

    types := pod.types.findAll |t| { t.isPublic }
    m[podName] = PodCacheEntry(types, mtime)
    LspProtocol.logInfo("PodTypeCache: cached ${types.size} types for '$podName' (mtime=$mtime)")
    return types
  }

  **
  ** Evict all entries whose pod file mtime has changed.
  ** Call this after a project build so stale pod caches are flushed
  ** before the next completion or diagnostic pass.
  **
  Void evictStale()
  {
    m := (Str:PodCacheEntry)store.val
    stale := m.keys.findAll |name| { m[name].mtime != podFileMtime(name) }
    stale.each |name|
    {
      m.remove(name)
      LspProtocol.logInfo("PodTypeCache: evicted stale entry for '$name'")
    }
  }

  ** Return the modification time of the pod file, or null if not found.
  private static DateTime? podFileMtime(Str podName)
  {
    try
    {
      f := Env.cur.homeDir + `lib/fan/${podName}.pod`
      return f.exists ? f.modified : null
    }
    catch (Err e) { return null }
  }
}

**************************************************************************
** PodCacheEntry
**************************************************************************

** Single entry in PodTypeCache
internal class PodCacheEntry
{
  ** Public types from the pod at the time of caching
  Type[] types

  ** Pod file modification time at time of caching (null = file not found)
  DateTime? mtime

  new make(Type[] types, DateTime? mtime)
  {
    this.types = types
    this.mtime = mtime
  }
}
