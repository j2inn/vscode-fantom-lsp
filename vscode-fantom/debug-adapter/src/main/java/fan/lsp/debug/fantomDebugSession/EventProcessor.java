package fan.lsp.debug.fantomDebugSession;

import com.sun.jdi.*;
import com.sun.jdi.event.*;

/**
 * JDI event loop — runs on a single daemon thread.
 *
 * Responsibilities:
 *  - Deliver ClassPrepareEvents to BreakpointManager so pending breakpoints
 *    are installed as their classes load.
 *  - Emit DAP "stopped" events for breakpoints and steps.
 *  - Emit DAP "terminated" on VM death / disconnect.
 */
public class EventProcessor {

    private final SessionContext    ctx;
    private final BreakpointManager bps;

    public EventProcessor(SessionContext ctx, BreakpointManager bps) {
        this.ctx = ctx;
        this.bps = bps;
    }

    public void start() {
        Thread t = new Thread(this::run, "jdi-event-thread");
        t.setDaemon(true);
        ctx.eventThread = t;
        t.start();
    }

    private void run() {
        EventQueue queue = ctx.vm.eventQueue();
        while (!Thread.currentThread().isInterrupted()) {
            try {
                EventSet eventSet = queue.remove();
                boolean  resume   = true;

                for (Event event : eventSet) {
                    // Suppress high-volume ClassPrepareEvent logging
                    if (!(event instanceof ClassPrepareEvent))
                        System.err.println("[JDI] event: " + event.getClass().getSimpleName());

                    if (event instanceof VMStartEvent) {
                        resume = false;

                    } else if (event instanceof ClassPrepareEvent) {
                        bps.installPendingBreakpoints(
                            ((ClassPrepareEvent) event).referenceType());

                    } else if (event instanceof BreakpointEvent) {
                        BreakpointEvent be = (BreakpointEvent) event;
                        ctx.stoppedThread = be.thread();
                        ctx.clearFrameStore();
                        ctx.sendStoppedEvent("breakpoint", be.thread());
                        resume = false;

                    } else if (event instanceof StepEvent) {
                        StepEvent se = (StepEvent) event;
                        ctx.vm.eventRequestManager().deleteEventRequest(se.request());
                        ctx.stoppedThread = se.thread();
                        ctx.clearFrameStore();
                        ctx.sendStoppedEvent("step", se.thread());
                        resume = false;

                    } else if (event instanceof VMDeathEvent) {
                        ctx.sendTerminated();
                        resume = false;

                    } else if (event instanceof VMDisconnectEvent) {
                        ctx.sendTerminated();
                        return;
                    }
                }

                if (resume) eventSet.resume();

            } catch (InterruptedException e) {
                break;
            } catch (VMDisconnectedException e) {
                System.err.println("[JDI] VM disconnected");
                ctx.server.sendEvent("terminated", null);
                break;
            } catch (Exception e) {
                System.err.println("[JDI] event loop error: " + e);
            }
        }
    }
}
