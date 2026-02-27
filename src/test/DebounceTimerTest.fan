**
** DebounceTimerTest - Unit tests for DebounceTimer.
**
** Time is simulated by back-dating 'pendingTicks' (internal field) so
** the tests run instantly without real sleeps.
**
class DebounceTimerTest : Test
{

//////////////////////////////////////////////////////////////////////////
// hasPending / initial state
//////////////////////////////////////////////////////////////////////////

  Void testInitialStateIsEmpty()
  {
    t := DebounceTimer()
    verify(!t.hasPending)
    verifyNull(t.take)
  }

//////////////////////////////////////////////////////////////////////////
// defer
//////////////////////////////////////////////////////////////////////////

  Void testDeferSetsPending()
  {
    t := DebounceTimer()
    t.defer("file:///a.fan", "class A {}")
    verify(t.hasPending)
  }

  Void testMultipleDeferKeepsLatest()
  {
    t := DebounceTimer()
    t.defer("file:///a.fan", "class A {}")
    t.defer("file:///b.fan", "class B {}")
    // Only the latest change is pending
    t.debounceMs = 0
    result := t.take
    verifyNotNull(result)
    verifyEq(result[0], "file:///b.fan")
    verifyEq(result[1], "class B {}")
  }

//////////////////////////////////////////////////////////////////////////
// take — window not elapsed
//////////////////////////////////////////////////////////////////////////

  Void testTakeReturnsNullWithinWindow()
  {
    t := DebounceTimer()
    t.debounceMs = 5_000  // 5 seconds — test runs much faster
    t.defer("file:///a.fan", "class A {}")
    // Called immediately — window has not elapsed
    verifyNull(t.take)
    // Pending is still recorded
    verify(t.hasPending)
  }

//////////////////////////////////////////////////////////////////////////
// take — window elapsed
//////////////////////////////////////////////////////////////////////////

  Void testTakeReturnsResultWhenWindowExpired()
  {
    t := DebounceTimer()
    t.debounceMs = 500
    t.defer("file:///a.fan", "class A {}")
    // Simulate 600 ms having passed by back-dating pendingTicks
    t.pendingTicks = Duration.nowTicks - 600_000_000
    result := t.take
    verifyNotNull(result)
    verifyEq(result[0], "file:///a.fan")
    verifyEq(result[1], "class A {}")
  }

  Void testTakeWithZeroDebounceIsImmediatelyReady()
  {
    t := DebounceTimer()
    t.debounceMs = 0
    t.defer("file:///a.fan", "class A {}")
    verifyNotNull(t.take)
  }

//////////////////////////////////////////////////////////////////////////
// take — consumes state
//////////////////////////////////////////////////////////////////////////

  Void testTakeClearsPending()
  {
    t := DebounceTimer()
    t.debounceMs = 0
    t.defer("file:///a.fan", "class A {}")
    t.take
    verify(!t.hasPending)
    verifyNull(t.take)
  }

//////////////////////////////////////////////////////////////////////////
// defer resets window
//////////////////////////////////////////////////////////////////////////

  Void testSubsequentDeferResetsWindow()
  {
    t := DebounceTimer()
    t.debounceMs = 500
    t.defer("file:///a.fan", "class A {}")
    // Simulate 600 ms since first defer — would normally be ready
    t.pendingTicks = Duration.nowTicks - 600_000_000

    // Second defer resets the window to now
    t.defer("file:///a.fan", "class A { Void m() {} }")

    // take() should return null because window was reset
    verifyNull(t.take)
    verify(t.hasPending)
  }

//////////////////////////////////////////////////////////////////////////
// clear
//////////////////////////////////////////////////////////////////////////

  Void testClearDiscardsPending()
  {
    t := DebounceTimer()
    t.defer("file:///a.fan", "class A {}")
    t.clear
    verify(!t.hasPending)
    verifyNull(t.take)
  }

  Void testClearOnEmptyTimerIsNoOp()
  {
    t := DebounceTimer()
    t.clear  // must not throw
    verify(!t.hasPending)
  }

//////////////////////////////////////////////////////////////////////////
// isReady
//////////////////////////////////////////////////////////////////////////

  Void testIsReadyFalseWhenNoPending()
  {
    t := DebounceTimer()
    verify(!t.isReady)
  }

  Void testIsReadyFalseWithinWindow()
  {
    t := DebounceTimer()
    t.debounceMs = 5_000
    t.defer("file:///a.fan", "class A {}")
    verify(!t.isReady)
  }

  Void testIsReadyTrueAfterWindow()
  {
    t := DebounceTimer()
    t.debounceMs = 500
    t.defer("file:///a.fan", "class A {}")
    t.pendingTicks = Duration.nowTicks - 600_000_000
    verify(t.isReady)
  }

}
