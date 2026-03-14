package fan.lsp.debug;

import java.io.File;
import java.nio.file.*;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

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
