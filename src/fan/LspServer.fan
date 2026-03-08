using concurrent

**
** LspServer - Core LSP server orchestrator
**
class LspServer
{
  ** Document manager
  private DocumentManager docMgr

  ** Project index (central source of truth for project structure and symbols)
  private ProjectIndex projectIndex

  ** Diagnostic service
  private DiagnosticService diagnostics

  ** Completion service
  private CompletionService completion

  ** Definition service
  private DefinitionService definition

  ** Hover service
  private HoverService hoverService

  ** Pod watcher service
  private PodWatchService podWatcher

  ** Code action service
  private CodeActionService codeActionSvc

  new make(
    DocumentManager docMgr,
    ProjectIndex projectIndex,
    DiagnosticService diagnostics,
    CompletionService completion,
    DefinitionService definition,
    HoverService hoverService,
    PodWatchService podWatcher,
    CodeActionService codeActionSvc)
  {
    this.docMgr = docMgr
    this.projectIndex = projectIndex
    this.diagnostics = diagnostics
    this.completion = completion
    this.definition = definition
    this.hoverService = hoverService
    this.podWatcher = podWatcher
    this.codeActionSvc = codeActionSvc
  }

  ** Output stream for sending responses
  private OutStream out := Env.cur.out

  ** Shared actor pool for background work and the write-serializer actor.
  private ActorPool bgPool := ActorPool()

  **
  ** Single actor that owns all stdout writes.  Both the main thread and
  ** any background threads send messages here, so writes are serialised
  ** through the actor's single-message-at-a-time queue and never interleave
  ** in the LSP byte stream.  The 'out' stream is wrapped in Unsafe because
  ** OutStream is mutable (non-const) and cannot cross an actor boundary
  ** directly; the actor unwraps it to do the actual write.
  **
  private Actor writerActor := Actor(bgPool) |msg->Obj?| {
    pair := ((Unsafe)msg).val as Obj?[]
    if (pair != null)
    {
      outStream := pair[0] as OutStream
      message   := pair[1] as Str:Obj?
      if (outStream != null && message != null)
        LspProtocol.writeMessage(outStream, message)
    }
    return null
  }

  ** Server initialized flag
  private Bool initialized := false

  ** Workspace root URI (from initialize params)
  private Str? workspaceRootUri

  ** Fan executable path (from initializationOptions)
  private Str? fanPath

  ** Build target (from initializationOptions, e.g. "compile" or empty for default)
  private Str? fanBuildTarget

  ** Debounce timer: tracks the pending change and idle window for diagnostics.
  private DebounceTimer debounce := DebounceTimer()

  ** Pedantic mode: warn on untyped := declarations (from initializationOptions)
  private Bool pedanticMode := false

  ** Whether to report unused 'using' imports (from initializationOptions / fan.config.json)
  private Bool enableUnusedImport := true

  ** Platform-aware relative URI for fan executable (fan.bat on Windows, fan on Unix)
  private static const Uri fanBinUri := isWindows ? `bin/fan.bat` : `bin/fan`

  ** True if running on Windows
  private static const Bool isWindows := Env.cur.os == "win32"

  ** Track files with published build diagnostics (to clear stale ones)
  private Str[] buildDiagFiles := Str[,]

  ** Per-file analysis diagnostics (single-file + cross-file), keyed by URI.
  ** Used by runBuild to merge build diagnostics with existing analysis results.
  private Str:LspDiagnostic[] analysisDiags := [:]

  ** Next ID for server-initiated requests
  private Int nextRequestId := 1

  ** Pending server-initiated requests: id -> filename-to-URI map
  private Int:Str:Str pendingRequests := [:]

  ** Pod watcher started flag
  private Bool podWatchStarted := false


  **
  ** Handle an incoming message.
  ** Before dispatching, flush any pending debounced diagnostics whose
  ** idle window has expired — this handles the case where the user stops
  ** typing without saving (no more didChange events arrive), but VS Code
  ** still sends other messages such as hover or completion requests.
  **
  Void handleMessage(Str:Obj? message)
  {
    try
    {
      flushPendingDiagIfReady
      if (LspProtocol.isResponse(message))
        handleResponse(message)
      else if (LspProtocol.isRequest(message))
        handleRequest(message)
      else if (LspProtocol.isNotification(message))
        handleNotification(message)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error handling message: $e")
    }
  }

  **
  ** Flush pending debounced diagnostics if the idle window has expired.
  ** Called at the start of every incoming message so that any server
  ** activity (hover, completion, etc.) triggers the deferred analysis.
  **
  private Void flushPendingDiagIfReady()
  {
    pending := debounce.take
    if (pending == null) return
    doFlush(pending[0], pending[1])
  }

  **
  ** Called by the background debounce timer via Actor/Unsafe.
  ** Same debounce check as flushPendingDiagIfReady so that timers
  ** scheduled for earlier keystrokes self-cancel when the user keeps typing.
  **
  internal Void timedFlush()
  {
    pending := debounce.take
    if (pending == null) return
    doFlush(pending[0], pending[1])
  }

  **
  ** Run single-file analysis for the given URI/text and publish diagnostics.
  ** Called from both the main message loop and the background timer actor.
  ** Does NOT modify the project index — that happens only on the main thread
  ** (handleDidSave/handleDidOpen/backgroundInit) to avoid concurrent map
  ** mutation that would corrupt completions.
  **
  private Void doFlush(Str uri, Str text)
  {
    singleFileDiags := diagnostics.analyze(uri, text, projectIndex, pedanticMode, enableUnusedImport)
    analysisDiags[uri] = singleFileDiags
    publishDiagnosticsList(uri, singleFileDiags)
  }

  **
  ** Schedule a background actor to fire after debounceMs and call timedFlush.
  ** One timer is created per keystroke; those that fire while a newer change
  ** is still within the debounce window self-cancel (timedFlush returns early).
  **
  private Void scheduleFlushTimer()
  {
    ref := Unsafe(this)
    Actor(bgPool) |msg->Obj?| {
      srv := ((Unsafe)msg).val as LspServer
      if (srv != null) srv.timedFlush
      return null
    }.sendLater(Duration(debounce.debounceMs * 1_000_000), ref)
  }

  **
  ** Handle a request message
  **
  private Void handleRequest(Str:Obj? message)
  {
    id := message["id"]
    method := message["method"] as Str
    params := message["params"] as Str:Obj?

    LspProtocol.logInfo("Request: $method")

    try
    {
      result := dispatchRequest(method, params)
      response := LspProtocol.createResponse(id, result)
      writeSync(response)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error handling request: $e")
      errorResponse := LspProtocol.createErrorResponse(id, -32603, e.toStr)
      writeSync(errorResponse)
    }
  }

  **
  ** Handle a notification message
  **
  private Void handleNotification(Str:Obj? message)
  {
    method := message["method"] as Str
    params := message["params"] as Str:Obj?

    LspProtocol.logInfo("Notification: $method")

    try
    {
      dispatchNotification(method, params)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error handling notification: $e")
    }
  }

  **
  ** Handle a response to a server-initiated request (e.g. showMessageRequest)
  **
  private Void handleResponse(Str:Obj? message)
  {
    id := message["id"] as Int
    if (id == null) return

    fileMap := pendingRequests.remove(id)
    if (fileMap == null) return

    // The result is the selected action, or null if dismissed
    result := message["result"] as Str:Obj?
    if (result == null) return

    title := result["title"] as Str
    if (title == null) return

    fileUri := fileMap[title]
    if (fileUri == null) return

    LspProtocol.logInfo("Opening file from build error: $fileUri")
    showDocument(fileUri)
  }

  **
  ** Dispatch request to appropriate handler
  **
  private Obj? dispatchRequest(Str method, Str:Obj? params)
  {
    switch (method)
    {
      case "initialize":
        return handleInitialize(params)
      case "shutdown":
        return handleShutdown
      case "textDocument/completion":
        return handleCompletion(params)
      case "textDocument/definition":
        return handleDefinition(params)
      case "textDocument/hover":
        return handleHover(params)
      case "textDocument/codeAction":
        return handleCodeAction(params)
      default:
        LspProtocol.logInfo("Unhandled request: $method")
        return null
    }
  }

  **
  ** Dispatch notification to appropriate handler
  **
  private Void dispatchNotification(Str method, Str:Obj? params)
  {
    switch (method)
    {
      case "initialized":
        handleInitialized
      case "exit":
        handleExit
      case "textDocument/didOpen":
        handleDidOpen(params)
      case "textDocument/didChange":
        handleDidChange(params)
      case "textDocument/didSave":
        handleDidSave(params)
      case "textDocument/didClose":
        handleDidClose(params)
      case "workspace/didChangeWatchedFiles":
        handleDidChangeWatchedFiles(params)
      default:
        LspProtocol.logInfo("Unhandled notification: $method")
    }
  }

  **
  ** Handle initialize request
  **
  private Str:Obj? handleInitialize(Str:Obj? params)
  {
    LspProtocol.logInfo("Initializing Fantom Language Server")

    // Extract workspace root URI
    workspaceRootUri = params["rootUri"] as Str
    if (workspaceRootUri == null)
    {
      rootPath := params["rootPath"] as Str
      if (rootPath != null)
        workspaceRootUri = LspUtil.fileToUri(File.os(rootPath))
    }
    LspProtocol.logInfo("Workspace root: $workspaceRootUri")

    // Read initializationOptions
    initOptions := params["initializationOptions"] as Str:Obj?
    if (initOptions != null)
    {
      fanPath = initOptions["fanPath"] as Str
      fanBuildTarget = initOptions["fanBuildTarget"] as Str
      dbMs := initOptions["debounceMs"] as Int
      if (dbMs != null && dbMs > 0) debounce.debounceMs = dbMs
      pm := initOptions["pedanticMode"]
      if (pm is Bool) pedanticMode = (Bool)pm
      ui := initOptions["enableUnusedImport"]
      if (ui is Bool) enableUnusedImport = (Bool)ui
      LspProtocol.logInfo("fanPath: $fanPath, fanBuildTarget: $fanBuildTarget, debounceMs: $debounce.debounceMs, pedanticMode: $pedanticMode, enableUnusedImport: $enableUnusedImport")
    }

    // Initialize project index
    if (workspaceRootUri != null)
      projectIndex.init(workspaceRootUri)

    return [
      "capabilities": [
        "textDocumentSync": [
          "openClose": true,
          "change": 1, // Full document sync
          "save": true
        ],
        "completionProvider": [
          "triggerCharacters": completionTriggerCharacters
        ],
        "diagnosticProvider": [:],
        "definitionProvider": true,
        "hoverProvider": true,
        "codeActionProvider": true
      ],
      "serverInfo": [
        "name": "Fantom Language Server",
        "version": "0.2.0"
      ]
    ]
  }

  **
  ** Completion trigger characters for both member access and identifier
  ** completion while typing local variables / parameters.
  **
  private Str[] completionTriggerCharacters()
  {
    return [
      ".", "_",
      "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
      "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
      "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
      "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"
    ]
  }

  **
  ** Handle initialized notification.
  ** Returns immediately so the main loop stays responsive to VS Code requests
  ** (e.g. textDocument/didOpen) while heavy work runs in the background.
  **
  private Void handleInitialized()
  {
    initialized = true
    LspProtocol.logInfo("Server initialized — spawning background init")

    startPodWatcher

    // Wrap 'this' in Unsafe so it can cross the actor boundary.
    // The actor closure must not close over any mutable state; the server
    // reference is passed as the message instead.
    ref := Unsafe(this)
    bgActor := Actor(bgPool) |msg->Obj?| {
      srv := ((Unsafe)msg).val as LspServer
      if (srv != null) srv.backgroundInit
      return null
    }
    bgActor.send(ref)
  }

  ** Start polling for pod changes across the full Fantom path.
  private Void startPodWatcher()
  {
    if (podWatchStarted) return
    podWatchStarted = true
    podWatcher.start(bgPool) |->| { onPodChanged }
  }

  **
  ** Handle lib/fan change detection by re-indexing the project.
  **
  private Void onPodChanged()
  {
    try
    {
      LspProtocol.logInfo("lib/fan changed — re-indexing")
      showMessage("lib/fan changed. Re-indexing", 3)
      PodTypeCache.cur.evictStale
      projectIndex.indexAll
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Pod re-index error: $e")
    }
  }

  **
  ** Run heavyweight initialization tasks in a background thread.
  ** Called by the background actor spawned in handleInitialized.
  **
  internal Void backgroundInit()
  {
    try
    {
      sendProgress("begin", "Indexing project sources\u2026")

      LspProtocol.logInfo("backgroundInit: indexing project...")
      projectIndex.indexAll

      // Advance to 25% and stream per-pod messages while loading
      sendProgress("report", "Loading pod types\u2026", 25)
      LspProtocol.logInfo("backgroundInit: preloading pods...")
      preloadAvailablePods

      sendProgress("report", "Analyzing files\u2026", 35)
      LspProtocol.logInfo("backgroundInit: analyzing all files...")
      dependentErrorFiles := analyzeAndValidateAllFiles

      sendProgress("report", "Build check\u2026", 25)
      // Run full project build check on workspace open — show popup at boot
      runBuild(dependentErrorFiles, true)

      sendProgress("end", "Ready")
      showMessage("Fantom LSP: indexing complete", 3)
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Error during background init: $e")
      sendProgress("end", "Init failed")
      showMessage("Fantom LSP: init error \u2014 $e", 1)
    }
  }

  **
  ** Send a fantom/progress notification to drive the extension's progress bar.
  ** kind: "begin" | "report" | "end"
  ** increment: percentage points to advance the bar (ignored for begin/end)
  **
  private Void sendProgress(Str kind, Str message, Int increment := 0)
  {
    params := Str:Obj?["kind": kind, "message": message]
    if (increment > 0) params["increment"] = increment
    writeSync(LspProtocol.createNotification("fantom/progress", params))
  }

  **
  ** Pre-load all pods from lib/fan/ into the runtime so that member
  ** completion for external pods is fast from the first request.
  **
  private Void preloadAvailablePods()
  {
    try
    {
      podFiles := LspUtil.allPodFiles
      if (podFiles.isEmpty) return
      podFiles.each |f|
      {
        sendProgress("report", "Loading pod: ${f.basename}\u2026")
        try { Pod.find(f.basename, false) } catch {}
      }
      LspProtocol.logInfo("Preloaded ${podFiles.size} pods from Fantom path")
    }
    catch (Err e) { LspProtocol.logInfo("Error preloading pods: $e") }
  }

  private Obj? handleShutdown()
  {
    LspProtocol.logInfo("Shutting down")
    return null
  }

  private Void handleExit()
  {
    LspProtocol.logInfo("Exiting")
    Env.cur.exit(0)
  }

  **
  ** Handle textDocument/didOpen notification
  **
  private Void handleDidOpen(Str:Obj? params)
  {
    textDocument := params["textDocument"] as Str:Obj?
    if (textDocument == null) return

    item := TextDocumentItem.fromMap(textDocument)
    if (item == null) return

    // Normalize URI before storing so all subsequent lookups (completion,
    // hover, definition) find the document regardless of drive-letter case
    // or slash format differences sent by VSCode on Windows.
    item.uri = LspUtil.normalizeFileUri(item.uri)

    docMgr.open(item)
    changedTypes := projectIndex.indexFile(item.uri, item.text)
    publishDiagnostics(item.uri, item.text)

    // Warn if the file is not part of the indexed project
    if (!projectIndex.isProjectFile(item.uri))
    {
      reason := projectIndex.pods.isEmpty
        ? "no build.fan files found in workspace"
        : "file is outside all pod srcDirs"
      showMessage("Fantom LSP: ${item.uri} is not indexed ($reason). Diagnostics may be inaccurate.", 2)
    }
  }

  **
  ** Handle textDocument/didChange notification.
  **
  ** Two-phase strategy, both gated by the same 'debounceMs' idle window
  ** (configurable via fan.config.json "debounceTime", default 2 s).
  ** While the user is actively typing the change is stored but no analysis
  ** runs, keeping the editor responsive.  Once typing pauses:
  **
  **   Phase 1 — single-file analysis on the current file.
  **     Covers syntax errors, method-arg counts, and cross-file references
  **     validated against the cached project index.  Results are published
  **     first so the developer sees feedback as fast as possible.
  **
  **   Phase 2 — full project re-index + analysis of all files.
  **     Catches errors that depend on cross-file type resolution
  **     (inheritance chains, 'using' imports, etc.).
  **
  private Void handleDidChange(Str:Obj? params)
  {
    textDocument := params["textDocument"] as Str:Obj?
    contentChanges := params["contentChanges"] as Obj?[]
    if (textDocument == null || contentChanges == null) return

    rawUri := textDocument["uri"] as Str
    uri := rawUri != null ? LspUtil.normalizeFileUri(rawUri) : null
    version := textDocument["version"] as Int

    changes := contentChanges.map |change| {
      TextDocumentContentChangeEvent.fromMap(change)
    }

    docMgr.change(uri, changes, version)

    doc := docMgr.get(uri)
    if (doc != null)
    {
      // Always defer — never run analysis on the keystroke itself.
      // A background timer fires after debounceMs; timers from earlier
      // keystrokes self-cancel when the debounce window hasn't elapsed yet.
      debounce.defer(uri, doc.text)
      scheduleFlushTimer
    }
  }

  **
  ** Handle textDocument/didSave notification.
  **
  ** On save, index newly created/updated tokens immediately when the saved
  ** file has no error-severity diagnostics. This keeps cross-file type
  ** resolution current (e.g., newly added classes) without indexing broken
  ** syntax snapshots.
  **
  private Void handleDidSave(Str:Obj? params)
  {
    textDocument := params["textDocument"] as Str:Obj?
    if (textDocument == null) return

    uri := LspUtil.normalizeFileUri(textDocument["uri"] as Str ?: "")

    // Cancel any pending debounced analysis; we're doing a full analysis now.
    debounce.clear

    doc := docMgr.get(uri)
    if (doc != null)
    {
      // Index this saved file only when it is syntactically/semantically valid.
      // New files are included in project metadata via indexSavedFile refresh.
      saveDiags := diagnostics.analyze(uri, doc.text, projectIndex, pedanticMode, enableUnusedImport)
      hasSaveErrors := saveDiags.any |d| { d.severity == DiagnosticSeverity.error }
      projectIndex.indexSavedFile(uri, doc.text, hasSaveErrors)

      // Re-run full diagnostics/build to update dependent files.
      dependentErrorFiles := analyzeAndValidateAllFiles
      runBuild(dependentErrorFiles, false, uri)
    }
  }

  **
  ** Run single-file diagnostics AND cross-file validation for all files,
  ** merging results before publishing. This prevents one pass from
  ** clearing diagnostics published by the other.
  ** Returns list of file names that have cross-file reference errors.
  **
  private Str[] analyzeAndValidateAllFiles()
  {
    errorFiles := Str[,]
    analysisDiags = [:]
    sources := Str:Str[:]

    projectIndex.sourceFiles.each |file|
    {
      fileUri := LspUtil.fileToUri(file)
      if (!file.exists) return

      try
      {
        openDoc := docMgr.get(fileUri)
        source := openDoc != null ? openDoc.text : file.readAllStr
        sources[fileUri] = source

        // Single-file analysis
        diags := diagnostics.analyze(fileUri, source, projectIndex, pedanticMode, enableUnusedImport)

        // Cross-file reference validation
        crossDiags := diagnostics.validateCrossFileReferences(source, projectIndex)
        if (!crossDiags.isEmpty)
          errorFiles.add(file.name)

        // Merge and publish all diagnostics together
        allDiags := LspDiagnostic[,].addAll(diags).addAll(crossDiags)
        analysisDiags[fileUri] = allDiags
        publishDiagnosticsList(fileUri, allDiags)
      }
      catch (Err e)
      {
        LspProtocol.logInfo("Error analyzing ${file.name}: $e")
      }
    }

    // Project-wide check: warn on static const fields with duplicate string values
    try
    {
      dupDiags := diagnostics.checkDuplicateConstValues(sources)
      dupDiags.each |fileDiags, fileUri|
      {
        existing := analysisDiags[fileUri] ?: LspDiagnostic[,]
        existing.addAll(fileDiags)
        analysisDiags[fileUri] = existing
        publishDiagnosticsList(fileUri, existing)
      }
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Duplicate const check error: $e")
    }

    return errorFiles
  }

  **
  ** Run project build (fan build.fan [target]) and publish diagnostics.
  ** showPopups controls whether error/warning notification popups are shown;
  ** pass true only at initial boot so that saves and file-structure changes
  ** don't produce repeated popups.
  ** activeUri is the URI of the file being saved; when set the build is
  ** scoped to that file's pod (pod-level build). When null the primary pod
  ** (or build.all if present) is used.
  **
  private Void runBuild(Str[] dependentErrorFiles := Str[,], Bool showPopups := false, Str? activeUri := null)
  {
    // Resolve which build.fan to run:
    //  1. Pod-level: find the pod that owns the active file.
    //  2. Workspace build.all (root orchestrator) if present.
    //  3. Primary pod's build.fan (backward-compat single-pod behaviour).
    buildFan := null as File
    buildDir := null as File

    if (activeUri != null)
    {
      buildFan = projectIndex.buildFanForFile(activeUri)
      if (buildFan != null) buildDir = buildFan.parent
    }

    if (buildFan == null)
    {
      root := projectIndex.workspaceRoot
      if (root != null)
      {
        candidate := root + `build.all`
        if (candidate.exists) { buildFan = candidate; buildDir = root }
      }
    }

    if (buildFan == null)
    {
      if (projectIndex.baseDir == null) return
      buildFan = projectIndex.baseDir + `build.fan`
      buildDir = projectIndex.baseDir
    }

    if (!buildFan.exists) return

    // Determine fan executable (use fan.bat on Windows)
    fanExe := fanPath != null && !fanPath.isEmpty
      ? fanPath
      : (Env.cur.homeDir + fanBinUri).osPath

    try
    {
      // Build command args
      args := Str[fanExe, buildFan.osPath]
      if (fanBuildTarget != null && !fanBuildTarget.isEmpty)
        args.add(fanBuildTarget)

      LspProtocol.logInfo("Running build: " + args.join(" "))

      tmpFile := File.createTemp("lsp-build-", ".log")
      try
      {
        outStream := tmpFile.out
        p := Process(args)
        p.dir = buildDir
        p.mergeErr = true
        p.out = outStream
        p.run
        p.join
        outStream.flush.close

        output := tmpFile.readAllStr
        LspProtocol.logInfo("Build output: ${output.size} chars")

        // Evict stale pod cache entries after a build — pods may have been
        // rebuilt on disk and their types will be refreshed on next access.
        PodTypeCache.cur.evictStale

        // Parse build output for errors
        fileDiags := Str:LspDiagnostic[][:]
        output.splitLines.each |line|
        {
          parsed := projectIndex.parseBuildErrorLine(line)
          if (parsed != null)
          {
            fileUri := parsed["uri"] as Str
            diag := parsed["diagnostic"] as LspDiagnostic
            if (fileUri != null && diag != null)
            {
              if (!fileDiags.containsKey(fileUri))
                fileDiags[fileUri] = LspDiagnostic[,]
              fileDiags[fileUri].add(diag)
            }
          }
        }

        // Merge build diagnostics with existing analysis diagnostics.
        // For files with build errors, combine with analysis results.
        // For files without build errors, keep their analysis diagnostics.
        newDiagFiles := Str[,]

        // Clear stale build diagnostics and re-publish analysis-only diagnostics
        buildDiagFiles.each |prevUri|
        {
          if (!fileDiags.containsKey(prevUri))
          {
            // No build errors for this file anymore — re-publish analysis diagnostics
            existing := analysisDiags[prevUri]
            publishDiagnosticsList(prevUri, existing ?: LspDiagnostic[,])
          }
        }

        // Publish merged build + analysis diagnostics
        fileDiags.each |buildDiagList, fileUri|
        {
          newDiagFiles.add(fileUri)
          existing := analysisDiags[fileUri] ?: LspDiagnostic[,]
          merged := LspDiagnostic[,].addAll(existing).addAll(buildDiagList)
          publishDiagnosticsList(fileUri, merged)
        }
        buildDiagFiles = newDiagFiles

        // Collect files with errors and warning-only files separately.
        errorFileMap := Str:Str[:]  // files with at least 1 error-severity diagnostic
        warnFileMap  := Str:Str[:]  // files with ONLY warning-severity diagnostics

        // Helper: add a file to the correct map based on the severity of its
        // combined diagnostics.  A file goes to errorFileMap only if it has at
        // least one error; otherwise it goes to warnFileMap (when non-empty).
        addToMap := |Str name, Str uri, LspDiagnostic[] diags|
        {
          if (errorFileMap.containsKey(name)) return  // already classified as error
          if (diags.any |d| { d.severity == DiagnosticSeverity.error })
            errorFileMap[name] = uri
          else if (!diags.isEmpty)
            warnFileMap[name] = uri
        }

        // Build diagnostics: the build output can contain warnings (WARN prefix)
        // as well as errors, so we must check severity here too.
        fileDiags.each |diagList, fileUri|
        {
          slashIdx := fileUri.indexr("/")
          name := slashIdx != null ? fileUri[slashIdx + 1 ..-1] : fileUri
          addToMap(name, fileUri, diagList)
        }

        // Analysis diagnostics (single-file + cross-file)
        analysisDiags.each |diagList, fileUri|
        {
          if (diagList.isEmpty) return
          slashIdx := fileUri.indexr("/")
          name := slashIdx != null ? fileUri[slashIdx + 1 ..-1] : fileUri
          addToMap(name, fileUri, diagList)
        }

        // Dependent error files: files flagged by cross-file reference validation.
        // Only add to errorFileMap when their current analysisDiags confirm errors;
        // if they have only warnings, route them to warnFileMap.
        dependentErrorFiles.each |name|
        {
          if (errorFileMap.containsKey(name) || warnFileMap.containsKey(name)) return
          depFile := projectIndex.sourceFiles.find |f| { f.name == name }
          depUri := depFile != null ? LspUtil.fileToUri(depFile) : ""
          existing := analysisDiags[depUri] ?: LspDiagnostic[,]
          addToMap(name, depUri, existing)
        }

        // Popups are only shown at initial boot to avoid spam on every save/change.
        if (showPopups)
        {
          if (!errorFileMap.isEmpty)
          {
            total := errorFileMap.size
            allFiles := errorFileMap.keys
            fileList := allFiles.size <= 3
              ? allFiles.join(", ")
              : allFiles[0..2].join(", ") + " and ${allFiles.size - 3} other file(s)"
            clickableMap := Str:Str[:]
            allFiles.eachRange(0 ..< 3.min(allFiles.size)) |name|
            {
              clickableMap[name] = errorFileMap[name]
            }
            showMessageRequestWithFiles(1,
              "\uD83D\uDC7B Fantom LSP: Errors found! \u2014 ${total} file(s) with errors: ${fileList}",
              clickableMap)
          }
          else
            showMessage("\uD83D\uDC7B Fantom LSP: No errors found")
        }

        // Yellow popup for files with warnings only — only at boot.
        if (showPopups && !warnFileMap.isEmpty)
        {
          total := warnFileMap.size
          allFiles := warnFileMap.keys
          fileList := allFiles.size <= 3
            ? allFiles.join(", ")
            : allFiles[0..2].join(", ") + " and ${allFiles.size - 3} other file(s)"
          clickableMap := Str:Str[:]
          allFiles.eachRange(0 ..< 3.min(allFiles.size)) |name|
          {
            clickableMap[name] = warnFileMap[name]
          }
          showMessageRequestWithFiles(2,
            "\uD83D\uDC7B Fantom LSP: Warnings found! \u2014 ${total} file(s) with warnings: ${fileList}",
            clickableMap)
        }
      }
      finally
      {
        try { tmpFile.delete } catch {}
      }
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Build error: $e")
    }
  }

  **
  ** Handle textDocument/didClose notification
  **
  private Void handleDidClose(Str:Obj? params)
  {
    textDocument := params["textDocument"] as Str:Obj?
    if (textDocument == null) return

    uri := LspUtil.normalizeFileUri(textDocument["uri"] as Str ?: "")
    docMgr.close(uri)
    publishDiagnostics(uri, null)
  }

  **
  ** Handle workspace/didChangeWatchedFiles notification.
  ** Re-index when .fan files are created or deleted and notify the user.
  **
  private Void handleDidChangeWatchedFiles(Str:Obj? params)
  {
    changes := params["changes"] as Obj?[]
    if (changes == null || changes.isEmpty) return

    // Count created (1) and deleted (3) events; ignore changed (2)
    created := 0
    deleted := 0
    changes.each |change|
    {
      evt := change as Str:Obj?
      if (evt == null) return
      type := evt["type"] as Int
      if (type == 1) created++
      else if (type == 3) deleted++
    }

    if (created == 0 && deleted == 0) return

    // Build a human-readable summary of what changed
    parts := Str[,]
    if (created > 0) { cs := created == 1 ? "" : "s"; parts.add("${created} file${cs} added") }
    if (deleted > 0) { ds := deleted == 1 ? "" : "s"; parts.add("${deleted} file${ds} removed") }
    summary := parts.join(", ")

    LspProtocol.logInfo("File structure changed (${summary}) — re-indexing project")
    showMessage("\uD83D\uDC7B Fantom LSP: File changes detected (${summary}) \u2014 reindexing project...", 3)

    projectIndex.indexAll
    dependentErrorFiles := analyzeAndValidateAllFiles
    runBuild(dependentErrorFiles)
  }

  **
  ** Handle textDocument/completion request
  **
  private [Str:Obj?]? handleCompletion(Str:Obj? params)
  {
    textDocument := params["textDocument"] as Str:Obj?
    position := params["position"] as Str:Obj?
    if (textDocument == null || position == null) return null

    uri := LspUtil.normalizeFileUri(textDocument["uri"] as Str ?: "")
    pos := LspPosition.fromMap(position)

    doc := docMgr.get(uri)
    if (doc == null) return null

    items := completion.complete(uri, pos, doc.text, projectIndex)

    return [
      "isIncomplete": false,
      "items": items.map |item| { item.toMap }
    ]
  }

  **
  ** Handle textDocument/definition request
  **
  private Obj? handleDefinition(Str:Obj? params)
  {
    textDocument := params["textDocument"] as Str:Obj?
    position := params["position"] as Str:Obj?
    if (textDocument == null || position == null) return null

    uri := LspUtil.normalizeFileUri(textDocument["uri"] as Str ?: "")
    pos := LspPosition.fromMap(position)

    doc := docMgr.get(uri)
    if (doc == null) return null

    return definition.findDefinition(uri, pos, doc.text, projectIndex)
  }

  **
  ** Handle textDocument/hover request
  **
  private Obj? handleHover(Str:Obj? params)
  {
    textDocument := params["textDocument"] as Str:Obj?
    position := params["position"] as Str:Obj?
    if (textDocument == null || position == null) return null

    uri := LspUtil.normalizeFileUri(textDocument["uri"] as Str ?: "")
    pos := LspPosition.fromMap(position)

    doc := docMgr.get(uri)
    if (doc == null) return null

    return hoverService.hover(uri, pos, doc.text, projectIndex)
  }

  **
  ** Handle textDocument/codeAction request.
  **
  ** Looks at the identifier token under the given range/position, searches
  ** all pods in lib/fan for a matching public type, and returns one
  ** "Add 'using <pod>'" quick-fix code action per matching pod.
  **
  private Obj? handleCodeAction(Str:Obj? params)
  {
    textDocument := params["textDocument"] as Str:Obj?
    rangeMap := params["range"] as Str:Obj?
    if (textDocument == null || rangeMap == null) return [,]

    uri := LspUtil.normalizeFileUri(textDocument["uri"] as Str ?: "")
    doc := docMgr.get(uri)
    if (doc == null) return [,]

    // Use the start of the requested range as the lookup position
    startMap := rangeMap["start"] as Str:Obj?
    if (startMap == null) return [,]
    pos := LspPosition.fromMap(startMap)

    word := LspUtil.getWordAtPosition(doc.text, pos)
    if (word == null || word.isEmpty || !word[0].isUpper) return [,]

    LspProtocol.logInfo("codeAction: looking for type '${word}' in all pods")
    actions := codeActionSvc.suggestUsingFixes(word, doc.text, uri)
    LspProtocol.logInfo("codeAction: found ${actions.size} fix(es) for '${word}'")
    return actions
  }

  **
  ** Enqueue a message for writing via writerActor so that main-thread
  ** responses and background-thread notifications are never interleaved
  ** in the LSP byte stream.
  **
  private Void writeSync(Str:Obj? msg)
  {
    writerActor.send(Unsafe(Obj?[out, msg]))
  }

  **
  ** Publish diagnostics for a single file (runs analysis).
  **
  private Void publishDiagnostics(Str uri, Str? text)
  {
    diags := text == null ? LspDiagnostic[,] : diagnostics.analyze(uri, text, projectIndex, pedanticMode, enableUnusedImport)
    publishDiagnosticsList(uri, diags)
  }

  **
  ** Publish a pre-computed list of diagnostics for a file.
  **
  private Void publishDiagnosticsList(Str uri, LspDiagnostic[] diags)
  {
    notification := LspProtocol.createNotification(
      "textDocument/publishDiagnostics",
      ["uri": uri, "diagnostics": diags.map |d| { d.toMap }]
    )
    writeSync(notification)
  }

  **
  ** Send a window/showMessage notification to the client.
  ** Type: 1=Error, 2=Warning, 3=Info
  **
  private Void showMessage(Str text, Int type := 3)
  {
    notification := LspProtocol.createNotification(
      "window/showMessage",
      Str:Obj?["type": type, "message": text]
    )
    writeSync(notification)
  }

  **
  ** Send a window/showMessageRequest with action buttons for files.
  ** type: 1=Error (red), 2=Warning (yellow), 3=Info.
  ** Each file becomes a clickable button; clicking opens the file in the editor.
  **
  private Void showMessageRequestWithFiles(Int type, Str text, Str:Str fileMap)
  {
    actions := fileMap.keys.map |name -> Str:Obj?| { Str:Obj?["title": name] }

    id := nextRequestId++
    pendingRequests[id] = fileMap

    request := LspProtocol.createRequest(id, "window/showMessageRequest",
      Str:Obj?["type": type, "message": text, "actions": actions]
    )
    writeSync(request)
  }

  **
  ** Send window/showDocument request to open a file in the editor.
  **
  private Void showDocument(Str uri)
  {
    id := nextRequestId++
    request := LspProtocol.createRequest(id, "window/showDocument",
      Str:Obj?["uri": uri, "external": false, "takeFocus": true]
    )
    writeSync(request)
  }
}
