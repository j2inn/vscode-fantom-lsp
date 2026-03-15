package fan.lsp.debug;

import com.google.gson.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.*;

/**
 * DAP message dispatcher.
 *
 * Reads Content-Length framed JSON messages from stdin, dispatches to
 * FantomDebugSession, and writes responses/events back to stdout.
 * sendMessage() is synchronized so the JDI event thread can safely
 * push events while the main read loop is handling a request.
 */
public class DapServer {

    private final InputStream  in;
    private final OutputStream out;
    private final Gson         gson = new GsonBuilder().serializeNulls().create();

    private FantomDebugSession session;
    private int seq = 1;

    /**
     * Single-threaded executor for evaluate requests.
     *
     * invokeToString() calls ObjectReference.invokeMethod() with INVOKE_SINGLE_THREADED.
     * If the target object's toString() acquires a lock held by another suspended thread
     * the call deadlocks and never returns.  Running evaluate on a background thread with
     * a hard timeout lets the main DAP dispatch loop continue processing variables/scopes
     * requests even while an evaluate is stuck.  We use a single-thread executor so at
     * most one invoke is in flight at a time (multiple concurrent invokes risk JDI
     * internal state issues on some JVMs).
     *
     * The stuck thread cannot be interrupted (invokeMethod ignores Thread.interrupt()) and
     * will remain alive until the debug session disconnects, at which point the JDI
     * VMDisconnectedException unblocks it automatically.
     */
    private final ExecutorService evalExecutor = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "dap-eval-thread");
        t.setDaemon(true);
        return t;
    });

    public DapServer() {
        this.in  = System.in;
        this.out = System.out;
    }

    // -----------------------------------------------------------------------
    // Main loop
    // -----------------------------------------------------------------------

    public void run() throws Exception {
        while (true) {
            JsonObject msg = readMessage();
            if (msg == null) {
                System.err.println("[DAP] stdin closed, exiting");
                break;
            }
            handleMessage(msg);
        }
    }

    // -----------------------------------------------------------------------
    // Wire I/O
    // -----------------------------------------------------------------------

    private JsonObject readMessage() throws IOException {
        int contentLength = -1;
        StringBuilder headerBuf = new StringBuilder();
        int prev = -1;
        int c;

        while ((c = in.read()) != -1) {
            if (prev == '\r' && c == '\n') {
                String header = headerBuf.toString().trim();
                if (header.isEmpty()) break; // blank line = end of headers
                if (header.startsWith("Content-Length:")) {
                    contentLength = Integer.parseInt(header.substring("Content-Length:".length()).trim());
                }
                headerBuf = new StringBuilder();
            } else if (c != '\r') {
                headerBuf.append((char) c);
            }
            prev = c;
        }

        if (contentLength < 0) return null;

        byte[] body = in.readNBytes(contentLength);
        String json = new String(body, StandardCharsets.UTF_8);
        System.err.println("[DAP] <<< " + json);
        return JsonParser.parseString(json).getAsJsonObject();
    }

    synchronized void sendMessage(JsonObject msg) {
        try {
            String json = gson.toJson(msg);
            System.err.println("[DAP] >>> " + json);
            byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
            String header = "Content-Length: " + bytes.length + "\r\n\r\n";
            out.write(header.getBytes(StandardCharsets.US_ASCII));
            out.write(bytes);
            out.flush();
        } catch (IOException e) {
            System.err.println("[DAP] send error: " + e.getMessage());
        }
    }

    synchronized int nextSeq() { return seq++; }

    // -----------------------------------------------------------------------
    // Helpers for sending standard message types
    // -----------------------------------------------------------------------

    void sendResponse(JsonObject req, boolean success, JsonObject body) {
        JsonObject resp = new JsonObject();
        resp.addProperty("seq",         nextSeq());
        resp.addProperty("type",        "response");
        resp.addProperty("request_seq", req.get("seq").getAsInt());
        resp.addProperty("success",     success);
        resp.addProperty("command",     req.get("command").getAsString());
        if (body != null) resp.add("body", body);
        sendMessage(resp);
    }

    void sendErrorResponse(JsonObject req, String message) {
        JsonObject body = new JsonObject();
        JsonObject error = new JsonObject();
        error.addProperty("id",     9999);
        error.addProperty("format", message);
        body.add("error", error);
        JsonObject resp = new JsonObject();
        resp.addProperty("seq",         nextSeq());
        resp.addProperty("type",        "response");
        resp.addProperty("request_seq", req.get("seq").getAsInt());
        resp.addProperty("success",     false);
        resp.addProperty("command",     req.get("command").getAsString());
        resp.addProperty("message",     message);
        resp.add("body", body);
        sendMessage(resp);
    }

    public void sendEvent(String event, JsonObject body) {
        JsonObject evt = new JsonObject();
        evt.addProperty("seq",   nextSeq());
        evt.addProperty("type",  "event");
        evt.addProperty("event", event);
        if (body != null) evt.add("body", body);
        sendMessage(evt);
    }

    // -----------------------------------------------------------------------
    // Request dispatch
    // -----------------------------------------------------------------------

    private void handleMessage(JsonObject msg) {
        String type = msg.get("type").getAsString();
        if (!"request".equals(type)) return;

        String     command = msg.get("command").getAsString();
        JsonObject args    = msg.has("arguments") ? msg.getAsJsonObject("arguments") : new JsonObject();

        System.err.println("[DAP] command=" + command);

        try {
            switch (command) {
                case "initialize":        handleInitialize(msg, args);         break;
                case "launch":            handleLaunch(msg, args);             break;
                case "attach":            handleAttach(msg, args);             break;
                case "setBreakpoints":    handleSetBreakpoints(msg, args);     break;
                case "configurationDone": handleConfigurationDone(msg, args);  break;
                case "continue":          handleContinue(msg, args);           break;
                case "next":              handleNext(msg, args);               break;
                case "stepIn":            handleStepIn(msg, args);             break;
                case "stepOut":           handleStepOut(msg, args);            break;
                case "pause":             handlePause(msg, args);              break;
                case "stackTrace":        handleStackTrace(msg, args);         break;
                case "scopes":            handleScopes(msg, args);             break;
                case "variables":         handleVariables(msg, args);          break;
                case "threads":           handleThreads(msg, args);            break;
                case "evaluate":          handleEvaluate(msg, args);           break;
                case "disconnect":        handleDisconnect(msg, args);         break;
                case "terminate":         handleTerminate(msg, args);          break;
                default:
                    System.err.println("[DAP] unhandled command: " + command);
                    sendResponse(msg, true, null);
            }
        } catch (Exception e) {
            System.err.println("[DAP] error in " + command + ": " + e);
            e.printStackTrace(System.err);
            sendErrorResponse(msg, e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName());
        }
    }

    // -----------------------------------------------------------------------
    // Individual handlers
    // -----------------------------------------------------------------------

    private void handleInitialize(JsonObject req, JsonObject args) {
        JsonObject caps = new JsonObject();
        caps.addProperty("supportsConfigurationDoneRequest", true);
        caps.addProperty("supportsTerminateRequest",         true);
        caps.addProperty("supportTerminateDebuggee",         true);
        caps.addProperty("supportsStepBack",                 false);
        caps.addProperty("supportsEvaluateForHovers",        true);
        caps.addProperty("supportsSetVariable",              false);
        sendResponse(req, true, caps);
        sendEvent("initialized", null);
    }

    private void handleLaunch(JsonObject req, JsonObject args) throws Exception {
        if (session != null) session.terminate();
        session = new FantomDebugSession(this);
        session.launch(args);
        sendResponse(req, true, null);
    }

    private void handleAttach(JsonObject req, JsonObject args) throws Exception {
        if (session != null) session.terminate();
        session = new FantomDebugSession(this);
        session.attach(args);
        sendResponse(req, true, null);
    }

    private void handleSetBreakpoints(JsonObject req, JsonObject args) {
        JsonObject body = (session != null)
            ? session.setBreakpoints(args)
            : emptyBreakpointsBody();
        sendResponse(req, true, body);
    }

    private void handleConfigurationDone(JsonObject req, JsonObject args) {
        if (session != null) session.configurationDone();
        sendResponse(req, true, null);
    }

    private void handleContinue(JsonObject req, JsonObject args) {
        // Send response BEFORE resuming: the VM may fire a stopped event almost
        // immediately, and VS Code must receive the continue response first.
        JsonObject body = new JsonObject();
        body.addProperty("allThreadsContinued", true);
        sendResponse(req, true, body);
        long threadId = args.has("threadId") ? args.get("threadId").getAsLong() : -1;
        if (session != null) session.resume(threadId);
    }

    private void handleNext(JsonObject req, JsonObject args) {
        // Send response BEFORE resuming: a step event can fire before we return
        // from session.next(), causing VS Code to receive "stopped" before the
        // "next" response — which makes it silently drop the stopped event.
        sendResponse(req, true, null);
        long threadId = args.has("threadId") ? args.get("threadId").getAsLong() : -1;
        if (session != null) session.next(threadId);
    }

    private void handleStepIn(JsonObject req, JsonObject args) {
        sendResponse(req, true, null);
        long threadId = args.has("threadId") ? args.get("threadId").getAsLong() : -1;
        if (session != null) session.stepIn(threadId);
    }

    private void handleStepOut(JsonObject req, JsonObject args) {
        sendResponse(req, true, null);
        long threadId = args.has("threadId") ? args.get("threadId").getAsLong() : -1;
        if (session != null) session.stepOut(threadId);
    }

    private void handlePause(JsonObject req, JsonObject args) {
        long threadId = args.has("threadId") ? args.get("threadId").getAsLong() : -1;
        if (session != null) session.pause(threadId);
        sendResponse(req, true, null);
    }

    private void handleStackTrace(JsonObject req, JsonObject args) {
        JsonObject body = (session != null)
            ? session.getStackTrace(args)
            : emptyStackBody();
        sendResponse(req, true, body);
    }

    private void handleScopes(JsonObject req, JsonObject args) {
        JsonObject body = (session != null)
            ? session.getScopes(args)
            : emptyScopesBody();
        sendResponse(req, true, body);
    }

    private void handleVariables(JsonObject req, JsonObject args) {
        JsonObject body = (session != null)
            ? session.getVariables(args)
            : emptyVarsBody();
        sendResponse(req, true, body);
    }

    private void handleThreads(JsonObject req, JsonObject args) {
        JsonObject body = (session != null)
            ? session.getThreads()
            : emptyThreadsBody();
        sendResponse(req, true, body);
    }

    private void handleEvaluate(JsonObject req, JsonObject args) {
        if (session == null) {
            sendResponse(req, true, notAvailableBody());
            return;
        }
        // Run evaluate in a background thread with a 3-second timeout.
        // invokeToString() (called for Watch / REPL expressions) uses
        // INVOKE_SINGLE_THREADED and can deadlock on complex objects that
        // acquire locks held by other suspended threads.  Without the timeout
        // the main DAP loop stalls: no variables/scopes responses are ever
        // sent, the Variables panel empties, and the UI appears frozen.
        final FantomDebugSession sess = session;
        Future<JsonObject> future = evalExecutor.submit(() -> sess.evaluate(args));
        JsonObject body;
        try {
            body = future.get(3, TimeUnit.SECONDS);
        } catch (TimeoutException e) {
            // Don't cancel — invokeMethod is not interruptible; the thread stays
            // alive until the VM disconnects.  Just return a visible placeholder.
            System.err.println("[DAP] evaluate timed out for: " +
                (args.has("expression") ? args.get("expression").getAsString() : "?"));
            body = new JsonObject();
            body.addProperty("result", "<timed out — toString() may be deadlocked>");
            body.addProperty("variablesReference", 0);
        } catch (Exception e) {
            System.err.println("[DAP] evaluate error: " + e);
            body = new JsonObject();
            body.addProperty("result", "<error: " + e.getMessage() + ">");
            body.addProperty("variablesReference", 0);
        }
        sendResponse(req, true, body);
    }

    private void handleDisconnect(JsonObject req, JsonObject args) {
        boolean terminate = args.has("terminateDebuggee") && args.get("terminateDebuggee").getAsBoolean();
        if (session != null) { session.disconnect(terminate); session = null; }
        sendResponse(req, true, null);
    }

    private void handleTerminate(JsonObject req, JsonObject args) {
        if (session != null) { session.terminate(); session = null; }
        sendResponse(req, true, null);
    }

    // -----------------------------------------------------------------------
    // Empty body helpers
    // -----------------------------------------------------------------------

    private JsonObject emptyBreakpointsBody() {
        JsonObject b = new JsonObject(); b.add("breakpoints", new JsonArray()); return b;
    }
    private JsonObject emptyStackBody() {
        JsonObject b = new JsonObject(); b.add("stackFrames", new JsonArray()); b.addProperty("totalFrames", 0); return b;
    }
    private JsonObject emptyScopesBody() {
        JsonObject b = new JsonObject(); b.add("scopes", new JsonArray()); return b;
    }
    private JsonObject emptyVarsBody() {
        JsonObject b = new JsonObject(); b.add("variables", new JsonArray()); return b;
    }
    private JsonObject emptyThreadsBody() {
        JsonObject b = new JsonObject(); b.add("threads", new JsonArray()); return b;
    }
    private JsonObject notAvailableBody() {
        JsonObject b = new JsonObject();
        b.addProperty("result", "<not available>");
        b.addProperty("variablesReference", 0);
        return b;
    }
}
