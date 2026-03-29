package fan.lsp.debug.fantomDebugSession;

import com.google.gson.*;
import com.sun.jdi.*;
import com.sun.jdi.AbsentInformationException;
import com.sun.jdi.IncompatibleThreadStateException;

import java.util.*;

/** Stack trace, scope and variable inspection. */
public class StackInspector {

    private final SessionContext ctx;
    private final ValueFormatter fmt;

    public StackInspector(SessionContext ctx, ValueFormatter fmt) {
        this.ctx = ctx;
        this.fmt = fmt;
    }

    // ── Stack trace ──────────────────────────────────────────────────────

    public JsonObject getStackTrace(JsonObject args) {
        long      threadId = args.get("threadId").getAsLong();
        JsonArray frames   = new JsonArray();

        if (ctx.vm != null) {
            ctx.findThread(threadId).ifPresent(thread -> {
                try {
                    int frameHandle = (int)(threadId * 10000L);
                    for (StackFrame frame : thread.frames()) {
                        try {
                            Location loc    = frame.location();
                            int      handle = frameHandle++;
                            ctx.frameStore.put(handle, frame);

                            JsonObject dapFrame = new JsonObject();
                            dapFrame.addProperty("id",     handle);
                            dapFrame.addProperty("name",   fmt.formatFrameName(loc));
                            dapFrame.addProperty("line",   loc.lineNumber());
                            dapFrame.addProperty("column", 1);

                            String sourceName = null;
                            try { sourceName = loc.sourceName(); } catch (Exception ignore) {}

                            if (sourceName != null && sourceName.endsWith(".fan")) {
                                String fullPath = ctx.sourceMapper != null
                                    ? ctx.sourceMapper.findSourceFile(
                                        sourceName, loc.declaringType().name())
                                    : null;
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

    // ── Scopes ───────────────────────────────────────────────────────────

    public JsonObject getScopes(JsonObject args) {
        int        frameHandle = args.get("frameId").getAsInt();
        StackFrame frame       = ctx.frameStore.get(frameHandle);
        JsonArray  scopes      = new JsonArray();

        if (frame != null) {
            // Locals scope — stored under a negative ref key
            int ref = ctx.nextRef.getAndIncrement();
            ctx.frameStore.put(-ref, frame);
            JsonObject localsScope = new JsonObject();
            localsScope.addProperty("name",               "Locals");
            localsScope.addProperty("variablesReference", ref);
            localsScope.addProperty("expensive",          false);
            scopes.add(localsScope);

            // "this" scope (instance fields, expandable)
            try {
                ObjectReference thisObj = frame.thisObject();
                if (thisObj != null) {
                    int thisRef = ctx.nextRef.getAndIncrement();
                    ctx.objectStore.put(thisRef, thisObj);
                    JsonObject thisScope = new JsonObject();
                    thisScope.addProperty("name",
                        "this (" + ValueFormatter.jvmTypeToFantom(thisObj.type().name()) + ")");
                    thisScope.addProperty("variablesReference", thisRef);
                    thisScope.addProperty("expensive",          false);
                    scopes.add(thisScope);
                }
            } catch (Exception e) {
                System.err.println("[JDI] scopes 'this' error: " + e);
            }
        }

        JsonObject body = new JsonObject();
        body.add("scopes", scopes);
        return body;
    }

    // ── Variables ────────────────────────────────────────────────────────

    public JsonObject getVariables(JsonObject args) {
        int       ref  = args.get("variablesReference").getAsInt();
        JsonArray vars = new JsonArray();

        // Negative ref → locals frame
        StackFrame localsFrame = ctx.frameStore.get(-ref);
        if (localsFrame != null) {
            fillLocalsVars(localsFrame, vars);
        } else {
            ObjectReference obj = ctx.objectStore.get(ref);
            if (obj != null) fillObjectVars(obj, vars);
        }

        JsonObject body = new JsonObject();
        body.add("variables", vars);
        return body;
    }

    /**
     * Fill vars from a stack frame.
     *
     * Three-step strategy:
     *  1. LocalVariableTable (LVT) — full local names when debug=true.
     *     hasLvt is set as soon as visibleVariables() succeeds (no AbsentInformationException),
     *     regardless of whether any variables are currently in scope or readable.
     *     Variables whose getValue() fails are still shown as &lt;unavailable&gt; so the user
     *     can see all declared vars even at the first bytecode of a declaration line.
     *  2. Method arguments via getArgumentValues() — always runs (not gated on hasLvt)
     *     to complement params omitted from the LVT (Fantom does not emit LVT entries
     *     for method parameters in all build configurations).  The `shown` set prevents
     *     duplicates when params ARE already present in the LVT.
     *  3. this.* instance fields — appended once, deduplicated against
     *     locals/params already shown.  Fantom fields are accessible
     *     without "this." prefix, matching the Watch panel behaviour.
     */
    private void fillLocalsVars(StackFrame frame, JsonArray vars) {
        Set<String> shown = new HashSet<>();

        // ── Step 1: LVT locals ────────────────────────────────────────────
        boolean hasLvt = false;
        try {
            List<LocalVariable> locals = frame.visibleVariables();
            // FIX: set hasLvt as soon as visibleVariables() succeeds — the LVT is
            // present even when no variables are in scope at the current PC, or when
            // individual getValue() calls fail below.
            hasLvt = true;
            for (LocalVariable lv : locals) {
                String name = lv.name();
                if (name.startsWith("$")) continue; // Fantom synthetic slots
                try {
                    Value v = frame.getValue(lv);
                    vars.add(makeSafeVar(name, lv.typeName(), v));
                } catch (Exception e) {
                    // FIX: show variable as <unavailable> rather than silently dropping it.
                    // This preserves visibility at the first bytecode of a declaration line
                    // where the slot hasn't been written yet.
                    vars.add(makeSafeVar(name, lv.typeName(), null));
                    System.err.println("[JDI] getValue(" + name + ") error: " + e);
                }
                // FIX: track the name regardless of getValue success so Step 2
                // doesn't add a duplicate entry for the same variable.
                shown.add(name);
            }
        } catch (AbsentInformationException ignored) {
            // Pod compiled without debug=true — no LocalVariableTable.
            // Warn once per session so the user knows how to fix it.
            if (ctx.lvtWarningShown.compareAndSet(false, true)) {
                ctx.consoleLog("[Fantom Debug] ⚠ Local variables not available: the pod was compiled "
                    + "without debug=true (no LocalVariableTable in bytecode). "
                    + "Set \"preLaunchRebuild\": true in launch.json (or ensure your pod "
                    + "was built with debug=true) to see local variables.");
            }
        } catch (Exception e) {
            System.err.println("[JDI] visibleVariables error: " + e);
        }

        // ── Step 2: method arguments ──────────────────────────────────────
        // FIX: always run (not gated on !hasLvt).  Fantom does not always emit
        // LVT entries for method parameters, so once a local variable comes into
        // scope the old `if (!hasLvt)` guard would hide all method params.
        // The `shown` set above handles deduplication when params ARE in the LVT.
        try {
            List<Value>         argVals   = frame.getArgumentValues();
            List<LocalVariable> namedArgs = null;
            try { namedArgs = frame.location().method().arguments(); }
            catch (Exception ignore) {}

            // Fallback: parse parameter names from the .fan source file
            List<String> sourceNames = null;
            if (namedArgs == null && ctx.sourceMapper != null) {
                try {
                    String srcName  = frame.location().sourceName();
                    String jvmClass = frame.location().declaringType().name();
                    String method   = frame.location().method().name();
                    List<String> parsed = ctx.sourceMapper
                        .getMethodParamNames(srcName, jvmClass, method);
                    if (!parsed.isEmpty()) sourceNames = parsed;
                } catch (Exception ignore) {}
            }

            for (int i = 0; i < argVals.size(); i++) {
                String name;
                String typeName = null;
                if (namedArgs != null && i < namedArgs.size()) {
                    name     = namedArgs.get(i).name();
                    typeName = namedArgs.get(i).typeName();
                } else if (sourceNames != null && i < sourceNames.size()) {
                    name = sourceNames.get(i);
                } else {
                    name = "arg" + i;
                }
                if (shown.contains(name)) continue;
                vars.add(makeSafeVar(name, typeName, argVals.get(i)));
                shown.add(name);
            }
        } catch (Exception e) {
            System.err.println("[JDI] getArgumentValues error: " + e);
        }

        // ── Step 3: this.* instance fields ───────────────────────────────
        try {
            ObjectReference thisObj = frame.thisObject();
            if (thisObj != null) {
                List<Field>       fields    = thisObj.referenceType().allFields();
                Map<Field, Value> fieldVals = thisObj.getValues(fields);
                for (Map.Entry<Field, Value> e : fieldVals.entrySet()) {
                    Field f = e.getKey();
                    if (f.isStatic()) continue;
                    if (f.name().startsWith("$")) continue; // Fantom synthetic
                    if (shown.contains(f.name())) continue;
                    vars.add(makeSafeVar(f.name(), f.typeName(), e.getValue()));
                    shown.add(f.name());
                }
            }
        } catch (Exception e) {
            System.err.println("[JDI] this fields error: " + e);
        }
    }

    private void fillObjectVars(ObjectReference obj, JsonArray vars) {
        try {
            List<Field>       fields = obj.referenceType().allFields();
            Map<Field, Value> values = obj.getValues(fields);
            for (Map.Entry<Field, Value> e : values.entrySet()) {
                Field f = e.getKey();
                if (f.name().startsWith("$")) continue;
                if (f.isStatic()) continue;
                vars.add(makeSafeVar(f.name(), f.typeName(), e.getValue()));
            }
        } catch (Exception e) {
            System.err.println("[JDI] field vars error: " + e);
        }
    }

    private JsonObject makeSafeVar(String name, String declType, Value value) {
        JsonObject var = new JsonObject();
        var.addProperty("name",  name);
        var.addProperty("value", fmt.safeFormatValue(value));
        String displayType = (value != null)
            ? fmt.formatType(value)
            : ValueFormatter.formatDeclType(declType);
        var.addProperty("type", displayType);
        int childRef = 0;
        if (value instanceof ObjectReference && !(value instanceof StringReference)) {
            childRef = ctx.nextRef.getAndIncrement();
            ctx.objectStore.put(childRef, (ObjectReference) value);
        }
        var.addProperty("variablesReference", childRef);
        return var;
    }
}
