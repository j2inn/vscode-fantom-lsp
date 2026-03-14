package fan.lsp.debug;

import com.google.gson.*;
import com.sun.jdi.*;
import com.sun.jdi.connect.*;
import com.sun.jdi.event.*;
import com.sun.jdi.request.*;

import java.io.*;
import java.net.ServerSocket;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.Collectors;
import java.util.stream.Collectors;

/**
 * Core Fantom debug session: wraps a JDI VirtualMachine and translates
 * between DAP requests and JDI calls.
 *
 * Key improvements over the basic reference implementation:
 *
 * 1. Variable watcher displays proper types and values.
 *    - formatType() translates JVM names → Fantom names (fan.myPod.MyClass → myPod::MyClass,
 *      fan.sys.Int$Val → sys::Int, etc.).
 *    - formatValue() invokes toString() on live Fantom objects so the
 *      Watch/Variables panel shows the actual value, not "fan.sys.List@123".
 *    - Fantom boxed primitives (Int$Val, Float$Val, Bool$True/False) are
 *      unwrapped to their raw value without any JDI method call.
 *
 * 2. Local variable scope works even without LocalVariableTable.
 *    Fantom does not always emit LocalVariableTable debug info, so
 *    frame.visibleVariables() throws AbsentInformationException.
 *    We fall back to frame.getArgumentValues() combined with the
 *    method's argument list to show at least method parameters.
 *    When LocalVariableTable IS present (e.g., when compiled with
 *    debug flags) all locals are shown normally.
 *
 * 3. evaluate() supports:
 *    - simple identifier:    fieldName / localName / argName
 *    - this-qualified:       this.fieldName
 *    - dot chains:           obj.field.subField
 *
 * Thread model
 * ─────────────
 * • Main thread: reads DAP requests from DapServer, calls methods here.
 * • JDI event thread: calls DapServer.sendEvent() to push stopped/terminated
 *   events to VS Code.
 *
 * The VM is kept suspended after breakpoint/step events; the main thread
 * resumes it on DAP "continue"/"next"/"stepIn"/"stepOut".
 */
public class FantomDebugSession {

    private final DapServer      server;
    private       VirtualMachine vm;
    private       Process        fanProcess;
    private       Thread         eventThread;
    private       SourceMapper   sourceMapper;

    // Thread that last caused a stop event — used for JDI method invocation
    private volatile ThreadReference stoppedThread;

    // Shadow FAN_HOME created for each launch session (deleted on cleanup)
    private String debugShadowHome;

    // True when we launched the process ourselves (vs. attach); used to decide
    // whether to kill it on disconnect regardless of terminateDebuggee flag.
    private boolean wasLaunched = false;

    // Guards against sending "terminated" more than once (event thread and
    // cleanup() both try to send it).
    private final AtomicBoolean terminatedSent = new AtomicBoolean(false);

    // Breakpoints that could not be installed yet (class not loaded)
    private final List<PendingBreakpoint> pendingBreakpoints = new ArrayList<>();

    // DAP variable reference store: integer handle → JDI ObjectReference
    private final Map<Integer, ObjectReference> objectStore = new HashMap<>();
    // DAP frame reference store: integer handle → JDI StackFrame
    private final Map<Integer, StackFrame>      frameStore  = new HashMap<>();
    private final AtomicInteger                 nextRef     = new AtomicInteger(1000);

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    public FantomDebugSession(DapServer server) {
        this.server = server;
    }

    /**
     * Launch a new Fantom process with JDWP enabled, then attach JDI.
     *
     * Expected launch config keys:
     *   fanExe        – path to fan/fin/any Fantom launcher executable (required)
     *   mainClass     – Fantom class to run, e.g. "myPod::Main".
     *                   Optional: launchers like "fin" already embed their main
     *                   class (fin = fanlaunch Fan finStackHost), so leave this
     *                   empty when using such executables.
     *   launcherArgs  – optional string[] inserted between fanExe and mainClass,
     *                   e.g. ["-noAuth"] → "fin -noAuth"
     *   args          – optional string[] of program arguments (after mainClass)
     *   sourceDir     – workspace root to search for .fan source files
     *   debugPort     – JDWP port (default 5005)
     *   noDebug       – boolean; skip JDWP when true
     *   preLaunchRebuild – boolean; rebuild pod with debug=true before launch
     */
    public void launch(JsonObject args) throws Exception {
        String   fanExe    = str(args, "fanExe",           "fan");
        String   mainClass = str(args, "mainClass",        "");
        String   sourceDir = str(args, "sourceDir",        ".");
        int      portHint  = num(args, "debugPort",        5005);
        boolean  noDebug   = bool(args, "noDebug",         false);
        boolean  rebuild   = bool(args, "preLaunchRebuild", false);

        sourceMapper = new SourceMapper(sourceDir);
        wasLaunched  = true;
        // findFreePort() tries the preferred port first; if it is taken
        // (e.g. by FIN_519's own JDWP listener) it falls back to any
        // available ephemeral port.
        int port = noDebug ? -1 : findFreePort(portHint);

        // Optional pre-launch rebuild: run 'fan build.fan' with debug=true
        // so the pod contains LocalVariableTable → local vars visible.
        // Use a temporary build-only shadow (debug=true, NO JDWP) so the
        // build JVM doesn't try to bind the debug port.
        if (rebuild) {
            String buildShadow = createDebugShadowHome(fanExe, -1);
            try {
                rebuildWithDebug(fanExe, sourceDir,
                        buildShadow != null ? buildShadow : deriveFanHome(fanExe));
            } finally {
                if (buildShadow != null) {
                    try { deleteRecursively(Paths.get(buildShadow)); } catch (Exception ignore) {}
                }
            }
        }

        // Create the run-time shadow FAN_HOME.
        //   • noDebug=false : debug=true + JDWP agent injected into java.options
        //   • noDebug=true  : debug=true only (no JDWP)
        // Injecting JDWP via java.options in config.props is safer than
        // JAVA_TOOL_OPTIONS: it is read once by the fan launcher for that
        // exact JVM and does NOT propagate to any subprocess.
        String shadowHome = createDebugShadowHome(fanExe, port);

        List<String> cmd = new ArrayList<>();
        cmd.add(fanExe);
        // launcherArgs go between the executable and the main class,
        // e.g. "-noAuth" → "fin -noAuth myPod::Main"
        if (args.has("launcherArgs")) {
            for (JsonElement a : args.getAsJsonArray("launcherArgs"))
                cmd.add(a.getAsString());
        }
        // mainClass is optional: launchers like "fin" already know their entry
        // point (fin = fanlaunch Fan finStackHost), so mainClass should be
        // left empty in the launch config when using such executables.
        if (!mainClass.isEmpty()) cmd.add(mainClass);
        if (args.has("args")) {
            for (JsonElement a : args.getAsJsonArray("args"))
                cmd.add(a.getAsString());
        }

        ProcessBuilder pb = new ProcessBuilder(cmd);
        pb.redirectErrorStream(false);

        // Log the exact command to the debug console so launch problems are visible.
        String cmdDisplay = String.join(" ", cmd);
        JsonObject launchMsg = new JsonObject();
        launchMsg.addProperty("category", "console");
        launchMsg.addProperty("output", "[Fantom Debug] Launching: " + cmdDisplay + "\n");
        server.sendEvent("output", launchMsg);
        System.err.println("[JDI] Launch command: " + cmdDisplay);

        if (shadowHome != null) {
            pb.environment().put("FAN_HOME", shadowHome);
        }

        // Apply any custom environment variables from the launch config.
        // This is the escape hatch for app-specific flags like FIN_NO_AUTH, etc.
        if (args.has("envVars")) {
            JsonObject envVars = args.getAsJsonObject("envVars");
            for (Map.Entry<String, JsonElement> e : envVars.entrySet()) {
                pb.environment().put(e.getKey(), e.getValue().getAsString());
            }
        }

        fanProcess = pb.start();
        pipeProcessOutput(fanProcess);

        if (noDebug) return;

        Thread.sleep(1500);
        attachToVm("localhost", port);
    }

    /**
     * Attach to an existing Fantom JVM already listening on a JDWP socket.
     *
     * Expected attach config keys:
     *   host        – default "localhost"
     *   port        – default 5005
     *   sourceDir   – workspace root
     */
    public void attach(JsonObject args) throws Exception {
        String host      = str(args, "host",      "localhost");
        int    port      = num(args, "port",      5005);
        String sourceDir = str(args, "sourceDir", ".");

        sourceMapper = new SourceMapper(sourceDir);
        attachToVm(host, port);
    }

    private void attachToVm(String host, int port) throws Exception {
        VirtualMachineManager vmm = Bootstrap.virtualMachineManager();

        AttachingConnector connector = vmm.attachingConnectors().stream()
            .filter(c -> c.name().equals("com.sun.jdi.SocketAttach"))
            .findFirst()
            .orElseThrow(() -> new RuntimeException("SocketAttach connector not found"));

        Map<String, Connector.Argument> cargs = connector.defaultArguments();
        setArg(cargs, "hostname", host);
        setArg(cargs, "port",     String.valueOf(port));
        setArg(cargs, "timeout",  "10000");

        System.err.println("[JDI] Attaching to " + host + ":" + port);
        vm = connector.attach(cargs);
        System.err.println("[JDI] Attached: " + vm.name() + " " + vm.version());

        ClassPrepareRequest cpr = vm.eventRequestManager().createClassPrepareRequest();
        cpr.setSuspendPolicy(EventRequest.SUSPEND_ALL);
        cpr.enable();

        startEventThread();
    }

    // -----------------------------------------------------------------------
    // Breakpoints
    // -----------------------------------------------------------------------

    public JsonObject setBreakpoints(JsonObject args) {
        JsonArray result = new JsonArray();

        if (vm == null) {
            JsonObject body = new JsonObject();
            body.add("breakpoints", result);
            return body;
        }

        JsonObject source     = args.getAsJsonObject("source");
        String     sourcePath = source.has("path") ? source.get("path").getAsString() : "";
        String     sourceName = new File(sourcePath).getName();  // "MyClass.fan"

        JsonArray bpRequests = args.has("breakpoints")
            ? args.getAsJsonArray("breakpoints")
            : new JsonArray();

        clearBreakpointsForFile(sourceName);

        for (JsonElement el : bpRequests) {
            int     line      = el.getAsJsonObject().get("line").getAsInt();
            boolean installed = tryInstallBreakpoint(sourceName, line);

            if (!installed)
                pendingBreakpoints.add(new PendingBreakpoint(sourceName, line));

            JsonObject bp = new JsonObject();
            bp.addProperty("verified", installed);
            bp.addProperty("line",     line);
            result.add(bp);
        }

        JsonObject body = new JsonObject();
        body.add("breakpoints", result);
        return body;
    }

    private void clearBreakpointsForFile(String sourceName) {
        List<BreakpointRequest> toRemove = new ArrayList<>();
        for (BreakpointRequest br : vm.eventRequestManager().breakpointRequests()) {
            try {
                if (sourceName.equals(br.location().sourceName())) toRemove.add(br);
            } catch (Exception ignore) {}
        }
        vm.eventRequestManager().deleteEventRequests(toRemove);
        pendingBreakpoints.removeIf(pb -> sourceName.equals(pb.sourceName));
    }

    private boolean tryInstallBreakpoint(String sourceName, int line) {
        for (ReferenceType rt : vm.allClasses()) {
            try {
                if (!sourceName.equals(rt.sourceName())) continue;
                List<Location> locs = rt.locationsOfLine(line);
                if (!locs.isEmpty()) {
                    BreakpointRequest br = vm.eventRequestManager().createBreakpointRequest(locs.get(0));
                    br.setSuspendPolicy(EventRequest.SUSPEND_ALL);
                    br.enable();
                    System.err.println("[JDI] Breakpoint set: " + sourceName + ":" + line);
                    return true;
                }
            } catch (Exception ignore) {}
        }
        return false;
    }

    private void installPendingBreakpoints(ReferenceType rt) {
        Iterator<PendingBreakpoint> it = pendingBreakpoints.iterator();
        while (it.hasNext()) {
            PendingBreakpoint pb = it.next();
            try {
                if (!pb.sourceName.equals(rt.sourceName())) continue;
                List<Location> locs = rt.locationsOfLine(pb.line);
                if (!locs.isEmpty()) {
                    BreakpointRequest br = vm.eventRequestManager().createBreakpointRequest(locs.get(0));
                    br.setSuspendPolicy(EventRequest.SUSPEND_ALL);
                    br.enable();
                    it.remove();
                    System.err.println("[JDI] Pending breakpoint installed: " + pb.sourceName + ":" + pb.line);

                    JsonObject bpBody = new JsonObject();
                    bpBody.addProperty("reason", "changed");
                    JsonObject bpInfo = new JsonObject();
                    bpInfo.addProperty("verified", true);
                    bpInfo.addProperty("line",     pb.line);
                    bpBody.add("breakpoint", bpInfo);
                    server.sendEvent("breakpoint", bpBody);
                }
            } catch (Exception e) {
                System.err.println("[JDI] Error installing pending breakpoint: " + e);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Execution control
    // -----------------------------------------------------------------------

    public void configurationDone() {
        if (vm != null) {
            System.err.println("[JDI] configurationDone → resuming VM");
            vm.resume();
        }
    }

    public void resume(long threadId) {
        if (vm == null) return;
        clearFrameStore();
        vm.resume();
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
        if (vm == null) return;
        findThread(threadId).ifPresent(thread -> {
            // Delete any existing step request for this thread first.
            // JDI throws IllegalArgumentException if you create a second
            // StepRequest for the same thread while one is still active.
            vm.eventRequestManager().stepRequests().stream()
                .filter(r -> r.thread().equals(thread))
                .forEach(r -> vm.eventRequestManager().deleteEventRequest(r));

            StepRequest sr = vm.eventRequestManager().createStepRequest(thread, size, depth);
            sr.setSuspendPolicy(EventRequest.SUSPEND_ALL);
            // Skip standard Java library internals
            sr.addClassExclusionFilter("java.*");
            sr.addClassExclusionFilter("javax.*");
            sr.addClassExclusionFilter("sun.*");
            sr.addClassExclusionFilter("com.sun.*");
            sr.addClassExclusionFilter("jdk.*");
            // Skip Fantom's own runtime library so step-into stays in user code
            sr.addClassExclusionFilter("fan.sys.*");
            sr.addClassExclusionFilter("fanx.*");
            sr.enable();
            clearFrameStore();
            // Resume ALL threads, not just the stepping thread.
            // The breakpoint/step that stopped us used SUSPEND_ALL, so every
            // thread has suspend count = 1.  Calling thread.resume() on only
            // the stepping thread leaves other threads suspended; if any of
            // them holds a lock the stepping thread needs (JIT, class-loader,
            // or application locks), the VM deadlocks silently — step never
            // fires and the debug UI freezes.  vm.resume() decrements every
            // thread's count by 1 (mirroring what SUSPEND_ALL added), and the
            // StepRequest still fires only for the thread it was created for.
            vm.resume();
        });
    }

    public void pause(long threadId) {
        if (vm == null) return;
        if (threadId < 0) {
            vm.suspend();
            vm.allThreads().stream().findFirst().ifPresent(t -> sendStoppedEvent("pause", t));
        } else {
            findThread(threadId).ifPresent(t -> {
                t.suspend();
                sendStoppedEvent("pause", t);
            });
        }
    }

    // -----------------------------------------------------------------------
    // Stack trace
    // -----------------------------------------------------------------------

    public JsonObject getStackTrace(JsonObject args) {
        long      threadId = args.get("threadId").getAsLong();
        JsonArray frames   = new JsonArray();

        if (vm != null) {
            findThread(threadId).ifPresent(thread -> {
                try {
                    int frameHandle = (int)(threadId * 10000L);
                    for (StackFrame frame : thread.frames()) {
                        try {
                            Location   loc    = frame.location();
                            int        handle = frameHandle++;
                            frameStore.put(handle, frame);

                            JsonObject dapFrame = new JsonObject();
                            dapFrame.addProperty("id",     handle);
                            dapFrame.addProperty("name",   formatFrameName(loc));
                            dapFrame.addProperty("line",   loc.lineNumber());
                            dapFrame.addProperty("column", 1);

                            String sourceName = null;
                            try { sourceName = loc.sourceName(); } catch (Exception ignore) {}

                            if (sourceName != null && sourceName.endsWith(".fan")) {
                                String fullPath = sourceMapper.findSourceFile(
                                    sourceName, loc.declaringType().name());
                                JsonObject src = new JsonObject();
                                src.addProperty("name", sourceName);
                                if (fullPath != null) src.addProperty("path", fullPath);
                                dapFrame.add("source", src);
                            }

                            frames.add(dapFrame);
                        } catch (Exception e) {
                            System.err.println("[JDI] frame error: " + e);
                        }
                    }
                } catch (IncompatibleThreadStateException e) {
                    System.err.println("[JDI] thread not suspended: " + e);
                }
            });
        }

        JsonObject body = new JsonObject();
        body.add("stackFrames", frames);
        body.addProperty("totalFrames", frames.size());
        return body;
    }

    // -----------------------------------------------------------------------
    // Scopes
    // -----------------------------------------------------------------------

    public JsonObject getScopes(JsonObject args) {
        int        frameHandle = args.get("frameId").getAsInt();
        StackFrame frame       = frameStore.get(frameHandle);
        JsonArray  scopes      = new JsonArray();

        if (frame != null) {
            // ── Locals scope ────────────────────────────────────────────────
            // We always expose a "Locals" scope. getVariables() will fill it
            // using visibleVariables() if LocalVariableTable is present, or
            // falling back to getArgumentValues() + method parameters otherwise.
            {
                int ref = nextRef.getAndIncrement();
                // Negative key → getVariables knows this is a locals frame
                frameStore.put(-ref, frame);

                JsonObject scope = new JsonObject();
                scope.addProperty("name",               "Locals");
                scope.addProperty("variablesReference", ref);
                scope.addProperty("expensive",          false);
                scopes.add(scope);
            }

            // ── "this" scope (instance fields) ──────────────────────────────
            try {
                ObjectReference thisObj = frame.thisObject();
                if (thisObj != null) {
                    int ref = nextRef.getAndIncrement();
                    objectStore.put(ref, thisObj);

                    JsonObject scope = new JsonObject();
                    scope.addProperty("name",               "this (" + jvmTypeToFantom(thisObj.type().name()) + ")");
                    scope.addProperty("variablesReference", ref);
                    scope.addProperty("expensive",          false);
                    scopes.add(scope);
                }
            } catch (Exception e) {
                System.err.println("[JDI] scopes 'this' error: " + e);
            }
        }

        JsonObject body = new JsonObject();
        body.add("scopes", scopes);
        return body;
    }

    // -----------------------------------------------------------------------
    // Variables
    // -----------------------------------------------------------------------

    public JsonObject getVariables(JsonObject args) {
        int        ref  = args.get("variablesReference").getAsInt();
        JsonArray  vars = new JsonArray();

        // ── Locals scope (stored under negative ref key in frameStore) ──────
        StackFrame localsFrame = frameStore.get(-ref);
        if (localsFrame != null) {
            fillLocalsVars(localsFrame, vars);
        } else {
            // ── Object fields scope ──────────────────────────────────────────
            ObjectReference obj = objectStore.get(ref);
            if (obj != null) {
                fillObjectVars(obj, vars);
            }
        }

        JsonObject body = new JsonObject();
        body.add("variables", vars);
        return body;
    }

    /**
     * Fill vars from a stack frame's locals.
     *
     * Strategy (in order):
     *  1. frame.visibleVariables() — works when LocalVariableTable is present.
     *  2. frame.getArgumentValues() + method.arguments() — works even without
     *     LocalVariableTable, shows at least method parameters.
     */
    private void fillLocalsVars(StackFrame frame, JsonArray vars) {
        // ── Attempt 1: LocalVariableTable ─────────────────────────────────
        try {
            List<LocalVariable> locals = frame.visibleVariables();
            if (!locals.isEmpty()) {
                Map<LocalVariable, Value> values = frame.getValues(locals);
                for (Map.Entry<LocalVariable, Value> e : values.entrySet()) {
                    vars.add(makeVar(e.getKey().name(), e.getKey().typeName(), e.getValue()));
                }
                return;  // got data — done
            }
        } catch (AbsentInformationException ignored) {
            // LocalVariableTable absent — fall through to argument fallback
        } catch (Exception e) {
            System.err.println("[JDI] visibleVariables error: " + e);
        }

        // ── Attempt 2: method arguments (available without debug info) ─────
        try {
            List<Value> argVals = frame.getArgumentValues();
            if (argVals.isEmpty()) return;

            // Try to get named argument list from LocalVariableTable if any
            List<LocalVariable> namedArgs = null;
            try { namedArgs = frame.location().method().arguments(); } catch (Exception ignore) {}

            for (int i = 0; i < argVals.size(); i++) {
                String name     = (namedArgs != null && i < namedArgs.size())
                                  ? namedArgs.get(i).name() : "arg" + i;
                String typeName = (namedArgs != null && i < namedArgs.size())
                                  ? namedArgs.get(i).typeName() : null;
                vars.add(makeVar(name, typeName, argVals.get(i)));
            }
        } catch (Exception e) {
            System.err.println("[JDI] getArgumentValues error: " + e);
        }
    }

    /**
     * Fill vars from an object's instance fields.
     * Skips Fantom synthetic fields (starting with '$') and static fields.
     */
    private void fillObjectVars(ObjectReference obj, JsonArray vars) {
        try {
            List<Field> fields = obj.referenceType().allFields();
            Map<Field, Value> values = obj.getValues(fields);
            for (Map.Entry<Field, Value> e : values.entrySet()) {
                Field f = e.getKey();
                if (f.name().startsWith("$")) continue;
                if (f.isStatic()) continue;
                vars.add(makeVar(f.name(), f.typeName(), e.getValue()));
            }
        } catch (Exception e) {
            System.err.println("[JDI] field vars error: " + e);
        }
    }

    /**
     * Build a DAP Variable object.
     *
     * @param name      display name
     * @param declType  declared type name from JDI (may be null)
     * @param value     JDI Value (may be null for "null")
     */
    private JsonObject makeVar(String name, String declType, Value value) {
        JsonObject var = new JsonObject();
        var.addProperty("name",  name);
        var.addProperty("value", formatValue(value));

        // Prefer the actual runtime type for richer display
        String displayType = (value != null) ? formatType(value) : formatDeclType(declType);
        var.addProperty("type",  displayType);

        // Allow drilling into complex objects (not strings, not null)
        int childRef = 0;
        if (value instanceof ObjectReference && !(value instanceof StringReference)) {
            childRef = nextRef.getAndIncrement();
            objectStore.put(childRef, (ObjectReference) value);
        }
        var.addProperty("variablesReference", childRef);
        return var;
    }

    // -----------------------------------------------------------------------
    // Threads
    // -----------------------------------------------------------------------

    public JsonObject getThreads() {
        JsonArray threads = new JsonArray();
        if (vm != null) {
            for (ThreadReference t : vm.allThreads()) {
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

    // -----------------------------------------------------------------------
    // Evaluate (Watch panel + hover)
    // -----------------------------------------------------------------------

    /**
     * Evaluate an expression in the context of a stack frame.
     *
     * Supported sub-expressions:
     *   identifier          → local var, argument, or "this" field
     *   this.identifier     → explicit "this" field lookup
     *   a.b.c               → field chain starting from an identifier
     */
    public JsonObject evaluate(JsonObject args) {
        String     expr    = str(args, "expression", "").trim();
        int        frameId = num(args, "frameId", -1);
        JsonObject body    = new JsonObject();
        body.addProperty("variablesReference", 0);

        if (expr.isEmpty()) {
            body.addProperty("result", "<empty expression>");
            return body;
        }

        // No frame available — can't resolve locals/this
        if (frameId < 0) {
            body.addProperty("result", "<no frame>");
            return body;
        }

        StackFrame frame = frameStore.get(frameId);
        if (frame == null) {
            body.addProperty("result", "<frame not available>");
            return body;
        }

        try {
            Value v = evalExpr(frame, expr);
            if (v != null) {
                body.addProperty("result", formatValue(v));
                body.addProperty("type",   formatType(v));
                if (v instanceof ObjectReference && !(v instanceof StringReference)) {
                    int ref = nextRef.getAndIncrement();
                    objectStore.put(ref, (ObjectReference) v);
                    body.addProperty("variablesReference", ref);
                }
                return body;
            }
        } catch (Exception e) {
            System.err.println("[JDI] evaluate error for '" + expr + "': " + e);
        }

        body.addProperty("result", "<not found: " + expr + ">");
        return body;
    }

    /**
     * Resolve an expression (possibly dot-chained) in a stack frame.
     * Returns null if the expression cannot be resolved.
     */
    private Value evalExpr(StackFrame frame, String expr) throws Exception {
        String[] parts = expr.split("\\.", 2);
        String   head  = parts[0].trim();
        String   tail  = parts.length > 1 ? parts[1].trim() : null;

        Value root = resolveIdent(frame, head);
        if (root == null) return null;
        if (tail == null) return root;

        return evalFieldChain(root, tail);
    }

    /**
     * Resolve a single identifier in the context of a frame:
     *  1. "this"  → frame.thisObject()
     *  2. visible local variables (when LocalVariableTable present)
     *  3. method arguments (by name, always available)
     *  4. instance fields of "this"
     */
    private Value resolveIdent(StackFrame frame, String ident) throws Exception {
        // "this" keyword
        if ("this".equals(ident)) return frame.thisObject();

        // ── Local variables (LocalVariableTable) ──────────────────────────
        try {
            for (LocalVariable lv : frame.visibleVariables()) {
                if (lv.name().equals(ident)) return frame.getValue(lv);
            }
        } catch (AbsentInformationException ignored) {}

        // ── Method arguments by name ────────────────────────────────────────
        try {
            List<Value>         argVals  = frame.getArgumentValues();
            List<LocalVariable> argNames = null;
            try { argNames = frame.location().method().arguments(); } catch (Exception e2) {}

            if (argNames != null) {
                for (int i = 0; i < argNames.size() && i < argVals.size(); i++) {
                    if (argNames.get(i).name().equals(ident)) return argVals.get(i);
                }
            }
        } catch (Exception ignore) {}

        // ── Instance fields of "this" ─────────────────────────────────────
        try {
            ObjectReference thisObj = frame.thisObject();
            if (thisObj != null) {
                Field f = thisObj.referenceType().fieldByName(ident);
                if (f != null) return thisObj.getValue(f);
            }
        } catch (Exception ignore) {}

        return null;
    }

    /**
     * Walk a dot-separated chain of field names on a root Value.
     * e.g. evalFieldChain(listRef, "size") → calls getField("size")
     */
    private Value evalFieldChain(Value base, String chain) throws Exception {
        if (!(base instanceof ObjectReference)) return null;

        String[] parts     = chain.split("\\.", 2);
        String   fieldName = parts[0].trim();
        String   rest      = parts.length > 1 ? parts[1].trim() : null;

        ObjectReference obj = (ObjectReference) base;
        Field f = obj.referenceType().fieldByName(fieldName);
        if (f == null) return null;

        Value v = obj.getValue(f);
        if (rest == null) return v;
        return evalFieldChain(v, rest);
    }

    // -----------------------------------------------------------------------
    // Session teardown
    // -----------------------------------------------------------------------

    public void disconnect(boolean terminateDebuggee) {
        // Always kill the process for launched sessions; for attached sessions
        // honour the terminateDebuggee flag sent by VS Code.
        cleanup(wasLaunched || terminateDebuggee);
    }

    public void terminate() {
        cleanup(true);
    }

    private void cleanup(boolean kill) {
        // Disconnect JDI cleanly (dispose() is non-blocking; we rely on
        // OS-level SIGKILL to actually stop the process, not vm.exit() which
        // can block on shutdown hooks or throw if the connection is already gone).
        if (vm != null) {
            try { vm.dispose(); } catch (Exception ignore) {}
            vm = null;
        }
        // Stop the JDI event thread before killing the process so it doesn't
        // race to send events after we've already cleaned up.
        if (eventThread != null) {
            eventThread.interrupt();
            eventThread = null;
        }
        if (fanProcess != null && kill) {
            long pid = fanProcess.pid();
            // 1. Kill the whole process group via shell (most reliable for
            //    server frameworks like FIN that spawn child JVMs / workers).
            //    "kill -KILL -<pid>" sends SIGKILL to every process whose
            //    pgid == pid.  This works when the process is a group leader
            //    (which bash scripts usually are).
            //    Fall back to individual kills from ProcessHandle.descendants()
            //    which covers processes that ended up in a different pgid.
            try {
                new ProcessBuilder("bash", "-c",
                        "kill -KILL -" + pid + " 2>/dev/null; "
                        + "kill -KILL " + pid + " 2>/dev/null")
                    .start().waitFor();
            } catch (Exception ignore) {}
            try {
                fanProcess.toHandle().descendants()
                    .forEach(h -> { try { h.destroyForcibly(); } catch (Exception e) {} });
            } catch (Exception ignore) {}
            fanProcess.destroyForcibly();
            fanProcess = null;
        }
        stoppedThread = null;
        if (debugShadowHome != null) {
            try { deleteRecursively(Paths.get(debugShadowHome)); } catch (Exception ignore) {}
            debugShadowHome = null;
        }
        if (kill) sendTerminated();
    }

    /** Send the "terminated" event exactly once per session. */
    private void sendTerminated() {
        if (terminatedSent.compareAndSet(false, true)) {
            try { server.sendEvent("terminated", null); } catch (Exception ignore) {}
        }
    }

    // -----------------------------------------------------------------------
    // Debug shadow FAN_HOME helpers
    // -----------------------------------------------------------------------

    /** Derive FAN_HOME from a fan executable path (grandparent of the binary). */
    private static String deriveFanHome(String fanExe) {
        try {
            File bin  = new File(fanExe).getCanonicalFile().getParentFile();
            if (bin == null) return null;
            File home = bin.getParentFile();
            return (home != null && home.isDirectory()) ? home.getAbsolutePath() : null;
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Create a temporary shadow FAN_HOME for the debug target process.
     *
     * The shadow directory contains:
     *   lib/          → symlink to realFanHome/lib/  (all pods visible, newly
     *                   built pods appear immediately through the symlink)
     *   etc/<subdir>  → symlink to realFanHome/etc/<subdir>  for every entry
     *                   except sys/
     *   etc/sys/      → real directory so we can override config.props
     *   etc/sys/config.props → modified copy:
     *       • java.options  stripped first (removes any pre-existing JDWP)
     *       • debug=true    added     (Fantom compiler emits LocalVariableTable
     *                                  on the next pod build → local vars visible)
     *       • java.options  re-added with jdwpPort if jdwpPort > 0 (cleaner
     *                        than JAVA_TOOL_OPTIONS: scoped to this one JVM,
     *                        not inherited by subprocesses)
     *   etc/sys/<other> → symlink to realFanHome/etc/sys/<other>
     *
     * @param fanExe    path to the fan/fin executable
     * @param jdwpPort  port to inject into java.options for JDWP; pass -1
     *                  when no JDWP is needed (e.g. for a build-only shadow)
     * Returns the shadow dir path, or null on failure.
     */
    private String createDebugShadowHome(String fanExe, int jdwpPort) {
        String fanHomeStr = deriveFanHome(fanExe);
        if (fanHomeStr == null) return null;
        try {
            Path shadow   = Files.createTempDirectory("fantom-debug-home-");
            debugShadowHome = shadow.toString();
            Path realHome = Paths.get(fanHomeStr);

            // Symlink every top-level entry from the real FAN_HOME into the
            // shadow, EXCEPT directories that need isolation (etc/, var/).
            // - etc/ needs a custom config.props (debug=true / JDWP port).
            // - var/ must be a real directory so the process can create its
            //   own vm.lock, log files, etc. without colliding with the live
            //   FIN server that holds a lock on the real var/.
            // Everything else (lib/, bin/, adm/, …) is symlinked as-is.
            Set<String> shallowExpand = new HashSet<>(Arrays.asList("etc", "var"));
            try (DirectoryStream<Path> stream = Files.newDirectoryStream(realHome)) {
                for (Path entry : stream) {
                    String name = entry.getFileName().toString();
                    if (shallowExpand.contains(name)) continue; // handled below
                    Files.createSymbolicLink(shadow.resolve(name), entry.toAbsolutePath());
                }
            }

            // var/ — real directory; only sub-directories are symlinked (not
            // plain files).  This means data dirs like brand/, db/ etc. remain
            // reachable while lock/state files (vm.lock, etc.) are absent in
            // the shadow and get created fresh, fully isolated from the live
            // FIN server that holds locks on the real var/ files.
            Path realVar   = realHome.resolve("var");
            Path shadowVar = shadow.resolve("var");
            Files.createDirectories(shadowVar);
            if (Files.isDirectory(realVar)) {
                try (DirectoryStream<Path> stream = Files.newDirectoryStream(realVar)) {
                    for (Path entry : stream) {
                        // Only symlink directories, skip plain files (vm.lock etc.)
                        if (Files.isDirectory(entry)) {
                            Files.createSymbolicLink(
                                shadowVar.resolve(entry.getFileName()),
                                entry.toAbsolutePath());
                        }
                    }
                }
            }

            // etc/ — real dir; all subdirs symlinked except sys/
            Path realEtc   = realHome.resolve("etc");
            Path shadowEtc = shadow.resolve("etc");
            Files.createDirectories(shadowEtc);

            try (DirectoryStream<Path> stream = Files.newDirectoryStream(realEtc)) {
                for (Path entry : stream) {
                    String name = entry.getFileName().toString();
                    Path   dest = shadowEtc.resolve(name);
                    if ("sys".equals(name)) {
                        Files.createDirectories(dest);
                        try (DirectoryStream<Path> sysStream = Files.newDirectoryStream(entry)) {
                            for (Path sysFile : sysStream) {
                                String sysName = sysFile.getFileName().toString();
                                Path   sysDest = dest.resolve(sysName);
                                if ("config.props".equals(sysName)) {
                                    String original = new String(Files.readAllBytes(sysFile));
                                    // Strip java.options (avoids double-JDWP) and add debug=true
                                    String modified = Arrays.stream(original.split("\n"))
                                        .filter(line -> !line.trim().startsWith("java.options"))
                                        .collect(Collectors.joining("\n"));
                                    if (!modified.contains("\ndebug=true")) {
                                        modified = modified.stripTrailing() + "\ndebug=true\n";
                                    }
                                    // Inject JDWP via java.options (read once by the fan
                                    // launcher, not propagated to child processes — unlike
                                    // JAVA_TOOL_OPTIONS which is process-wide).
                                    if (jdwpPort > 0) {
                                        modified = modified.stripTrailing()
                                            + "\njava.options=-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address="
                                            + jdwpPort + "\n";
                                    }
                                    Files.write(sysDest, modified.getBytes());
                                } else {
                                    Files.createSymbolicLink(sysDest, sysFile.toAbsolutePath());
                                }
                            }
                        }
                    } else {
                        Files.createSymbolicLink(dest, entry.toAbsolutePath());
                    }
                }
            }

            System.err.println("[JDI] Debug shadow FAN_HOME: " + shadow);
            return shadow.toString();
        } catch (Exception e) {
            System.err.println("[JDI] Warning: could not create debug shadow home: " + e);
            if (debugShadowHome != null) {
                try { deleteRecursively(Paths.get(debugShadowHome)); } catch (Exception ignore) {}
                debugShadowHome = null;
            }
            return null;
        }
    }

    /**
     * Run 'fan build.fan' in sourceDir using the shadow FAN_HOME (which has
     * debug=true), so the rebuilt pod contains LocalVariableTable entries and
     * local variables become fully visible in the debugger.
     */
    private void rebuildWithDebug(String fanExe, String sourceDir, String fanHome) {
        File buildFile = new File(sourceDir, "build.fan");
        if (!buildFile.exists()) {
            System.err.println("[Debug] No build.fan in " + sourceDir + " — skipping pre-launch rebuild");
            return;
        }
        JsonObject startMsg = new JsonObject();
        startMsg.addProperty("category", "console");
        startMsg.addProperty("output", "[Fantom Debug] Rebuilding with debug=true for local variable support...\n");
        server.sendEvent("output", startMsg);
        try {
            ProcessBuilder pb = new ProcessBuilder(fanExe, "build.fan");
            pb.directory(new File(sourceDir));
            pb.redirectErrorStream(true);
            if (fanHome != null) pb.environment().put("FAN_HOME", fanHome);
            Process proc = pb.start();
            try (BufferedReader r = new BufferedReader(new InputStreamReader(proc.getInputStream()))) {
                String line;
                while ((line = r.readLine()) != null) {
                    JsonObject out = new JsonObject();
                    out.addProperty("category", "console");
                    out.addProperty("output", line + "\n");
                    server.sendEvent("output", out);
                }
            }
            int code = proc.waitFor();
            JsonObject doneMsg = new JsonObject();
            doneMsg.addProperty("category", "console");
            doneMsg.addProperty("output", code == 0
                ? "[Fantom Debug] Rebuild successful — local variables now visible.\n"
                : "[Fantom Debug] Rebuild exited with code " + code + "\n");
            server.sendEvent("output", doneMsg);
        } catch (Exception e) {
            System.err.println("[Debug] Pre-launch rebuild failed: " + e);
        }
    }

    /** Recursively delete a path, following into real dirs but not symlinks. */
    private static void deleteRecursively(Path path) throws IOException {
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return;
        if (Files.isDirectory(path) && !Files.isSymbolicLink(path)) {
            try (DirectoryStream<Path> stream = Files.newDirectoryStream(path)) {
                for (Path child : stream) deleteRecursively(child);
            }
        }
        Files.deleteIfExists(path);
    }

    /**
     * Find a free TCP port, preferring the given hint.
     * If the hint is already in use (e.g. by FIN_519's JDWP listener or a
     * previous debug session that didn't clean up), fall back to any port
     * the OS assigns.
     */
    private static int findFreePort(int preferred) {
        try (ServerSocket s = new ServerSocket(preferred)) {
            s.setReuseAddress(true);
            return preferred;
        } catch (IOException e) {
            // preferred is taken — let the OS pick a free one
            try (ServerSocket s = new ServerSocket(0)) {
                s.setReuseAddress(true);
                return s.getLocalPort();
            } catch (IOException e2) {
                return preferred; // last resort, launch will fail with the real error
            }
        }
    }

    // -----------------------------------------------------------------------
    // JDI event thread
    // -----------------------------------------------------------------------

    private void startEventThread() {
        eventThread = new Thread(() -> {
            EventQueue eventQueue = vm.eventQueue();
            while (!Thread.currentThread().isInterrupted()) {
                try {
                    EventSet eventSet = eventQueue.remove();
                    boolean  resume   = true;

                    for (Event event : eventSet) {
                        System.err.println("[JDI] event: " + event.getClass().getSimpleName());

                        if (event instanceof VMStartEvent) {
                            resume = false;

                        } else if (event instanceof ClassPrepareEvent) {
                            installPendingBreakpoints(((ClassPrepareEvent) event).referenceType());

                        } else if (event instanceof BreakpointEvent) {
                            BreakpointEvent be = (BreakpointEvent) event;
                            stoppedThread = be.thread();
                            clearFrameStore();
                            sendStoppedEvent("breakpoint", be.thread());
                            resume = false;

                        } else if (event instanceof StepEvent) {
                            StepEvent se = (StepEvent) event;
                            vm.eventRequestManager().deleteEventRequest(se.request());
                            stoppedThread = se.thread();
                            clearFrameStore();
                            sendStoppedEvent("step", se.thread());
                            resume = false;

                        } else if (event instanceof VMDeathEvent) {
                            sendTerminated();
                            resume = false;

                        } else if (event instanceof VMDisconnectEvent) {
                            sendTerminated();
                            return;
                        }
                    }

                    if (resume) eventSet.resume();

                } catch (InterruptedException e) {
                    break;
                } catch (VMDisconnectedException e) {
                    System.err.println("[JDI] VM disconnected");
                    server.sendEvent("terminated", null);
                    break;
                } catch (Exception e) {
                    System.err.println("[JDI] event loop error: " + e);
                }
            }
        }, "jdi-event-thread");

        eventThread.setDaemon(true);
        eventThread.start();
    }

    // -----------------------------------------------------------------------
    // Value formatting
    // -----------------------------------------------------------------------

    /**
     * Format a JDI Value for display in the Variables / Watch panel.
     *
     * Special handling for Fantom:
     *  • fan.sys.Int$Val / fan.sys.Float$Val  — unwrap the primitive 'val' field
     *  • fan.sys.Bool$True / fan.sys.Bool$False — literal true/false
     *  • fan.sys.Str (StringReference)        — quoted string value
     *  • Other Fantom objects                 — invoke toString() via JDI
     *    so the panel shows the same value as Fantom's toStr() would print
     */
    private String formatValue(Value v) {
        if (v == null) return "null";

        // Primitive JDI types
        if (v instanceof StringReference)  return "\"" + escapeStr(((StringReference) v).value()) + "\"";
        if (v instanceof BooleanValue)     return Boolean.toString(((BooleanValue) v).value());
        if (v instanceof LongValue)        return Long.toString(((LongValue) v).value());
        if (v instanceof IntegerValue)     return Integer.toString(((IntegerValue) v).value());
        if (v instanceof FloatValue)       return Float.toString(((FloatValue) v).floatValue());
        if (v instanceof DoubleValue)      return Double.toString(((DoubleValue) v).doubleValue());
        if (v instanceof CharValue)        return String.valueOf(((CharValue) v).value());
        if (v instanceof ByteValue)        return Byte.toString(((ByteValue) v).value());
        if (v instanceof ShortValue)       return Short.toString(((ShortValue) v).value());

        if (v instanceof ObjectReference) {
            ObjectReference obj      = (ObjectReference) v;
            String          typeName = obj.type().name();

            // ── Fantom boxed primitives — unwrap without calling methods ────
            if (typeName.equals("fan.sys.Int$Val")) {
                Value inner = getField(obj, "val");
                if (inner != null) return formatValue(inner);
            }
            if (typeName.equals("fan.sys.Float$Val")) {
                Value inner = getField(obj, "val");
                if (inner != null) return formatValue(inner);
            }
            if (typeName.equals("fan.sys.Bool$True"))  return "true";
            if (typeName.equals("fan.sys.Bool$False")) return "false";

            // ── Invoke toString() on live Fantom/Java objects ───────────────
            // Fantom overrides java.lang.Object.toString() to call toStr()
            // which returns the Fantom string representation.
            // We use INVOKE_SINGLE_THREADED and catch everything defensively.
            String invoked = invokeToString(obj);
            if (invoked != null) return invoked;

            // ── Fallback: type@id ────────────────────────────────────────────
            return jvmTypeToFantom(typeName) + "@" + obj.uniqueID();
        }

        return v.toString();
    }

    /**
     * Invoke java.lang.Object.toString() on an ObjectReference.
     * Returns null on any error (rather than crashing the variable display).
     *
     * Requires the VM to be suspended (which it is after any breakpoint/step).
     */
    private String invokeToString(ObjectReference obj) {
        ThreadReference thread = stoppedThread;
        if (thread == null) return null;

        try {
            // Find java.lang.Object.toString() — available on every reference type
            Optional<Method> toStr = obj.referenceType()
                .methodsByName("toString", "()Ljava/lang/String;")
                .stream().findFirst();

            if (!toStr.isPresent()) return null;

            // INVOKE_SINGLE_THREADED: resume only the target thread for this call
            Value result = obj.invokeMethod(
                thread, toStr.get(), Collections.emptyList(),
                ObjectReference.INVOKE_SINGLE_THREADED
            );

            if (result instanceof StringReference)
                return ((StringReference) result).value();

        } catch (InvalidTypeException | ClassNotLoadedException |
                 IncompatibleThreadStateException | InvocationException e) {
            System.err.println("[JDI] invokeToString error for " + obj.type().name() + ": " + e);
        } catch (Exception e) {
            System.err.println("[JDI] invokeToString unexpected error: " + e);
        }
        return null;
    }

    /**
     * Format the Fantom type name for display.
     * Converts JVM class names to Fantom pod::Type notation.
     */
    private String formatType(Value v) {
        if (v == null) return "null";
        if (v instanceof BooleanValue) return "sys::Bool";
        if (v instanceof LongValue || v instanceof IntegerValue ||
            v instanceof ByteValue  || v instanceof ShortValue)  return "sys::Int";
        if (v instanceof DoubleValue || v instanceof FloatValue)  return "sys::Float";
        if (v instanceof CharValue)   return "sys::Int";  // Fantom Char is Int
        if (v instanceof StringReference) return "sys::Str";

        if (v instanceof ObjectReference) {
            String typeName = ((ObjectReference) v).type().name();
            return jvmTypeToFantom(typeName);
        }
        return v.type().name();
    }

    /**
     * Format a declared type name (from LocalVariable.typeName()) for display.
     * Used as a fallback when no live Value is available.
     */
    private static String formatDeclType(String declType) {
        if (declType == null) return "?";
        return jvmTypeToFantom(declType);
    }

    /**
     * Translate a JVM class name (or type descriptor) to a Fantom type name.
     *
     * Examples:
     *   fan.myPod.MyClass          → myPod::MyClass
     *   fan.sys.Int$Val            → sys::Int
     *   fan.sys.Bool$True/False    → sys::Bool
     *   fan.sys.List               → sys::List
     *   [Lfan.myPod.MyClass;       → myPod::MyClass[]
     *   java.lang.String           → sys::Str
     *   java.lang.Long             → sys::Int
     */
    private static String jvmTypeToFantom(String name) {
        if (name == null || name.isEmpty()) return "?";

        // Array types: [Lfan.myPod.Type; → myPod::Type[]
        if (name.startsWith("[L") && name.endsWith(";"))
            return jvmTypeToFantom(name.substring(2, name.length() - 1)) + "[]";

        // Primitive arrays
        if (name.equals("[J") || name.equals("[I")) return "sys::Int[]";
        if (name.equals("[D") || name.equals("[F")) return "sys::Float[]";
        if (name.equals("[Z"))                      return "sys::Bool[]";

        // Fantom classes: fan.podName.ClassName[$Variant]
        if (name.startsWith("fan.")) {
            String[] parts = name.split("\\.", 3);
            if (parts.length < 3) return parts.length == 2 ? parts[1] : name;

            String pod      = parts[1];
            String typePart = parts[2];

            // Strip inner-class / variant suffixes: Int$Val → Int, Bool$False → Bool
            int dollar = typePart.indexOf('$');
            if (dollar >= 0) typePart = typePart.substring(0, dollar);

            return pod + "::" + typePart;
        }

        // Common Java → Fantom mappings
        switch (name) {
            case "java.lang.String":    return "sys::Str";
            case "java.lang.Long":      return "sys::Int";
            case "java.lang.Integer":   return "sys::Int";
            case "java.lang.Double":    return "sys::Float";
            case "java.lang.Float":     return "sys::Float";
            case "java.lang.Boolean":   return "sys::Bool";
            case "java.lang.Object":    return "sys::Obj";
            case "java.math.BigDecimal":return "sys::Decimal";
            default: return name;
        }
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private void sendStoppedEvent(String reason, ThreadReference thread) {
        JsonObject body = new JsonObject();
        body.addProperty("reason",            reason);
        body.addProperty("threadId",          thread.uniqueID());
        body.addProperty("allThreadsStopped", true);
        server.sendEvent("stopped", body);
    }

    private void clearFrameStore() {
        frameStore.clear();
        objectStore.clear();
        nextRef.set(1000);
    }

    private String formatFrameName(Location loc) {
        String cls    = loc.declaringType().name();
        String method = loc.method().name();

        if (cls.startsWith("fan.")) {
            String[] parts = cls.split("\\.", 3);
            if (parts.length == 3) return parts[1] + "::" + parts[2] + "." + method;
            if (parts.length == 2) return parts[1] + "." + method;
        }
        return cls + "." + method;
    }

    /** Read a field value from an ObjectReference without invoking methods. */
    private static Value getField(ObjectReference obj, String fieldName) {
        try {
            Field f = obj.referenceType().fieldByName(fieldName);
            if (f != null) return obj.getValue(f);
        } catch (Exception ignore) {}
        return null;
    }

    private static String escapeStr(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r");
    }

    private Optional<ThreadReference> findThread(long id) {
        if (vm == null) return Optional.empty();
        return vm.allThreads().stream().filter(t -> t.uniqueID() == id).findFirst();
    }

    private void pipeProcessOutput(Process process) {
        Thread out = new Thread(() -> {
            try (BufferedReader r = new BufferedReader(
                    new InputStreamReader(process.getInputStream()))) {
                String line;
                while ((line = r.readLine()) != null) {
                    JsonObject body = new JsonObject();
                    body.addProperty("category", "stdout");
                    body.addProperty("output",   line + "\n");
                    server.sendEvent("output", body);
                }
            } catch (IOException ignore) {}
        }, "process-stdout");
        out.setDaemon(true);
        out.start();

        Thread err = new Thread(() -> {
            try (BufferedReader r = new BufferedReader(
                    new InputStreamReader(process.getErrorStream()))) {
                String line;
                while ((line = r.readLine()) != null) {
                    JsonObject body = new JsonObject();
                    body.addProperty("category", "stderr");
                    body.addProperty("output",   line + "\n");
                    server.sendEvent("output", body);
                }
            } catch (IOException ignore) {}
        }, "process-stderr");
        err.setDaemon(true);
        err.start();
    }

    private static void setArg(Map<String, Connector.Argument> cargs, String key, String value) {
        Connector.Argument arg = cargs.get(key);
        if (arg == null) {
            System.err.println("[JDI] WARNING: connector has no argument '" + key + "'");
            return;
        }
        arg.setValue(value);
    }

    private static String str(JsonObject o, String key, String def) {
        return (o != null && o.has(key) && !o.get(key).isJsonNull())
            ? o.get(key).getAsString() : def;
    }

    private static int num(JsonObject o, String key, int def) {
        return (o != null && o.has(key) && !o.get(key).isJsonNull())
            ? o.get(key).getAsInt() : def;
    }

    private static boolean bool(JsonObject o, String key, boolean def) {
        return (o != null && o.has(key) && !o.get(key).isJsonNull())
            ? o.get(key).getAsBoolean() : def;
    }

    // -----------------------------------------------------------------------
    // Inner classes
    // -----------------------------------------------------------------------

    private static class PendingBreakpoint {
        final String sourceName;
        final int    line;
        PendingBreakpoint(String s, int l) { sourceName = s; line = l; }
    }
}
