package fan.lsp.debug;

/**
 * Entry point for the Fantom Debug Adapter.
 *
 * Launched by the VS Code extension as:
 *   java --add-modules jdk.jdi -jar fantom-debug-adapter.jar
 *
 * Communicates with VS Code over stdin/stdout using the Debug Adapter Protocol.
 */
public class Main {
    public static void main(String[] args) throws Exception {
        System.err.println("[FantomDAP] Starting Fantom Debug Adapter");
        new DapServer().run();
    }
}
