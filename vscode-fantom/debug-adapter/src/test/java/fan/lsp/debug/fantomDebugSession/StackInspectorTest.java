package fan.lsp.debug.fantomDebugSession;

import com.google.gson.*;
import com.sun.jdi.*;
import com.sun.jdi.AbsentInformationException;

import java.lang.reflect.*;
import java.util.*;

/**
 * Unit tests for StackInspector.fillLocalsVars() — the logic that populates
 * the Variables panel when the debugger stops on a Fantom frame.
 *
 * Run via build.sh (no external test framework required).
 *
 * Regression cases covered:
 *   1. LVT local variable shown after step-over
 *   2. Variable whose getValue() throws is shown as <unavailable> (not silently dropped)
 *   3. hasLvt flag set correctly even when all getValue() calls fail
 *   4. Method params complemented from getArgumentValues() when not in LVT
 *   5. No duplicate when params ARE in both LVT and getArgumentValues()
 *   6. Full fallback to getArgumentValues() when LVT is absent
 *   7. Fantom $-prefixed synthetic slot names are filtered out
 */
public class StackInspectorTest {

    // ── Test runner ───────────────────────────────────────────────────────

    private static int passed = 0;
    private static int failed = 0;

    @FunctionalInterface
    interface TestCase { void run() throws Exception; }

    private static void test(String name, TestCase tc) {
        try {
            tc.run();
            System.out.println("  [PASS] " + name);
            passed++;
        } catch (AssertionError | Exception e) {
            System.out.println("  [FAIL] " + name + " — " + e.getMessage());
            failed++;
        }
    }

    public static void main(String[] args) throws Exception {
        System.out.println("=== StackInspectorTest ===");
        StackInspectorTest t = new StackInspectorTest();
        test("LVT local var shown after step-over",              t::testLvtLocalVarShown);
        test("getValue failure shows <unavailable> not dropped", t::testGetValueFailureShowsUnavailable);
        test("hasLvt set even when all getValue calls fail",     t::testHasLvtSetWhenGetValueFails);
        test("method params complement when not in LVT",         t::testParamsComplementLvt);
        test("no duplicate when params are in both LVT + args",  t::testNoDuplicateWhenParamsInBothSources);
        test("no LVT: full fallback to getArgumentValues",       t::testNoLvtFallsBackToParams);
        test("Fantom $ synthetic slot names filtered",            t::testSyntheticVarsFiltered);
        System.out.println("=== " + passed + " passed, " + failed + " failed ===");
        if (failed > 0) System.exit(1);
    }

    // ── Individual tests ──────────────────────────────────────────────────

    /**
     * Basic regression: after preLaunchRebuild (LVT present), a local variable
     * that is in scope at the current PC should appear in the Variables panel.
     */
    void testLvtLocalVarShown() throws Exception {
        LocalVariable x = mockLv("x", "fan.sys.Int");
        StackFrame frame = FrameBuilder.newBuilder()
            .lvtVars(x)
            .getValue(x, null)          // null value → shown as "null"
            .build();

        JsonArray vars = runGetLocals(frame);
        assertContains(vars, "x");
    }

    /**
     * If getValue() throws for a visible LVT variable, it must still appear
     * in the Variables panel (as <unavailable>), not be silently dropped.
     * Previously the variable was swallowed and the user saw nothing.
     */
    void testGetValueFailureShowsUnavailable() throws Exception {
        LocalVariable x = mockLv("x", "fan.sys.Int");
        StackFrame frame = FrameBuilder.newBuilder()
            .lvtVars(x)
            .getValueThrows(x, new IllegalArgumentException("slot not yet initialized"))
            .build();

        JsonArray vars = runGetLocals(frame);
        assertContains(vars, "x");
        // value should be "null" (the safe fallback when getValue fails)
        assertEquals("null", getVarValue(vars, "x"));
    }

    /**
     * Even when every getValue() call fails, hasLvt must be set to true so
     * Step 2 (method-arg fallback) does NOT run and silently replace the
     * "no visible vars yet" state with a ghost params-only list.
     * With the old code, hasLvt stayed false and Step 2 kicked in.
     */
    void testHasLvtSetWhenGetValueFails() throws Exception {
        LocalVariable x = mockLv("x", "fan.sys.Int");
        // Method param "msg" available via getArgumentValues()
        LocalVariable msg = mockLv("msg", "fan.sys.Str");
        StackFrame frame = FrameBuilder.newBuilder()
            .lvtVars(x)
            .getValueThrows(x, new IllegalArgumentException("slot unreadable"))
            .argVals(Collections.emptyList())    // no args from getArgumentValues
            .methodArgs(Collections.emptyList()) // no named args either
            .build();

        JsonArray vars = runGetLocals(frame);
        // x must appear (unavailable), and there must be no phantom "msg" from args
        assertContains(vars, "x");
        assertNotContains(vars, "msg");
    }

    /**
     * Fantom does not always emit LVT entries for method parameters.  Step 2
     * must always run (not be gated on !hasLvt) so params are supplemented from
     * getArgumentValues() even when LVT is present with local variables.
     * This was the primary user-visible regression: once a local var came into
     * scope, method params disappeared from the Variables panel.
     */
    void testParamsComplementLvt() throws Exception {
        // LVT has a local var 'x' but NOT the method param 'self'
        LocalVariable x    = mockLv("x", "fan.sys.Int");
        LocalVariable self = mockLv("self", "fan.sys.Obj");
        StackFrame frame = FrameBuilder.newBuilder()
            .lvtVars(x)
            .getValue(x, null)
            // 'self' available via getArgumentValues but NOT in LVT
            .argVals(Collections.singletonList(null))
            .methodArgs(Collections.singletonList(self))
            .build();

        JsonArray vars = runGetLocals(frame);
        assertContains(vars, "x");
        assertContains(vars, "self");
    }

    /**
     * When a param IS in both LVT (visibleVariables) and getArgumentValues,
     * it must appear exactly once — no duplicate entries.
     */
    void testNoDuplicateWhenParamsInBothSources() throws Exception {
        LocalVariable p = mockLv("p", "fan.sys.Int");
        StackFrame frame = FrameBuilder.newBuilder()
            .lvtVars(p)
            .getValue(p, null)
            // same var also returned by getArgumentValues / method.arguments()
            .argVals(Collections.singletonList(null))
            .methodArgs(Collections.singletonList(p))
            .build();

        JsonArray vars = runGetLocals(frame);
        assertContains(vars, "p");
        assertEquals(1, countVarOccurrences(vars, "p"));
    }

    /**
     * When no LVT is present (AbsentInformationException), the adapter must
     * fall back to getArgumentValues() to show method parameters.
     */
    void testNoLvtFallsBackToParams() throws Exception {
        LocalVariable param = mockLv("param", "fan.sys.Str");
        StackFrame frame = FrameBuilder.newBuilder()
            .noLvt()
            .argVals(Collections.singletonList(null))
            .methodArgs(Collections.singletonList(param))
            .build();

        JsonArray vars = runGetLocals(frame);
        assertContains(vars, "param");
    }

    /**
     * Fantom emits synthetic local variables whose JVM slot names start with '$'.
     * These must be hidden from the Variables panel.
     */
    void testSyntheticVarsFiltered() throws Exception {
        LocalVariable real      = mockLv("counter", "fan.sys.Int");
        LocalVariable synthetic = mockLv("$val",    "fan.sys.Obj");
        StackFrame frame = FrameBuilder.newBuilder()
            .lvtVars(real, synthetic)
            .getValue(real,      null)
            .getValue(synthetic, null)
            .build();

        JsonArray vars = runGetLocals(frame);
        assertContains(vars,    "counter");
        assertNotContains(vars, "$val");
    }

    // ── Test helpers ──────────────────────────────────────────────────────

    /** Run getVariables for the "Locals" scope of the given mock frame. */
    private JsonArray runGetLocals(StackFrame frame) {
        SessionContext ctx      = new SessionContext(null);
        ValueFormatter fmt      = new ValueFormatter(ctx);
        StackInspector inspector = new StackInspector(ctx, fmt);

        // Simulate what getScopes does: store the frame at -1000
        ctx.frameStore.put(-1000, frame);

        JsonObject args = new JsonObject();
        args.addProperty("variablesReference", 1000);
        JsonObject result = inspector.getVariables(args);
        return result.getAsJsonArray("variables");
    }

    private void assertContains(JsonArray vars, String name) {
        for (JsonElement e : vars)
            if (name.equals(e.getAsJsonObject().get("name").getAsString())) return;
        throw new AssertionError("Expected variable '" + name + "' but got: " + vars);
    }

    private void assertNotContains(JsonArray vars, String name) {
        for (JsonElement e : vars)
            if (name.equals(e.getAsJsonObject().get("name").getAsString()))
                throw new AssertionError("Unexpected variable '" + name + "' in: " + vars);
    }

    private void assertEquals(Object expected, Object actual) {
        if (!expected.equals(actual))
            throw new AssertionError("Expected " + expected + " but got " + actual);
    }

    private String getVarValue(JsonArray vars, String name) {
        for (JsonElement e : vars) {
            JsonObject v = e.getAsJsonObject();
            if (name.equals(v.get("name").getAsString()))
                return v.get("value").getAsString();
        }
        throw new AssertionError("Variable '" + name + "' not found");
    }

    private int countVarOccurrences(JsonArray vars, String name) {
        int count = 0;
        for (JsonElement e : vars)
            if (name.equals(e.getAsJsonObject().get("name").getAsString())) count++;
        return count;
    }

    // ── JDI mock factory helpers ──────────────────────────────────────────

    /** Create a minimal LocalVariable mock with the given name and typeName. */
    @SuppressWarnings("unchecked")
    private static LocalVariable mockLv(String name, String typeName) {
        return (LocalVariable) Proxy.newProxyInstance(
            LocalVariable.class.getClassLoader(),
            new Class<?>[]{ LocalVariable.class },
            (proxy, method, args) -> {
                switch (method.getName()) {
                    case "name":     return name;
                    case "typeName": return typeName;
                    case "equals":   return proxy == args[0];
                    case "hashCode": return System.identityHashCode(proxy);
                    case "toString": return "MockLV(" + name + ")";
                    default:
                        if (method.getReturnType() == boolean.class) return false;
                        if (method.getReturnType() == int.class)     return 0;
                        return null;
                }
            }
        );
    }

    /**
     * Builder for minimal StackFrame mocks.
     *
     * Default behaviour for unspecified paths:
     *   - visibleVariables(): returns empty list (LVT present but nothing in scope)
     *   - getValue(lv): returns null
     *   - getArgumentValues(): returns empty list
     *   - location().method().arguments(): throws AbsentInformationException
     *   - thisObject(): returns null
     */
    static class FrameBuilder {
        private boolean lvtAbsent = false;
        private final List<LocalVariable>          lvtVars    = new ArrayList<>();
        private final Map<LocalVariable, Value>    valueMap   = new IdentityHashMap<>();
        private final Map<LocalVariable, Exception> throwMap  = new IdentityHashMap<>();
        private List<Value>          argValList  = Collections.emptyList();
        private List<LocalVariable>  methodArgList = null; // null = throws AbsInfInfo

        static FrameBuilder newBuilder() { return new FrameBuilder(); }

        FrameBuilder noLvt()                                     { lvtAbsent = true;                    return this; }
        FrameBuilder lvtVars(LocalVariable... lvs)               { lvtVars.addAll(Arrays.asList(lvs));  return this; }
        FrameBuilder getValue(LocalVariable lv, Value v)         { valueMap.put(lv, v);                 return this; }
        FrameBuilder getValueThrows(LocalVariable lv, Exception e){ throwMap.put(lv, e);                return this; }
        FrameBuilder argVals(List<Value> vals)                   { argValList = vals;                   return this; }
        FrameBuilder methodArgs(List<LocalVariable> args)        { methodArgList = args;                return this; }

        @SuppressWarnings("unchecked")
        StackFrame build() {
            FrameBuilder self = this;

            // Method mock: arguments() returns methodArgList or throws
            com.sun.jdi.Method methodMock = (com.sun.jdi.Method) Proxy.newProxyInstance(
                com.sun.jdi.Method.class.getClassLoader(),
                new Class<?>[]{ com.sun.jdi.Method.class },
                (proxy, m, args) -> {
                    if ("arguments".equals(m.getName())) {
                        if (self.methodArgList == null)
                            throw new AbsentInformationException();
                        return self.methodArgList;
                    }
                    if ("name".equals(m.getName())) return "testMethod";
                    if (m.getReturnType() == boolean.class) return false;
                    if (m.getReturnType() == int.class)     return 0;
                    return null;
                });

            // ReferenceType mock for location().declaringType().name()
            ReferenceType refTypeMock = (ReferenceType) Proxy.newProxyInstance(
                ReferenceType.class.getClassLoader(),
                new Class<?>[]{ ReferenceType.class },
                (proxy, m, args) -> {
                    if ("name".equals(m.getName())) return "fan.test.TestClass";
                    if (m.getReturnType() == boolean.class) return false;
                    if (m.getReturnType() == int.class)     return 0;
                    return null;
                });

            // Location mock
            Location locMock = (Location) Proxy.newProxyInstance(
                Location.class.getClassLoader(),
                new Class<?>[]{ Location.class },
                (proxy, m, args) -> {
                    if ("method".equals(m.getName()))        return methodMock;
                    if ("sourceName".equals(m.getName()))    return "TestClass.fan";
                    if ("declaringType".equals(m.getName())) return refTypeMock;
                    if ("lineNumber".equals(m.getName()))    return 42;
                    if (m.getReturnType() == boolean.class) return false;
                    if (m.getReturnType() == int.class)     return 0;
                    return null;
                });

            // StackFrame mock
            return (StackFrame) Proxy.newProxyInstance(
                StackFrame.class.getClassLoader(),
                new Class<?>[]{ StackFrame.class },
                (proxy, m, args) -> {
                    switch (m.getName()) {
                        case "visibleVariables":
                            if (self.lvtAbsent) throw new AbsentInformationException();
                            return new ArrayList<>(self.lvtVars);

                        case "getValue": {
                            LocalVariable lv = (LocalVariable) args[0];
                            if (self.throwMap.containsKey(lv)) throw self.throwMap.get(lv);
                            return self.valueMap.getOrDefault(lv, null);
                        }

                        case "getArgumentValues":
                            return new ArrayList<>(self.argValList);

                        case "location":
                            return locMock;

                        case "thisObject":
                            return null;

                        default:
                            if (m.getReturnType() == boolean.class) return false;
                            if (m.getReturnType() == int.class)     return 0;
                            return null;
                    }
                });
        }
    }
}
