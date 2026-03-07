
using afIoc

**
** Main entry point for the Fantom Language Server
**
class Main
{
  **
  ** Main method - starts the LSP server
  **
  static Void main(Str[] args := Str#.emptyList)
  {
    Registry? registry := null
    try
    {
      LspProtocol.logInfo("Starting Fantom Language Server")

      // Build IoC registry and resolve server
      registry = RegistryBuilder()
        .silent
        .addModule(LspModule#)
        .build
      server := (LspServer) registry.rootScope.serviceByType(LspServer#)

      // Get stdin and stdout
      in := Env.cur.in

      // Main loop - read messages from stdin
      while (true)
      {
        // Read message
        message := LspProtocol.readMessage(in)
        if (message == null) break  // EOF

        // Handle message
        server.handleMessage(message)

        // Check for exit
        if (message["method"] == "exit")
          break
      }

      LspProtocol.logInfo("Fantom Language Server stopped")
    }
    catch (Err e)
    {
      LspProtocol.logInfo("Fatal error: $e")
      e.trace
    }
    finally
    {
      try
      {
        if (registry != null)
          registry.shutdown
      }
      catch (Err e)
      {
        LspProtocol.logInfo("Error shutting down IoC registry: $e")
      }
    }
  }
}
