package fan.lsp.debug;

import java.io.File;
import java.nio.file.*;
import java.util.*;
import java.util.regex.*;

/**
 * Maps JDI source information back to .fan file paths on disk.
 *
 * The Fantom compiler emits a SourceFile attribute in each .class file
 * that contains just the base filename (e.g. "MyClass.fan"), not the full
 * path.  Given that name and the JVM class name (fan.myPod.MyClass), we
 * walk the user-supplied sourceDir tree to find the actual file.
 *
 * Results are cached so that the walk is done at most once per
 * (sourceName, className) pair within a session.
 */
public class SourceMapper {

    private final Path                sourceRoot;
    private final Map<String, String> cache = new HashMap<>();

    public SourceMapper(String sourceDir) {
        this.sourceRoot = Paths.get(sourceDir).toAbsolutePath();
    }

    /**
     * Find the absolute path for a .fan source file.
     *
     * @param sourceName  Base filename from JVM SourceFile attribute, e.g. "MyClass.fan"
     * @param jvmClass    JVM class name, e.g. "fan.myPod.MyClass"
     * @return            Absolute path string, or null if not found
     */
    public String findSourceFile(String sourceName, String jvmClass) {
        String cacheKey = jvmClass + "|" + sourceName;
        if (cache.containsKey(cacheKey)) return cache.get(cacheKey);

        String podName = extractPodName(jvmClass);
        String result  = null;

        if (Files.exists(sourceRoot)) {
            // 1. <sourceDir>/<pod>/fan/<sourceName>  (standard pod layout)
            if (podName != null) {
                Path candidate = sourceRoot.resolve(podName).resolve("fan").resolve(sourceName);
                if (Files.exists(candidate)) result = candidate.toString();
            }

            // 2. <sourceDir>/<pod>/<sourceName>
            if (result == null && podName != null) {
                Path candidate = sourceRoot.resolve(podName).resolve(sourceName);
                if (Files.exists(candidate)) result = candidate.toString();
            }

            // 3. <sourceDir>/fan/<sourceName>  (single-pod workspace)
            if (result == null) {
                Path candidate = sourceRoot.resolve("fan").resolve(sourceName);
                if (Files.exists(candidate)) result = candidate.toString();
            }

            // 4. Full recursive walk, preferring paths that contain the pod name
            if (result == null) result = walkForFile(sourceName, podName);
        }

        if (result != null) {
            System.err.println("[SourceMapper] " + sourceName + " → " + result);
        } else {
            System.err.println("[SourceMapper] " + sourceName + " not found under " + sourceRoot);
        }

        cache.put(cacheKey, result);
        return result;
    }

    // -----------------------------------------------------------------------
    // Param name extraction from source
    // -----------------------------------------------------------------------

    /**
     * Parse parameter names for a given Fantom method directly from its .fan source file.
     *
     * This is used as a fallback when the JVM class has no LocalVariableTable
     * (compiled without debug=true), so method.arguments() throws
     * AbsentInformationException and we'd normally show "arg0", "arg1" etc.
     *
     * Returns an empty list if the source file cannot be found or parsed.
     */
    public List<String> getMethodParamNames(String sourceName, String jvmClass, String methodName) {
        String filePath = findSourceFile(sourceName, jvmClass);
        if (filePath == null) return Collections.emptyList();
        try {
            String source = new String(Files.readAllBytes(Paths.get(filePath)));
            return parseParamNamesFromSource(source, methodName);
        } catch (Exception e) {
            return Collections.emptyList();
        }
    }

    /**
     * Find the first Fantom method matching {@code methodName} in {@code source}
     * and return its parameter names.
     *
     * Handles:
     *   - Generic types:   Map<Str,Int> names
     *   - Nullable types:  Str? value
     *   - Default values:  Int count := 0  →  name = "count"
     *   - Multi-line sigs: params that span several source lines
     */
    private static List<String> parseParamNamesFromSource(String source, String methodName) {
        // Match: <methodName>  (  — word boundary, optional whitespace
        Pattern methodPat = Pattern.compile("\\b" + Pattern.quote(methodName) + "\\s*\\(");
        Matcher m = methodPat.matcher(source);
        while (m.find()) {
            // Walk forward to find the matching closing ')'
            int start = m.end() - 1;   // position of '('
            int depth = 0, end = -1;
            for (int i = start; i < source.length(); i++) {
                char c = source.charAt(i);
                if      (c == '(') depth++;
                else if (c == ')') { depth--; if (depth == 0) { end = i; break; } }
            }
            if (end < 0) continue;

            String paramsStr = source.substring(start + 1, end).trim();
            if (paramsStr.isEmpty()) return Collections.emptyList();

            List<String> names = extractParamNames(paramsStr);
            if (!names.isEmpty()) return names;
        }
        return Collections.emptyList();
    }

    /** Split a Fantom param list by commas, respecting < > and [ ] nesting. */
    private static List<String> splitParams(String paramsStr) {
        List<String> result = new ArrayList<>();
        int depth = 0, start = 0;
        for (int i = 0; i < paramsStr.length(); i++) {
            char c = paramsStr.charAt(i);
            if      (c == '<' || c == '[') depth++;
            else if (c == '>' || c == ']') depth--;
            else if (c == ','  && depth == 0) {
                result.add(paramsStr.substring(start, i));
                start = i + 1;
            }
        }
        result.add(paramsStr.substring(start));
        return result;
    }

    /**
     * Given a Fantom param list string (contents between the method parens),
     * return the parameter names in order.
     *
     * Each param looks like one of:
     *   Type  name
     *   Type? name
     *   Type<A,B> name
     *   Type  name  := defaultExpr
     */
    private static List<String> extractParamNames(String paramsStr) {
        List<String> names = new ArrayList<>();
        for (String chunk : splitParams(paramsStr)) {
            chunk = chunk.trim();
            // Drop default value expression after :=
            int assignIdx = chunk.indexOf(":=");
            if (assignIdx >= 0) chunk = chunk.substring(0, assignIdx).trim();
            // The param name is the last whitespace-delimited token
            // (type token(s) precede it, e.g. "Map<Str,Int>" "myMap")
            String[] tokens = chunk.trim().split("\\s+");
            if (tokens.length >= 2) {
                String name = tokens[tokens.length - 1];
                // Must look like a Fantom identifier (starts with lowercase)
                if (name.matches("[a-z_][a-zA-Z0-9_]*")) {
                    names.add(name);
                }
            }
        }
        return names;
    }

    private static String extractPodName(String jvmClass) {
        if (jvmClass == null || !jvmClass.startsWith("fan.")) return null;
        String[] parts = jvmClass.split("\\.", 3);
        return (parts.length >= 2) ? parts[1] : null;
    }

    private String walkForFile(String sourceName, String podName) {
        try {
            Optional<Path> found = Files.walk(sourceRoot)
                .filter(p -> p.getFileName().toString().equals(sourceName))
                .filter(p -> podName == null || p.toString().contains(File.separator + podName + File.separator))
                .findFirst();

            if (!found.isPresent() && podName != null) {
                found = Files.walk(sourceRoot)
                    .filter(p -> p.getFileName().toString().equals(sourceName))
                    .findFirst();
            }

            return found.map(Path::toString).orElse(null);

        } catch (Exception e) {
            System.err.println("[SourceMapper] walk error: " + e);
            return null;
        }
    }
}
