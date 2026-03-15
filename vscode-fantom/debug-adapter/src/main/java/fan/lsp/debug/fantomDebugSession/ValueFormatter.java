package fan.lsp.debug.fantomDebugSession;

import com.sun.jdi.*;

import java.util.*;

/**
 * JDI value / type formatting for the Variables, Watch and hover panels.
 *
 * All methods are intentionally free of side-effects on the JVM (no
 * invokeMethod calls) so they are safe to call from any thread while the
 * VM is suspended.
 */
public class ValueFormatter {

    private final SessionContext ctx;

    public ValueFormatter(SessionContext ctx) {
        this.ctx = ctx;
    }

    // ── Safe formatting (never invokes JVM methods) ──────────────────────

    /**
     * Format a value for display in the Variables / Watch panel.
     *
     * Deliberately avoids invokeMethod/INVOKE_SINGLE_THREADED, which would
     * resume the stopped thread and cause concurrent JDI frame-access calls
     * to throw IncompatibleThreadStateException — emptying the Variables panel.
     *
     * Complex objects are shown as "pod::Type@id"; users can expand the node
     * to browse fields, matching the behaviour of IntelliJ / Eclipse when
     * toString() is not invoked automatically.
     */
    public String safeFormatValue(Value v) {
        if (v == null) return "null";

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

            // Fantom boxed primitives — unwrap the inner 'val' field directly
            if (typeName.equals("fan.sys.Int$Val")) {
                Value inner = getField(obj, "val");
                if (inner != null) return safeFormatValue(inner);
            }
            if (typeName.equals("fan.sys.Float$Val")) {
                Value inner = getField(obj, "val");
                if (inner != null) return safeFormatValue(inner);
            }
            if (typeName.equals("fan.sys.Bool$True"))  return "true";
            if (typeName.equals("fan.sys.Bool$False")) return "false";

            return jvmTypeToFantom(typeName) + "@" + obj.uniqueID();
        }

        return v.toString();
    }

    // ── Type display ─────────────────────────────────────────────────────

    public String formatType(Value v) {
        if (v == null) return "null";
        if (v instanceof BooleanValue)  return "sys::Bool";
        if (v instanceof LongValue
         || v instanceof IntegerValue
         || v instanceof ByteValue
         || v instanceof ShortValue)    return "sys::Int";
        if (v instanceof DoubleValue
         || v instanceof FloatValue)    return "sys::Float";
        if (v instanceof CharValue)     return "sys::Int"; // Fantom Char is Int
        if (v instanceof StringReference) return "sys::Str";
        if (v instanceof ObjectReference)
            return jvmTypeToFantom(((ObjectReference) v).type().name());
        return v.type().name();
    }

    public static String formatDeclType(String declType) {
        if (declType == null) return "?";
        return jvmTypeToFantom(declType);
    }

    /**
     * Translate a JVM class name to a Fantom-style pod::Type name.
     *
     * Examples:
     *   fan.myPod.MyClass          → myPod::MyClass
     *   fan.sys.Int$Val            → sys::Int
     *   [Lfan.myPod.MyClass;       → myPod::MyClass[]
     *   java.lang.String           → sys::Str
     */
    public static String jvmTypeToFantom(String name) {
        if (name == null || name.isEmpty()) return "?";

        // Array descriptors:  [Lfan.pod.Type;  →  pod::Type[]
        if (name.startsWith("[L") && name.endsWith(";"))
            return jvmTypeToFantom(name.substring(2, name.length() - 1)) + "[]";

        if (name.equals("[J") || name.equals("[I")) return "sys::Int[]";
        if (name.equals("[D") || name.equals("[F")) return "sys::Float[]";
        if (name.equals("[Z"))                      return "sys::Bool[]";

        // Fantom classes:  fan.podName.ClassName[$Variant]
        if (name.startsWith("fan.")) {
            String[] parts = name.split("\\.", 3);
            if (parts.length < 3) return parts.length == 2 ? parts[1] : name;
            String pod      = parts[1];
            String typePart = parts[2];
            int dollar = typePart.indexOf('$');
            if (dollar >= 0) typePart = typePart.substring(0, dollar);
            return pod + "::" + typePart;
        }

        // Common Java → Fantom mappings
        switch (name) {
            case "java.lang.String":     return "sys::Str";
            case "java.lang.Long":       return "sys::Int";
            case "java.lang.Integer":    return "sys::Int";
            case "java.lang.Double":     return "sys::Float";
            case "java.lang.Float":      return "sys::Float";
            case "java.lang.Boolean":    return "sys::Bool";
            case "java.lang.Object":     return "sys::Obj";
            case "java.math.BigDecimal": return "sys::Decimal";
            default: return name;
        }
    }

    // ── Frame name ───────────────────────────────────────────────────────

    public String formatFrameName(Location loc) {
        String cls    = loc.declaringType().name();
        String method = loc.method().name();
        if (cls.startsWith("fan.")) {
            String[] parts = cls.split("\\.", 3);
            if (parts.length == 3) return parts[1] + "::" + parts[2] + "." + method;
            if (parts.length == 2) return parts[1] + "." + method;
        }
        return cls + "." + method;
    }

    // ── Low-level helpers ────────────────────────────────────────────────

    /** Read a field value from an ObjectReference without invoking any methods. */
    public static Value getField(ObjectReference obj, String fieldName) {
        try {
            Field f = obj.referenceType().fieldByName(fieldName);
            if (f != null) return obj.getValue(f);
        } catch (Exception ignore) {}
        return null;
    }

    public static String escapeStr(String s) {
        return s.replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n",  "\\n")
                .replace("\r",  "\\r");
    }
}
