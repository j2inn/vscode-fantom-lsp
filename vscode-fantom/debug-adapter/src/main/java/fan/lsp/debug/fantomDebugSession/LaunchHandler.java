package fan.lsp.debug.fantomDebugSession;

import com.google.gson.*;
import com.sun.jdi.*;
import com.sun.jdi.connect.*;
import com.sun.jdi.request.*;

import fan.lsp.debug.SourceMapper;

import java.io.*;
import java.net.ServerSocket;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Collectors;

/**
 * Handles session lifecycle: launch, attach, shadow FAN_HOME, process teardown.
 *
 * Windows compatibility:
 *  - killProcess():  uses "taskkill /F /T /PID" on Windows instead of
 *    "bash -c kill -KILL -<pid>", which is bash-only.
 *  - linkOrCopy():   wraps Files.createSymbolicLink in a try/catch; on Windows
 *    without Developer Mode or administrator rights symbolic-link creation throws
 *    AccessDeniedException or UnsupportedOperationException, in which case the
 *    entry is copied instead (full copy for directories, file copy for files).
 */
public class LaunchHandler {

    private final SessionContext ctx;
    private final EventProcessor events;
    private final BreakpointManager bps;

    /**
     * True when running on Windows.
     * Used to select the correct process-kill strategy and handle
     * symbolic-link creation restrictions.
     */
    private static final boolean IS_WINDOWS =
        System.getProperty("os.name", "").toLowerCase().contains("win");

    public LaunchHandler(SessionContext ctx, EventProcessor events, BreakpointManager bps) {
        this.ctx    = ctx;
        this.events = events;
        this.bps    = bps;
    }

    // -----------------------------------------------------------------------
    // Public session lifecycle
    // -----------------------------------------------------------------------

    /**
     * Launch a new Fantom process with JDWP enabled, then attach JDI.
     *
     * Expected launch config keys:
     *   fanExe           – path to fan/fin/any Fantom launcher executable (required)
     *   mainClass        – Fantom class to run, e.g. "myPod::Main" (optional)
     *   launcherArgs     – optional string[] inserted between fanExe and mainClass
     *   args             – optional string[] of program arguments (after mainClass)
     *   sourceDir        – workspace root to search for .fan source files
     *   debugPort        – JDWP port (default 5005)
     *   noDebug          – boolean; skip JDWP when true
     *   preLaunchRebuild – boolean; rebuild pod with debug=true before launch
     *   startupTimeout   – seconds to wait for JDWP (default 60)
     */
    public void launch(JsonObject args) throws Exception {
        String  fanExe    = SessionContext.str(args, "fanExe",            "fan");
        String  mainClass = SessionContext.str(args, "mainClass",         "");
        String  sourceDir = SessionContext.str(args, "sourceDir",         ".");
        int     portHint  = SessionContext.num(args, "debugPort",         5005);
        boolean noDebug   = SessionContext.bool(args, "noDebug",          false);
        boolean rebuild   = SessionContext.bool(args, "preLaunchRebuild", false);

        ctx.sourceMapper = new SourceMapper(sourceDir);
        ctx.wasLaunched  = true;

        // ── Port reservation ─────────────────────────────────────────────
        // Keep the ServerSocket OPEN while creating the shadow and building
        // the ProcessBuilder.  Closing it just before pb.start() minimises
        // the window in which another process can steal the port between our
        // "is it free?" test and the JVM JDWP agent binding it.
        ServerSocket portReservation = null;
        int port = -1;
        if (!noDebug) {
            portReservation = reservePort(portHint);
            port = portReservation.getLocalPort();
        }

        ctx.consoleLog("[Fantom Debug] JDWP port: " + (port < 0 ? "disabled" : port));

        // Optional pre-launch rebuild with a build-only shadow (no JDWP)
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

        // Create the run-time shadow FAN_HOME with the reserved port
        String shadowHome = createDebugShadowHome(fanExe, port);
        if (shadowHome == null && !noDebug) {
            if (portReservation != null) try { portReservation.close(); } catch (IOException ignore) {}
            throw new RuntimeException(
                "Could not create debug shadow FAN_HOME for " + fanExe +
                ". Check stderr for details.");
        }
        if (shadowHome != null) {
            ctx.consoleLog("[Fantom Debug] Shadow FAN_HOME: " + shadowHome);
        }

        List<String> cmd = new ArrayList<>();
        cmd.add(fanExe);
        if (args.has("launcherArgs")) {
            for (JsonElement a : args.getAsJsonArray("launcherArgs"))
                cmd.add(a.getAsString());
        }
        if (!mainClass.isEmpty()) cmd.add(mainClass);
        if (args.has("args")) {
            for (JsonElement a : args.getAsJsonArray("args"))
                cmd.add(a.getAsString());
        }

        ProcessBuilder pb = new ProcessBuilder(cmd);
        pb.redirectErrorStream(false);

        String cmdDisplay = String.join(" ", cmd);
        ctx.consoleLog("[Fantom Debug] Launching: " + cmdDisplay);
        System.err.println("[JDI] Launch command: " + cmdDisplay);

        if (shadowHome != null) {
            pb.environment().put("FAN_HOME", shadowHome);
        }

        // Release the reserved port NOW — just before the process starts.
        // The window between close() and the JVM JDWP bind is microseconds.
        if (portReservation != null) {
            try { portReservation.close(); } catch (IOException ignore) {}
        }

        ctx.fanProcess = pb.start();
        pipeProcessOutput(ctx.fanProcess);

        if (noDebug) return;

        attachWithRetry("localhost", port,
            SessionContext.num(args, "startupTimeout", 60));

        // After attaching, strip java.options from the shadow config.props so
        // child JVMs (docs generator, projkit, etc.) don't try to bind the
        // same JDWP port and fail with "Address already in use".
        if (shadowHome != null) {
            stripJdwpFromShadowConfig(shadowHome);
        }
    }

    /**
     * Attach to an existing Fantom JVM already listening on a JDWP socket.
     *
     * Expected attach config keys:
     *   host       – default "localhost"
     *   port       – default 5005
     *   sourceDir  – workspace root
     */
    public void attach(JsonObject args) throws Exception {
        String host      = SessionContext.str(args, "host",      "localhost");
        int    port      = SessionContext.num(args, "port",      5005);
        String sourceDir = SessionContext.str(args, "sourceDir", ".");

        ctx.sourceMapper = new SourceMapper(sourceDir);
        attachToVm(host, port, 10000);
    }

    public void disconnect(boolean terminateDebuggee) {
        cleanup(ctx.wasLaunched || terminateDebuggee);
    }

    public void terminate() {
        cleanup(true);
    }

    // -----------------------------------------------------------------------
    // Attach helpers
    // -----------------------------------------------------------------------

    /**
     * Poll for the JDWP agent to become ready, retrying every 500 ms.
     *
     * @param timeoutSecs  total seconds to wait (default 60)
     */
    private void attachWithRetry(String host, int port, int timeoutSecs) throws Exception {
        long      deadline  = System.currentTimeMillis() + timeoutSecs * 1000L;
        int       attempt   = 0;
        Exception lastError = null;

        ctx.consoleLog("[Fantom Debug] Waiting for JVM on port " + port
            + " (up to " + timeoutSecs + "s)...");

        while (System.currentTimeMillis() < deadline) {
            if (ctx.fanProcess != null && !ctx.fanProcess.isAlive()) {
                throw new RuntimeException(
                    "Fantom process exited before the JDWP agent became ready (exit code "
                    + ctx.fanProcess.exitValue() + "). Check the Debug Console for output.");
            }
            attempt++;
            try {
                attachToVm(host, port, 1500);
                ctx.consoleLog("[Fantom Debug] Connected to JVM after " + attempt + " attempt(s).");
                return;
            } catch (Exception e) {
                lastError = e;
                if (attempt % 5 == 0) {
                    ctx.consoleLog("[Fantom Debug] Still waiting... (" + attempt + " attempts, "
                        + ((System.currentTimeMillis() - (deadline - timeoutSecs * 1000L)) / 1000)
                        + "s elapsed)");
                }
                Thread.sleep(500);
            }
        }

        throw new RuntimeException(
            "Timed out waiting for JDWP on port " + port + " after " + timeoutSecs + "s ("
            + attempt + " attempts). Last error: " + lastError
            + ". Add \"startupTimeout\": 120 to launch.json for slow-starting apps.");
    }

    private void attachToVm(String host, int port, int timeoutMs) throws Exception {
        VirtualMachineManager vmm = Bootstrap.virtualMachineManager();

        AttachingConnector connector = vmm.attachingConnectors().stream()
            .filter(c -> c.name().equals("com.sun.jdi.SocketAttach"))
            .findFirst()
            .orElseThrow(() -> new RuntimeException("SocketAttach connector not found"));

        Map<String, Connector.Argument> cargs = connector.defaultArguments();
        setArg(cargs, "hostname", host);
        setArg(cargs, "port",     String.valueOf(port));
        setArg(cargs, "timeout",  String.valueOf(timeoutMs));

        ctx.vm = connector.attach(cargs);
        System.err.println("[JDI] Attached: " + ctx.vm.name() + " " + ctx.vm.version());

        // Only subscribe to fan.* class-prepare events.
        // Without this filter the JVM sends a ClassPrepareEvent for every class
        // loaded (java.*, jdk.*, thousands of framework classes on FIN startup).
        // SUSPEND_NONE: we don't need the class-loader thread suspended just to
        // install a breakpoint — installPendingBreakpoints() uses the ReferenceType
        // object which is available regardless of thread state.
        ClassPrepareRequest cpr = ctx.vm.eventRequestManager().createClassPrepareRequest();
        cpr.addClassFilter("fan.*");
        cpr.setSuspendPolicy(EventRequest.SUSPEND_NONE);
        cpr.enable();

        events.start();
    }

    // -----------------------------------------------------------------------
    // Cleanup / teardown
    // -----------------------------------------------------------------------

    private void cleanup(boolean kill) {
        if (ctx.vm != null) {
            try { ctx.vm.dispose(); } catch (Exception ignore) {}
            ctx.vm = null;
        }
        if (ctx.eventThread != null) {
            ctx.eventThread.interrupt();
            ctx.eventThread = null;
        }
        if (ctx.fanProcess != null && kill) {
            killProcess(ctx.fanProcess);
            ctx.fanProcess = null;
        }
        ctx.stoppedThread = null;
        if (ctx.debugShadowHome != null) {
            try { deleteRecursively(Paths.get(ctx.debugShadowHome)); } catch (Exception ignore) {}
            ctx.debugShadowHome = null;
        }
        if (kill) ctx.sendTerminated();
    }

    /**
     * Kill a process and all its descendants.
     *
     * On Windows:  "taskkill /F /T /PID <pid>" — kills the process tree
     *              forcefully.  The equivalent of SIGKILL + kill-group, but
     *              native to the Windows job-objects / process-tree model.
     *
     * On Unix/Mac: "bash -c kill -KILL -<pid>; kill -KILL <pid>" — sends
     *              SIGKILL to the process group (pgid == pid for bash-started
     *              processes) as well as the process itself, covering any
     *              child JVMs or worker processes in the group hierarchy.
     *
     * Both paths also walk ProcessHandle.descendants() and call destroyForcibly
     * on each, ensuring processes that ended up outside the group are caught.
     */
    private static void killProcess(Process process) {
        long pid = process.pid();
        if (IS_WINDOWS) {
            try {
                new ProcessBuilder("taskkill", "/F", "/T", "/PID", String.valueOf(pid))
                    .start().waitFor();
            } catch (Exception ignore) {}
        } else {
            try {
                new ProcessBuilder("bash", "-c",
                        "kill -KILL -" + pid + " 2>/dev/null; "
                        + "kill -KILL " + pid + " 2>/dev/null")
                    .start().waitFor();
            } catch (Exception ignore) {}
        }
        // Also terminate any descendants visible via ProcessHandle
        try {
            process.toHandle().descendants()
                .forEach(h -> { try { h.destroyForcibly(); } catch (Exception e) {} });
        } catch (Exception ignore) {}
        process.destroyForcibly();
    }

    // -----------------------------------------------------------------------
    // Shadow FAN_HOME
    // -----------------------------------------------------------------------

    /**
     * Create a temporary shadow FAN_HOME for the debug target process.
     *
     * The shadow directory contains:
     *   lib/          → link/copy of realFanHome/lib/
     *   etc/<subdir>  → link/copy for every entry except sys/
     *   etc/sys/      → real directory so we can override config.props
     *   etc/sys/config.props → debug=true + optional JDWP port
     *   var/          → real dir (isolated lock files, symlinked data dirs)
     *
     * On Windows, "link/copy" means a directory copy when symlink creation
     * is denied (no Developer Mode / no admin rights).
     *
     * @param fanExe    path to the fan/fin executable
     * @param jdwpPort  port to inject into java.options; -1 = no JDWP
     * @return shadow dir path, or null on failure
     */
    private String createDebugShadowHome(String fanExe, int jdwpPort) {
        String fanHomeStr = deriveFanHome(fanExe);
        if (fanHomeStr == null) return null;
        try {
            Path shadow         = Files.createTempDirectory("fantom-debug-home-");
            ctx.debugShadowHome = shadow.toString();
            Path realHome       = Paths.get(fanHomeStr);

            // Symlink (or copy) every top-level entry except etc/ and var/
            Set<String> shallowExpand = new HashSet<>(Arrays.asList("etc", "var"));
            try (DirectoryStream<Path> stream = Files.newDirectoryStream(realHome)) {
                for (Path entry : stream) {
                    String name = entry.getFileName().toString();
                    if (shallowExpand.contains(name)) continue;
                    linkOrCopy(entry.toAbsolutePath(), shadow.resolve(name));
                }
            }

            // var/ — real directory; only subdirectories are symlinked (not
            // plain files), so lock/state files (vm.lock etc.) are absent in
            // the shadow and get created fresh, isolated from the live server.
            Path realVar   = realHome.resolve("var");
            Path shadowVar = shadow.resolve("var");
            Files.createDirectories(shadowVar);
            if (Files.isDirectory(realVar)) {
                try (DirectoryStream<Path> stream = Files.newDirectoryStream(realVar)) {
                    for (Path entry : stream) {
                        if (Files.isDirectory(entry)) {
                            linkOrCopy(entry.toAbsolutePath(),
                                shadowVar.resolve(entry.getFileName()));
                        }
                    }
                }
            }

            // etc/ — real dir; all subdirectories linked/copied except sys/
            Path realEtc   = realHome.resolve("etc");
            Path shadowEtc = shadow.resolve("etc");
            Files.createDirectories(shadowEtc);

            boolean wroteConfigProps = false;
            if (Files.isDirectory(realEtc)) {
                try (DirectoryStream<Path> stream = Files.newDirectoryStream(realEtc)) {
                    for (Path entry : stream) {
                        String name = entry.getFileName().toString();
                        Path   dest = shadowEtc.resolve(name);
                        if ("sys".equals(name)) {
                            Files.createDirectories(dest);
                            try (DirectoryStream<Path> sysStream =
                                    Files.newDirectoryStream(entry)) {
                                for (Path sysFile : sysStream) {
                                    String sysName = sysFile.getFileName().toString();
                                    Path   sysDest = dest.resolve(sysName);
                                    if ("config.props".equals(sysName)) {
                                        writeConfigProps(sysDest,
                                            Files.readAllBytes(sysFile), jdwpPort);
                                        wroteConfigProps = true;
                                    } else {
                                        linkOrCopy(sysFile.toAbsolutePath(), sysDest);
                                    }
                                }
                            }
                        } else {
                            linkOrCopy(entry.toAbsolutePath(), dest);
                        }
                    }
                }
            }

            // Always ensure etc/sys/config.props exists in the shadow
            if (!wroteConfigProps) {
                Path shadowSys = shadowEtc.resolve("sys");
                Files.createDirectories(shadowSys);
                writeConfigProps(shadowSys.resolve("config.props"), new byte[0], jdwpPort);
            }

            System.err.println("[JDI] Debug shadow FAN_HOME: " + shadow);
            return shadow.toString();

        } catch (Exception e) {
            System.err.println("[JDI] Warning: could not create debug shadow home: " + e);
            e.printStackTrace(System.err);
            if (ctx.debugShadowHome != null) {
                try { deleteRecursively(Paths.get(ctx.debugShadowHome)); }
                catch (Exception ignore) {}
                ctx.debugShadowHome = null;
            }
            return null;
        }
    }

    /**
     * Create a symbolic link from {@code target} pointing to {@code source}.
     *
     * On Windows without Developer Mode or administrator rights,
     * Files.createSymbolicLink() throws AccessDeniedException or
     * UnsupportedOperationException.  The fallback copies the content instead:
     * a full recursive copy for directories, a simple file copy for files.
     * This means changes to the real FAN_HOME are not reflected in the shadow
     * after creation, but for a single debug session that is acceptable.
     */
    private static void linkOrCopy(Path source, Path target) throws IOException {
        try {
            Files.createSymbolicLink(target, source);
        } catch (UnsupportedOperationException | java.nio.file.AccessDeniedException e) {
            // Windows doesn't allow symlinks without elevated permissions:
            // fall back to a copy so the shadow still works.
            if (Files.isDirectory(source)) {
                copyDirectory(source, target);
            } else {
                Files.copy(source, target,
                    java.nio.file.StandardCopyOption.COPY_ATTRIBUTES,
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            }
        }
    }

    /** Recursively copy {@code source} directory to {@code target}. */
    private static void copyDirectory(Path source, Path target) throws IOException {
        Files.createDirectories(target);
        try (DirectoryStream<Path> stream = Files.newDirectoryStream(source)) {
            for (Path entry : stream)
                linkOrCopy(entry.toAbsolutePath(), target.resolve(entry.getFileName()));
        }
    }

    /** Write a shadow etc/sys/config.props: strip existing java.options, add debug=true, inject JDWP. */
    private static void writeConfigProps(Path dest, byte[] originalBytes, int jdwpPort)
            throws IOException {
        String original = new String(originalBytes, java.nio.charset.StandardCharsets.UTF_8);
        String modified = Arrays.stream(original.split("\r?\n"))
            .filter(line -> !line.trim().startsWith("java.options"))
            .collect(Collectors.joining("\n"));
        if (!modified.contains("debug=true"))
            modified = modified.stripTrailing() + "\ndebug=true\n";
        if (jdwpPort > 0) {
            modified = modified.stripTrailing()
                + "\njava.options=-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address="
                + jdwpPort + "\n";
        }
        Files.write(dest, modified.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }

    /** Rewrite the shadow etc/sys/config.props to remove java.options (called after attach). */
    private void stripJdwpFromShadowConfig(String shadowHome) {
        try {
            Path cfg = Paths.get(shadowHome, "etc", "sys", "config.props");
            if (!Files.exists(cfg)) return;
            String content = new String(Files.readAllBytes(cfg),
                java.nio.charset.StandardCharsets.UTF_8);
            String stripped = Arrays.stream(content.split("\r?\n"))
                .filter(line -> !line.trim().startsWith("java.options"))
                .collect(Collectors.joining("\n")) + "\n";
            Files.write(cfg, stripped.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            ctx.consoleLog("[Fantom Debug] Stripped JDWP from shadow config.props "
                + "(child processes won't try to bind the debug port).");
        } catch (Exception e) {
            System.err.println("[JDI] Warning: could not strip JDWP from shadow config.props: " + e);
        }
    }

    // -----------------------------------------------------------------------
    // Rebuild helper
    // -----------------------------------------------------------------------

    /**
     * Run 'fan build.fan' in sourceDir using the shadow FAN_HOME (debug=true),
     * so the rebuilt pod contains LocalVariableTable entries.
     */
    private void rebuildWithDebug(String fanExe, String sourceDir, String fanHome) {
        File buildFile = new File(sourceDir, "build.fan");
        if (!buildFile.exists()) {
            System.err.println("[Debug] No build.fan in " + sourceDir
                + " — skipping pre-launch rebuild");
            return;
        }
        ctx.consoleLog("[Fantom Debug] Rebuilding with debug=true for local variable support...");
        try {
            ProcessBuilder pb = new ProcessBuilder(fanExe, "build.fan");
            pb.directory(new File(sourceDir));
            pb.redirectErrorStream(true);
            if (fanHome != null) pb.environment().put("FAN_HOME", fanHome);
            Process proc = pb.start();
            try (BufferedReader r = new BufferedReader(
                    new InputStreamReader(proc.getInputStream()))) {
                String line;
                while ((line = r.readLine()) != null) ctx.consoleLog(line);
            }
            int code = proc.waitFor();
            ctx.consoleLog(code == 0
                ? "[Fantom Debug] Rebuild successful — local variables now visible."
                : "[Fantom Debug] Rebuild exited with code " + code);
        } catch (Exception e) {
            System.err.println("[Debug] Pre-launch rebuild failed: " + e);
        }
    }

    // -----------------------------------------------------------------------
    // Process I/O piping
    // -----------------------------------------------------------------------

    private void pipeProcessOutput(Process process) {
        Thread out = new Thread(() -> {
            try (BufferedReader r = new BufferedReader(
                    new InputStreamReader(process.getInputStream()))) {
                String line;
                while ((line = r.readLine()) != null) {
                    JsonObject body = new JsonObject();
                    body.addProperty("category", "stdout");
                    body.addProperty("output",   line + "\n");
                    ctx.server.sendEvent("output", body);
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
                    ctx.server.sendEvent("output", body);
                }
            } catch (IOException ignore) {}
        }, "process-stderr");
        err.setDaemon(true);
        err.start();
    }

    // -----------------------------------------------------------------------
    // Static helpers
    // -----------------------------------------------------------------------

    /** Derive FAN_HOME as the grandparent directory of the fan executable. */
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

    /** Recursively delete a path without following symlinks into their targets. */
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
     * Reserve a TCP port by holding a ServerSocket.
     * Tries {@code preferred} first; falls back to an OS-assigned port if taken.
     * Caller MUST close the socket immediately before starting the target process.
     */
    private static ServerSocket reservePort(int preferred) throws IOException {
        try {
            ServerSocket s = new ServerSocket();
            s.setReuseAddress(true);
            s.bind(new java.net.InetSocketAddress(preferred));
            return s;
        } catch (IOException e) {
            ServerSocket s = new ServerSocket();
            s.setReuseAddress(true);
            s.bind(new java.net.InetSocketAddress(0));
            return s;
        }
    }

    private static void setArg(Map<String, Connector.Argument> cargs, String key, String value) {
        Connector.Argument arg = cargs.get(key);
        if (arg == null) {
            System.err.println("[JDI] WARNING: connector has no argument '" + key + "'");
            return;
        }
        arg.setValue(value);
    }
}
