package fan.lsp.debug.fantomDebugSession;

import com.google.gson.*;
import com.sun.jdi.*;
import com.sun.jdi.AbsentInformationException;

import java.util.List;

/**
 * Handles DAP evaluate requests (Watch panel, hover, REPL).
 *
 * Uses safeFormatValue exclusively — never calls invokeMethod — to avoid
 * INVOKE_SINGLE_THREADED deadlocks that would empty the Variables panel.
 */
public class EvalHandler {

    private final SessionContext ctx;
    private final ValueFormatter fmt;

    public EvalHandler(SessionContext ctx, ValueFormatter fmt) {
        this.ctx = ctx;
        this.fmt = fmt;
    }

    public JsonObject evaluate(JsonObject args) {
        String     expr    = SessionContext.str(args, "expression", "").trim();
        int        frameId = SessionContext.num(args, "frameId", -1);
        JsonObject body    = new JsonObject();
        body.addProperty("variablesReference", 0);

        if (expr.isEmpty())  { body.addProperty("result", "<empty expression>"); return body; }
        if (frameId < 0)     { body.addProperty("result", "<no frame>");         return body; }

        StackFrame frame = ctx.frameStore.get(frameId);
        if (frame == null) { body.addProperty("result", "<frame not available>"); return body; }

        try {
            Value v = evalExpr(frame, expr);
            if (v != null) {
                body.addProperty("result", fmt.safeFormatValue(v));
                body.addProperty("type",   fmt.formatType(v));
                if (v instanceof ObjectReference && !(v instanceof StringReference)) {
                    int ref = ctx.nextRef.getAndIncrement();
                    ctx.objectStore.put(ref, (ObjectReference) v);
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

    // ── Expression resolution ────────────────────────────────────────────

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
     *  2. LVT locals  (when LocalVariableTable is present)
     *  3. Method arguments by name
     *  4. Instance fields of "this"
     */
    private Value resolveIdent(StackFrame frame, String ident) throws Exception {
        if ("this".equals(ident)) return frame.thisObject();

        // LVT locals
        try {
            for (LocalVariable lv : frame.visibleVariables())
                if (lv.name().equals(ident)) return frame.getValue(lv);
        } catch (AbsentInformationException ignored) {}

        // Method arguments by name
        try {
            List<Value>         argVals  = frame.getArgumentValues();
            List<LocalVariable> argNames = null;
            try { argNames = frame.location().method().arguments(); } catch (Exception e2) {}
            if (argNames != null) {
                for (int i = 0; i < argNames.size() && i < argVals.size(); i++)
                    if (argNames.get(i).name().equals(ident)) return argVals.get(i);
            }
        } catch (Exception ignore) {}

        // Instance fields of "this"
        try {
            ObjectReference thisObj = frame.thisObject();
            if (thisObj != null) {
                Field f = thisObj.referenceType().fieldByName(ident);
                if (f != null) return thisObj.getValue(f);
            }
        } catch (Exception ignore) {}

        return null;
    }

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
}
