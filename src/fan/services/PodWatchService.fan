using concurrent

**
** PodWatchService - Polls lib/fan for any file changes and triggers re-indexing.
**
class PodWatchService
{
  private const Duration pollInterval := 2sec
  private Bool running := false
  private Actor? pollActor := null
  private Str:DateTime? snapshot := [:]
  private |->|? onChange := null

  **
  ** Start polling the runtime lib/fan directory for any file changes.
  ** The callback is invoked whenever anything inside lib/fan changes.
  **
  Void start(ActorPool pool, |->| onChange)
  {
    if (running) return

    libDir := Env.cur.homeDir + `lib/fan/`
    if (!libDir.exists) return

    this.onChange = onChange
    running = true
    takeSnapshot(libDir)

    ref := Unsafe(this)
    pollActor = Actor(pool) |msg->Obj?| {
      svc := ((Unsafe)msg).val as PodWatchService
      if (svc != null) svc.poll
      return null
    }

    pollActor.sendLater(pollInterval, ref)
  }

  ** Stop polling.
  Void stop()
  {
    running = false
  }

  ** Poll once and schedule the next run.
  internal Void poll()
  {
    if (!running) return

    try
      checkForChanges
    catch (Err e)
      LspProtocol.logInfo("PodWatchService error: $e")

    if (pollActor != null)
      pollActor.sendLater(pollInterval, Unsafe(this))
  }

  private Void takeSnapshot(File libDir)
  {
    snapshot.clear
    libDir.list.each |f|
    {
      snapshot[f.name] = f.modified
    }
  }

  private Void checkForChanges()
  {
    libDir := Env.cur.homeDir + `lib/fan/`
    if (!libDir.exists) return

    current := Str:DateTime?[:]
    libDir.list.each |f|
    {
      current[f.name] = f.modified
    }

    Bool changed := false

    current.each |mtime, name|
    {
      prev := snapshot[name]
      if (prev == null || (mtime != null && mtime != prev))
        changed = true
    }

    if (!changed)
      snapshot.keys.each |name|
      {
        if (!current.containsKey(name))
          changed = true
      }

    snapshot = current

    if (changed)
      onChange?.call
  }
}
