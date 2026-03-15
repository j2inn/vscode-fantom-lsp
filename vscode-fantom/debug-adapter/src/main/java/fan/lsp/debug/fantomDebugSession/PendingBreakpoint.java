package fan.lsp.debug.fantomDebugSession;

/** A breakpoint that could not be installed yet because its class is not loaded. */
public class PendingBreakpoint {
    public final String sourceName;
    public final int    line;

    public PendingBreakpoint(String sourceName, int line) {
        this.sourceName = sourceName;
        this.line       = line;
    }
}
