package fan.lsp.debug;

import com.google.gson.*;
import fan.lsp.debug.fantomDebugSession.*;

/**
 * Thin facade that wires the seven handler classes together and exposes
 * the public DAP API consumed by DapServer.
 *
 * All logic lives in the fantomDebugSession sub-package:
 *   SessionContext       – shared mutable state + utility helpers
 *   ValueFormatter       – JDI value/type formatting (never invokes JVM methods)
 *   BreakpointManager    – setBreakpoints, pending-install on ClassPrepare
 *   ExecutionController  – resume, step, pause, threads
 *   StackInspector       – stackTrace, scopes, variables
 *   EvalHandler          – evaluate (Watch panel / hover)
 *   EventProcessor       – JDI event loop on a daemon thread
 *   LaunchHandler        – launch, attach, shadow FAN_HOME, teardown
 *
 * Windows notes (all in LaunchHandler):
 *   - killProcess():  uses "taskkill /F /T /PID" on Windows
 *   - linkOrCopy():   falls back to a full directory/file copy when
 *     Files.createSymbolicLink() is denied (no Developer Mode / admin rights)
 */
public class FantomDebugSession {

    private final SessionContext      ctx;
    private final BreakpointManager   bps;
    private final ExecutionController exec;
    private final StackInspector      stack;
    private final EvalHandler         eval;
    private final EventProcessor      events;
    private final LaunchHandler       launch;

    public FantomDebugSession(DapServer server) {
        ctx    = new SessionContext(server);
        ValueFormatter fmt = new ValueFormatter(ctx);
        bps    = new BreakpointManager(ctx);
        exec   = new ExecutionController(ctx);
        stack  = new StackInspector(ctx, fmt);
        eval   = new EvalHandler(ctx, fmt);
        events = new EventProcessor(ctx, bps);
        launch = new LaunchHandler(ctx, events, bps);
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    public void launch(JsonObject args) throws Exception { launch.launch(args); }
    public void attach(JsonObject args) throws Exception { launch.attach(args); }
    public void disconnect(boolean terminateDebuggee)    { launch.disconnect(terminateDebuggee); }
    public void terminate()                              { launch.terminate(); }

    // ── Breakpoints ──────────────────────────────────────────────────────────

    public JsonObject setBreakpoints(JsonObject args) { return bps.setBreakpoints(args); }

    // ── Execution control ────────────────────────────────────────────────────

    public void configurationDone()        { exec.configurationDone(); }
    public void resume(long threadId)      { exec.resume(threadId); }
    public void next(long threadId)        { exec.next(threadId); }
    public void stepIn(long threadId)      { exec.stepIn(threadId); }
    public void stepOut(long threadId)     { exec.stepOut(threadId); }
    public void pause(long threadId)       { exec.pause(threadId); }

    // ── Inspection ───────────────────────────────────────────────────────────

    public JsonObject getThreads()                         { return exec.getThreads(); }
    public JsonObject getStackTrace(JsonObject args)       { return stack.getStackTrace(args); }
    public JsonObject getScopes(JsonObject args)           { return stack.getScopes(args); }
    public JsonObject getVariables(JsonObject args)        { return stack.getVariables(args); }
    public JsonObject evaluate(JsonObject args)            { return eval.evaluate(args); }
}
