using concurrent

**
** PodWatchService - Polls lib/fan for pod file changes and triggers re-indexing.
**
** Only .pod files (across the full Fantom path) are tracked so that
** auxiliary files written by the JVM (e.g. extracted .jar / .class caches)
** do not produce false-positive change events.
** A startup grace period and a post-fire cooldown further prevent spurious
** notifications during server initialisation.
**
class PodWatchService
{
  ** How often to poll
  private const Duration pollInterval := 5sec

  ** Grace period after start() before any change is reported
  private const Duration startupGrace := 30sec

  ** Minimum time between successive change notifications
  private const Duration fireCooldown := 60sec

  private Bool running := false
  private Actor? pollActor := null

  ** Snapshot: pod basename → mtime (only .pod files)
  private Str:DateTime? snapshot := [:]

  ** Wall-clock time when start() was called
  private DateTime? startedAt := null

  ** Wall-clock time of the last change notification
  private DateTime? lastFiredAt := null

  private |->|? onChange := null

  **
  ** Start polling all Fantom-path lib/fan directories for .pod file changes.
  ** The callback is invoked whenever a .pod file is added, removed, or modified.
  **
  Void start(ActorPool pool, |->| onChange)
  {
    if (running) return

    // Require at least one lib/fan directory to exist
    if (LspUtil.allPodFiles.isEmpty) return

    this.onChange = onChange
    this.startedAt = DateTime.now
    running = true
    takeSnapshot

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

  ** Rebuild snapshot from all .pod files across the Fantom path.
  private Void takeSnapshot()
  {
    snapshot = Str:DateTime?[:]
    LspUtil.allPodFiles.each |f|
    {
      snapshot[f.basename] = f.modified
    }
  }

  private Void checkForChanges()
  {
    // Build current state (only .pod files)
    current := Str:DateTime?[:]
    LspUtil.allPodFiles.each |f|
    {
      current[f.basename] = f.modified
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
        if (!current.containsKey(name)) changed = true
      }

    // Always advance snapshot so the same change is not re-reported
    snapshot = current

    if (!changed) return

    // Startup grace: ignore changes in the first N seconds after start
    now := DateTime.now
    if (startedAt != null && (now - startedAt) < startupGrace)
    {
      LspProtocol.logInfo("PodWatchService: pod change detected during startup grace — ignored")
      return
    }

    // Cooldown: do not fire more than once per fireCooldown window
    if (lastFiredAt != null && (now - lastFiredAt) < fireCooldown)
    {
      LspProtocol.logInfo("PodWatchService: pod change detected within cooldown window — ignored")
      return
    }

    lastFiredAt = now
    onChange?.call()
  }
}
