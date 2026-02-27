
using util

**
** LSP Protocol - JSON-RPC message handling
**
class LspProtocol
{
  **
  ** Read a JSON-RPC message from the input stream
  ** Returns null if EOF is reached
  **
  static [Str:Obj?]? readMessage(InStream in)
  {
    try
    {
      // Read headers
      headers := Str:Str[:]
      while (true)
      {
        line := in.readLine
        if (line == null) return null // EOF
        if (line.isEmpty) break  // End of headers

        colon := line.index(":")
        if (colon != null)
        {
          key := line[0..<colon].trim
          val := line[colon+1..-1].trim
          headers[key] = val
        }
      }

      // Get content length
      contentLengthStr := headers["Content-Length"]
      if (contentLengthStr == null)
        throw Err("Missing Content-Length header")

      contentLength := contentLengthStr.toInt

      // Read content
      buf := Buf(contentLength)
      buf.writeBuf(in.readBufFully(null, contentLength))
      buf.flip

      // Parse JSON
      json := JsonInStream(buf.in).readJson
      return json as Str:Obj?
    }
    catch (Err e)
    {
      // Log error to file, not stdout
      logErr("Error reading message: $e")
      return null
    }
  }

  **
  ** Write a JSON-RPC message to the output stream
  **
  static Void writeMessage(OutStream out, Str:Obj? message)
  {
    try
    {
      // Serialize JSON
      jsonBuf := Buf()
      JsonOutStream(jsonBuf.out).writeJson(message)
      jsonStr := jsonBuf.flip.readAllStr

      // Write headers
      out.print("Content-Length: ${jsonStr.size}\r\n")
      out.print("\r\n")

      // Write content
      out.print(jsonStr)
      out.flush
    }
    catch (Err e)
    {
      logErr("Error writing message: $e")
    }
  }

  **
  ** Create a response message
  **
  static Str:Obj? createResponse(Obj? id, Obj? result)
  {
    return Str:Obj?["jsonrpc": "2.0", "id": id, "result": result]
  }

  **
  ** Create an error response
  **
  static Str:Obj? createErrorResponse(Obj? id, Int code, Str message)
  {
    return Str:Obj?[
      "jsonrpc": "2.0",
      "id": id,
      "error": Str:Obj?["code": code, "message": message]
    ]
  }

  **
  ** Create a notification (no id)
  **
  static Str:Obj? createNotification(Str method, Obj? params)
  {
    msg := Str:Obj?["jsonrpc": "2.0", "method": method]
    if (params != null) msg["params"] = params
    return msg
  }

  **
  ** Create a request from server to client (has id and method).
  **
  static Str:Obj? createRequest(Int id, Str method, Obj? params)
  {
    msg := Str:Obj?["jsonrpc": "2.0", "id": id, "method": method]
    if (params != null) msg["params"] = params
    return msg
  }

  **
  ** Check if message is a request (has id and method)
  **
  static Bool isRequest(Str:Obj? message)
  {
    return message.containsKey("id") && message.containsKey("method")
  }

  **
  ** Check if message is a notification (no id)
  **
  static Bool isNotification(Str:Obj? message)
  {
    return message.containsKey("method") && !message.containsKey("id")
  }

  **
  ** Check if message is a response (has id but no method)
  **
  static Bool isResponse(Str:Obj? message)
  {
    return message.containsKey("id") && !message.containsKey("method")
  }

  **
  ** Log error to file (not stdout which is used for LSP communication)
  **
  private static Void logErr(Str msg)
  {
    try
    {
      logFile := LspUtil.tempDir + `fantom-lsp.log`
      out := logFile.out(true)  // append
      out.printLine("${DateTime.now}: $msg")
      out.close
    }
    catch (Err e)
    {
      // Can't log - ignore
    }
  }

  **
  ** Log info to file
  **
  static Void logInfo(Str msg)
  {
    try
    {
      logFile := LspUtil.tempDir + `fantom-lsp.log`
      out := logFile.out(true)  // append
      out.printLine("${DateTime.now}: $msg")
      out.close
    }
    catch (Err e)
    {
      // Can't log - ignore
    }
  }
}
