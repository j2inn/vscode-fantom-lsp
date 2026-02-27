**
** DebounceTimer manages the debounce idle window for LSP text-document
** diagnostics.  It records the URI and source text of the most recent
** edit together with the wall-clock time, and exposes take() to
** atomically consume the pending change once the idle window expires.
**
** The 'pendingTicks' field is internal (not private) so that unit tests
** can back-date it to simulate elapsed time without real sleeps.
**
class DebounceTimer
{
  ** Idle window in milliseconds.  Pending changes are not exposed by
  ** take() until this many milliseconds have passed without a new defer().
  Int debounceMs := 500

  ** URI of the most recently changed document, or null if nothing pending.
  private Str? pendingUri

  ** Source text of the most recently changed document.
  private Str? pendingText

  ** Nanosecond tick count when the last defer() was called.
  ** Declared internal so tests can back-date it to simulate elapsed time.
  internal Int pendingTicks := 0

  ** Return true if a pending change is recorded (window may not have elapsed yet).
  Bool hasPending() { pendingUri != null }

  **
  ** Record a new change for 'uri'.  Resets the debounce window so that
  ** consecutive keystrokes push the flush further into the future.
  **
  Void defer(Str uri, Str text)
  {
    pendingUri   = uri
    pendingText  = text
    pendingTicks = Duration.nowTicks
  }

  **
  ** Return true if a pending change exists and the idle window has elapsed.
  **
  Bool isReady()
  {
    if (pendingUri == null) return false
    return Duration.nowTicks - pendingTicks >= debounceMs * 1_000_000
  }

  **
  ** If isReady(), clear the pending state and return [uri, text].
  ** Returns null if nothing is pending or the window has not elapsed yet.
  **
  Str[]? take()
  {
    if (!isReady) return null
    uri  := pendingUri
    text := pendingText
    pendingUri  = null
    pendingText = null
    return [uri, text]
  }

  ** Discard any pending change without running analysis.
  Void clear()
  {
    pendingUri  = null
    pendingText = null
  }
}
