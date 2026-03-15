package fan.lsp.debug.fantomDebugSession;

import com.google.gson.*;
import com.sun.jdi.*;
import com.sun.jdi.request.*;

import java.io.File;
import java.util.*;

/** Manages breakpoint installation, deferral and removal. */
public class BreakpointManager {

    private final SessionContext ctx;

    public BreakpointManager(SessionContext ctx) {
        this.ctx = ctx;
    }

    public JsonObject setBreakpoints(JsonObject args) {
        JsonArray result = new JsonArray();

        if (ctx.vm == null) {
            JsonObject body = new JsonObject();
            body.add("breakpoints", result);
            return body;
        }

        JsonObject source    = args.getAsJsonObject("source");
        String sourcePath    = source.has("path") ? source.get("path").getAsString() : "";
        String sourceName    = new File(sourcePath).getName(); // e.g. "MyClass.fan"

        JsonArray bpRequests = args.has("breakpoints")
            ? args.getAsJsonArray("breakpoints") : new JsonArray();

        clearBreakpointsForFile(sourceName);

        for (JsonElement el : bpRequests) {
            int     line      = el.getAsJsonObject().get("line").getAsInt();
            boolean installed = tryInstallBreakpoint(sourceName, line);
            if (!installed)
                ctx.pendingBreakpoints.add(new PendingBreakpoint(sourceName, line));

            JsonObject bp = new JsonObject();
            bp.addProperty("verified", installed);
            bp.addProperty("line",     line);
            result.add(bp);
        }

        JsonObject body = new JsonObject();
        body.add("breakpoints", result);
        return body;
    }

    public void clearBreakpointsForFile(String sourceName) {
        List<BreakpointRequest> toRemove = new ArrayList<>();
        for (BreakpointRequest br : ctx.vm.eventRequestManager().breakpointRequests()) {
            try {
                if (sourceName.equals(br.location().sourceName())) toRemove.add(br);
            } catch (Exception ignore) {}
        }
        ctx.vm.eventRequestManager().deleteEventRequests(toRemove);
        ctx.pendingBreakpoints.removeIf(pb -> sourceName.equals(pb.sourceName));
    }

    public boolean tryInstallBreakpoint(String sourceName, int line) {
        for (ReferenceType rt : ctx.vm.allClasses()) {
            try {
                if (!sourceName.equals(rt.sourceName())) continue;
                List<Location> locs = rt.locationsOfLine(line);
                if (!locs.isEmpty()) {
                    BreakpointRequest br = ctx.vm.eventRequestManager()
                        .createBreakpointRequest(locs.get(0));
                    br.setSuspendPolicy(EventRequest.SUSPEND_ALL);
                    br.enable();
                    System.err.println("[JDI] Breakpoint set: " + sourceName + ":" + line);
                    return true;
                }
            } catch (Exception ignore) {}
        }
        return false;
    }

    public void installPendingBreakpoints(ReferenceType rt) {
        Iterator<PendingBreakpoint> it = ctx.pendingBreakpoints.iterator();
        while (it.hasNext()) {
            PendingBreakpoint pb = it.next();
            try {
                if (!pb.sourceName.equals(rt.sourceName())) continue;
                List<Location> locs = rt.locationsOfLine(pb.line);
                if (!locs.isEmpty()) {
                    BreakpointRequest br = ctx.vm.eventRequestManager()
                        .createBreakpointRequest(locs.get(0));
                    br.setSuspendPolicy(EventRequest.SUSPEND_ALL);
                    br.enable();
                    it.remove();
                    System.err.println("[JDI] Pending breakpoint installed: "
                        + pb.sourceName + ":" + pb.line);

                    JsonObject bpBody = new JsonObject();
                    bpBody.addProperty("reason", "changed");
                    JsonObject bpInfo = new JsonObject();
                    bpInfo.addProperty("verified", true);
                    bpInfo.addProperty("line",     pb.line);
                    bpBody.add("breakpoint", bpInfo);
                    ctx.server.sendEvent("breakpoint", bpBody);
                }
            } catch (Exception e) {
                System.err.println("[JDI] Error installing pending breakpoint: " + e);
            }
        }
    }
}
