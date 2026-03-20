package fan.lsp.debug.fantomDebugSession;

import com.google.gson.*;
import com.sun.jdi.*;
import fan.lsp.debug.DapServer;
import fan.lsp.debug.SourceMapper;

import java.util.*;
import java.util.concurrent.atomic.*;

/**
 * Shared mutable state for a single debug session.
 *
 * All handler classes hold a reference to the same SessionContext instance.
 * Fields are package-private so handlers can access them directly without
 * generating noisy getter/setter boilerplate.
 */
public class SessionContext {

    // ── Wiring ────────────────────────────────────────────────────────────
    public final DapServer server;

    // ── JDI state (set by LaunchHandler) ─────────────────────────────────
    public VirtualMachine   vm;
    public Process          fanProcess;
    public Thread           eventThread;
    public SourceMapper     sourceMapper;

    /** Thread that last triggered a stop event (breakpoint / step). */
    public volatile ThreadReference stoppedThread;

    /** Temp shadow FAN_HOME path — deleted on cleanup. */
    public String  debugShadowHome;

    /** If shadow creation failed, holds the root-cause message for a better error. */
    public String  shadowCreationError;

    /** True when we launched the process ourselves (vs. attach-only). */
    public boolean wasLaunched = false;

    /** Guards against sending "terminated" more than once. */
    public final AtomicBoolean terminatedSent = new AtomicBoolean(false);

    // ── Breakpoint / variable state ───────────────────────────────────────
    public final List<PendingBreakpoint>       pendingBreakpoints = new ArrayList<>();
    public final Map<Integer, ObjectReference> objectStore        = new HashMap<>();
    public final Map<Integer, StackFrame>      frameStore         = new HashMap<>();
    public final AtomicInteger                 nextRef            = new AtomicInteger(1000);

    // ── Construction ──────────────────────────────────────────────────────

    public SessionContext(DapServer server) {
        this.server = server;
    }

    // ── Common helpers used by all handlers ──────────────────────────────

    public void consoleLog(String msg) {
        JsonObject o = new JsonObject();
        o.addProperty("category", "console");
        o.addProperty("output",   msg + "\n");
        server.sendEvent("output", o);
    }

    public void clearFrameStore() {
        frameStore.clear();
        objectStore.clear();
        nextRef.set(1000);
    }

    public void sendStoppedEvent(String reason, ThreadReference thread) {
        JsonObject body = new JsonObject();
        body.addProperty("reason",            reason);
        body.addProperty("threadId",          thread.uniqueID());
        body.addProperty("allThreadsStopped", true);
        server.sendEvent("stopped", body);
    }

    public void sendTerminated() {
        if (terminatedSent.compareAndSet(false, true)) {
            try { server.sendEvent("terminated", null); } catch (Exception ignore) {}
        }
    }

    public Optional<ThreadReference> findThread(long id) {
        if (vm == null) return Optional.empty();
        return vm.allThreads().stream().filter(t -> t.uniqueID() == id).findFirst();
    }

    // ── JSON helpers ─────────────────────────────────────────────────────

    public static String str(JsonObject o, String key, String def) {
        return (o != null && o.has(key) && !o.get(key).isJsonNull())
            ? o.get(key).getAsString() : def;
    }

    public static int num(JsonObject o, String key, int def) {
        return (o != null && o.has(key) && !o.get(key).isJsonNull())
            ? o.get(key).getAsInt() : def;
    }

    public static boolean bool(JsonObject o, String key, boolean def) {
        return (o != null && o.has(key) && !o.get(key).isJsonNull())
            ? o.get(key).getAsBoolean() : def;
    }
}
