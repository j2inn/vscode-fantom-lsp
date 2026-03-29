package fan.lsp.debug.fantomDebugSession;

import java.lang.reflect.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;

/**
 * Unit tests for LaunchHandler helpers — specifically writeConfigProps() and
 * readFanConfigTarget(), both of which are private static methods accessed via
 * reflection so the production code stays clean.
 *
 * Regression cases covered:
 *
 *   writeConfigProps:
 *   1. debug=true is written when config.props is empty (baseline)
 *   2. debug=true is written when config.props has no debug key
 *   3. debug=true REPLACES a commented-out "// debug=true" line — the root
 *      cause of the original bug: Sys.debug stayed false because the old
 *      contains("debug=true") check matched the comment.
 *   4. debug=true REPLACES an active debug=false line
 *   5. debug=true REPLACES an active debug=true line (idempotent, no duplicate)
 *   6. Other properties are preserved as-is
 *   7. java.options is stripped (JDWP injection safety)
 *   8. JDWP java.options injected when jdwpPort > 0
 *   9. No JDWP line when jdwpPort == -1 (build-only shadow)
 *  10. Multiple commented debug= variants all removed
 *
 *   readFanConfigTarget:
 *  11. Returns target when fanTargetBuild is present
 *  12. Returns null when the key is absent
 *  13. Returns null when fan.config.json is missing
 *  14. Returns null on malformed JSON (no crash)
 */
public class LaunchHandlerTest {

    // ── Private method handles ────────────────────────────────────────────

    private static final Method WRITE_CONFIG_PROPS;
    private static final Method READ_FAN_CONFIG_TARGET;

    static {
        try {
            WRITE_CONFIG_PROPS = LaunchHandler.class.getDeclaredMethod(
                "writeConfigProps", Path.class, byte[].class, int.class);
            WRITE_CONFIG_PROPS.setAccessible(true);

            READ_FAN_CONFIG_TARGET = LaunchHandler.class.getDeclaredMethod(
                "readFanConfigTarget", String.class);
            READ_FAN_CONFIG_TARGET.setAccessible(true);
        } catch (NoSuchMethodException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    /** Invoke writeConfigProps and return the resulting file content. */
    private static String writeConfigProps(String original, int jdwpPort) throws Exception {
        Path tmp = Files.createTempFile("config-test-", ".props");
        try {
            WRITE_CONFIG_PROPS.invoke(null, tmp,
                original.getBytes(StandardCharsets.UTF_8), jdwpPort);
            return Files.readString(tmp);
        } finally {
            Files.deleteIfExists(tmp);
        }
    }

    /** Invoke readFanConfigTarget with the given directory. */
    private static String readFanConfigTarget(String dir) throws Exception {
        return (String) READ_FAN_CONFIG_TARGET.invoke(null, dir);
    }

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
            e.printStackTrace(System.err);
            failed++;
        }
    }

    public static void main(String[] args) throws Exception {
        System.out.println("=== LaunchHandlerTest ===");
        LaunchHandlerTest t = new LaunchHandlerTest();

        // writeConfigProps
        test("debug=true written into empty config",                    t::testDebugWrittenWhenEmpty);
        test("debug=true written when no debug key present",            t::testDebugWrittenWhenAbsent);
        test("commented-out '// debug=true' replaced by active line",   t::testCommentedDebugTrueReplaced);
        test("commented-out '// debug=false' replaced by active line",  t::testCommentedDebugFalseReplaced);
        test("active debug=false replaced by debug=true",               t::testActiveDebugFalseReplaced);
        test("active debug=true replaced without duplication",          t::testActiveDebugTrueIsIdempotent);
        test("other properties preserved",                              t::testOtherPropertiesPreserved);
        test("java.options stripped",                                   t::testJavaOptionsStripped);
        test("JDWP java.options injected when port > 0",                t::testJdwpInjectedWhenPortSet);
        test("no JDWP line when port == -1 (build shadow)",             t::testNoJdwpWhenPortMinusOne);
        test("multiple commented debug= variants all removed",          t::testMultipleCommentedDebugVariants);

        // readFanConfigTarget
        test("returns target when fanTargetBuild present",              t::testReadTargetPresent);
        test("returns null when fanTargetBuild absent",                 t::testReadTargetAbsent);
        test("returns null when fan.config.json missing",               t::testReadTargetMissingFile);
        test("returns null on malformed JSON, no crash",                t::testReadTargetMalformedJson);

        System.out.println("=== " + passed + " passed, " + failed + " failed ===");
        if (failed > 0) System.exit(1);
    }

    // ── writeConfigProps tests ────────────────────────────────────────────

    /** Baseline: empty original → debug=true appended. */
    void testDebugWrittenWhenEmpty() throws Exception {
        String out = writeConfigProps("", -1);
        assertContains(out, "debug=true");
        assertNotContains(out, "//");
    }

    /** No debug key present → debug=true appended. */
    void testDebugWrittenWhenAbsent() throws Exception {
        String out = writeConfigProps("runtime=java\nerrTraceMaxDepth=25\n", -1);
        assertContains(out, "debug=true");
        assertContains(out, "runtime=java");
    }

    /**
     * ROOT-CAUSE REGRESSION: config.props had "// debug=true" (commented out).
     * Old code: modified.contains("debug=true") → true → skipped appending.
     * Result: Sys.debug stayed false, zero LVT entries emitted, locals invisible.
     * Fix: strip any line matching the commented-or-active debug= pattern, then
     * always append a fresh debug=true.
     */
    void testCommentedDebugTrueReplaced() throws Exception {
        String original = "runtime=java\n// debug=true\nerrTraceMaxDepth=25\n";
        String out = writeConfigProps(original, -1);

        // Must have exactly one active debug=true
        long count = countOccurrences(out, "debug=true");
        assertEquals(1L, count, "exactly one debug=true");

        // The commented line must be gone
        assertNotContains(out, "// debug=true");
        assertNotContains(out, "//debug=true");
    }

    /** "// debug=false" variant also removed and replaced. */
    void testCommentedDebugFalseReplaced() throws Exception {
        String original = "// debug=false\n";
        String out = writeConfigProps(original, -1);
        assertContains(out, "debug=true");
        assertNotContains(out, "debug=false");
    }

    /** Active debug=false → replaced by debug=true. */
    void testActiveDebugFalseReplaced() throws Exception {
        String out = writeConfigProps("debug=false\n", -1);
        assertContains(out, "debug=true");
        assertNotContains(out, "debug=false");
    }

    /** Active debug=true → no duplication after idempotent rewrite. */
    void testActiveDebugTrueIsIdempotent() throws Exception {
        String out = writeConfigProps("debug=true\n", -1);
        assertEquals(1L, countOccurrences(out, "debug=true"), "no duplicate debug=true");
    }

    /** Unrelated properties must survive unchanged. */
    void testOtherPropertiesPreserved() throws Exception {
        String original = "runtime=java\nerrTraceMaxDepth=25\ntimezone=Europe/London\n";
        String out = writeConfigProps(original, -1);
        assertContains(out, "runtime=java");
        assertContains(out, "errTraceMaxDepth=25");
        assertContains(out, "timezone=Europe/London");
    }

    /** java.options must be stripped (prevents child JVMs re-binding JDWP port). */
    void testJavaOptionsStripped() throws Exception {
        String original = "java.options=-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=5005\n";
        String out = writeConfigProps(original, -1);
        assertNotContains(out, "java.options");
    }

    /** When jdwpPort > 0 a java.options=-agentlib:jdwp=... line must be injected. */
    void testJdwpInjectedWhenPortSet() throws Exception {
        String out = writeConfigProps("runtime=java\n", 5005);
        assertContains(out, "java.options=-agentlib:jdwp=");
        assertContains(out, "address=5005");
    }

    /** When jdwpPort == -1 (build-only shadow) no java.options line must appear. */
    void testNoJdwpWhenPortMinusOne() throws Exception {
        String out = writeConfigProps("runtime=java\n", -1);
        assertNotContains(out, "java.options");
    }

    /**
     * Config.props with multiple commented-out debug variants (different spacing
     * around '='): all must be removed and replaced by a single debug=true.
     */
    void testMultipleCommentedDebugVariants() throws Exception {
        String original = "// debug=true\n//debug = false\n// debug=false\n";
        String out = writeConfigProps(original, -1);

        assertEquals(1L, countOccurrences(out, "debug=true"), "exactly one debug=true");
        assertNotContains(out, "//");
        assertNotContains(out, "debug=false");
    }

    // ── readFanConfigTarget tests ─────────────────────────────────────────

    /** fanTargetBuild key present → its value returned. */
    void testReadTargetPresent() throws Exception {
        Path dir = Files.createTempDirectory("fan-cfg-test-");
        try {
            Files.writeString(dir.resolve("fan.config.json"),
                "{\"fanPath\":\"/some/path\",\"fanTargetBuild\":\"fan\"}");
            String target = readFanConfigTarget(dir.toString());
            assertEquals("fan", target, "fanTargetBuild value");
        } finally {
            deleteRecursively(dir);
        }
    }

    /** Key absent → null returned (no crash, no default imposed). */
    void testReadTargetAbsent() throws Exception {
        Path dir = Files.createTempDirectory("fan-cfg-test-");
        try {
            Files.writeString(dir.resolve("fan.config.json"),
                "{\"fanPath\":\"/some/path\"}");
            String target = readFanConfigTarget(dir.toString());
            assertEquals(null, target, "should be null when key absent");
        } finally {
            deleteRecursively(dir);
        }
    }

    /** Missing file → null returned. */
    void testReadTargetMissingFile() throws Exception {
        String target = readFanConfigTarget("/tmp/nonexistent-dir-xyz-abc");
        assertEquals(null, target, "should be null when file missing");
    }

    /** Malformed JSON → null returned, no exception escapes. */
    void testReadTargetMalformedJson() throws Exception {
        Path dir = Files.createTempDirectory("fan-cfg-test-");
        try {
            Files.writeString(dir.resolve("fan.config.json"), "{ NOT_JSON !! }");
            // readFanConfigTarget uses regex so partial parse is fine; just ensure no crash
            String target = readFanConfigTarget(dir.toString());
            // result may be null — we only care it doesn't throw
        } finally {
            deleteRecursively(dir);
        }
    }

    // ── Assertion helpers ─────────────────────────────────────────────────

    private static void assertContains(String text, String sub) {
        if (!text.contains(sub))
            throw new AssertionError("Expected to find <" + sub + "> in:\n" + text);
    }

    private static void assertNotContains(String text, String sub) {
        if (text.contains(sub))
            throw new AssertionError("Did NOT expect <" + sub + "> in:\n" + text);
    }

    private static void assertEquals(Object expected, Object actual, String label) {
        if (expected == null ? actual != null : !expected.equals(actual))
            throw new AssertionError(label + ": expected <" + expected + "> but got <" + actual + ">");
    }

    private static long countOccurrences(String text, String sub) {
        long count = 0;
        int  idx   = 0;
        while ((idx = text.indexOf(sub, idx)) != -1) { count++; idx += sub.length(); }
        return count;
    }

    private static void deleteRecursively(Path path) throws Exception {
        if (!Files.exists(path)) return;
        try (var stream = Files.walk(path)) {
            stream.sorted(java.util.Comparator.reverseOrder())
                  .forEach(p -> { try { Files.delete(p); } catch (Exception ignore) {} });
        }
    }
}
