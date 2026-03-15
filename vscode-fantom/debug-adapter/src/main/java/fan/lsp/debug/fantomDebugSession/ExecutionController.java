package fan.lsp.debug.fantomDebugSession;

import com.google.gson.*;
import com.sun.jdi.*;
import com.sun.jdi.request.*;

/** Handles execution control: resume, step variants, pause and thread listing. */
public class ExecutionController {

    private final SessionContext ctx;

    public ExecutionController(SessionContext ctx) {
        this.ctx = ctx;
    }

    public void configurationDone() {
        if (ctx.vm != null) {
            System.err.println("[JDI] configurationDone → resuming VM");
            ctx.vm.resume();
        }
    }

    public void resume(long threadId) {
        if (ctx.vm == null) return;
        ctx.clearFrameStore();
        ctx.vm.resume();
    }

    public void next(long threadId) {
        stepThread(threadId, StepRequest.STEP_LINE, StepRequest.STEP_OVER);
    }

    public void stepIn(long threadId) {
        stepThread(threadId, StepRequest.STEP_LINE, StepRequest.STEP_INTO);
    }

    public void stepOut(long threadId) {
        stepThread(threadId, StepRequest.STEP_LINE, StepRequest.STEP_OUT);
    }

    private void stepThread(long threadId, int size, int depth) {
        if (ctx.vm == null) return;
        ctx.findThread(threadId).ifPresent(thread -> {
            // Delete any existing step request for this thread first —
            // JDI throws IllegalArgumentException if two StepRequests coexist.
            ctx.vm.eventRequestManager().stepRequests().stream()
                .filter(r -> r.thread().equals(thread))
                .forEach(r -> ctx.vm.eventRequestManager().deleteEventRequest(r));

            StepRequest sr = ctx.vm.eventRequestManager()
                .createStepRequest(thread, size, depth);
            sr.setSuspendPolicy(EventRequest.SUSPEND_ALL);
            // Skip standard library internals — keep stepping in Fantom user code
            sr.addClassExclusionFilter("java.*");
            sr.addClassExclusionFilter("javax.*");
            sr.addClassExclusionFilter("sun.*");
            sr.addClassExclusionFilter("com.sun.*");
            sr.addClassExclusionFilter("jdk.*");
            sr.addClassExclusionFilter("fan.sys.*");
            sr.addClassExclusionFilter("fanx.*");
            sr.enable();

            ctx.clearFrameStore();
            // Resume ALL threads: SUSPEND_ALL gives each thread a suspend count
            // of 1; vm.resume() decrements all counts together.  Calling
            // thread.resume() alone leaves others suspended and can deadlock.
            ctx.vm.resume();
        });
    }

    public void pause(long threadId) {
        if (ctx.vm == null) return;
        if (threadId < 0) {
            ctx.vm.suspend();
            ctx.vm.allThreads().stream().findFirst()
                .ifPresent(t -> ctx.sendStoppedEvent("pause", t));
        } else {
            ctx.findThread(threadId).ifPresent(t -> {
                t.suspend();
                ctx.sendStoppedEvent("pause", t);
            });
        }
    }

    public JsonObject getThreads() {
        JsonArray threads = new JsonArray();
        if (ctx.vm != null) {
            for (ThreadReference t : ctx.vm.allThreads()) {
                JsonObject thread = new JsonObject();
                thread.addProperty("id",   t.uniqueID());
                thread.addProperty("name", t.name());
                threads.add(thread);
            }
        }
        JsonObject body = new JsonObject();
        body.add("threads", threads);
        return body;
    }
}
