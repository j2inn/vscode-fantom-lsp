
**
** LspUtilTest - Tests for URI/path conversion utilities in LspUtil.
** Covers normalizeFileUri, uriToFile, pathToFileUri, and getLine,
** with particular focus on Windows drive-letter paths.
**
class LspUtilTest : Test
{

//////////////////////////////////////////////////////////////////////////
// normalizeFileUri
//////////////////////////////////////////////////////////////////////////

  Void testNormalizeUnixPath()
  {
    verifyEq(
      LspUtil.normalizeFileUri("file:///home/user/project/Foo.fan"),
      "file:///home/user/project/Foo.fan")
  }

  Void testNormalizeWindowsUppercaseDrive()
  {
    // VSCode on Windows sends file:///C:/Users/foo — drive letter must be lowercased
    verifyEq(
      LspUtil.normalizeFileUri("file:///C:/Users/foo/Bar.fan"),
      "file:///c:/Users/foo/Bar.fan")
  }

  Void testNormalizeWindowsLowercaseDriveUnchanged()
  {
    verifyEq(
      LspUtil.normalizeFileUri("file:///c:/Users/foo/Bar.fan"),
      "file:///c:/Users/foo/Bar.fan")
  }

  Void testNormalizeWindowsPercentEncodedColonUppercase()
  {
    // file:///C%3A/Users/foo  (%3A = colon, uppercase)
    verifyEq(
      LspUtil.normalizeFileUri("file:///C%3A/Users/foo/Bar.fan"),
      "file:///c:/Users/foo/Bar.fan")
  }

  Void testNormalizeWindowsPercentEncodedColonLowercase()
  {
    // file:///c%3a/Users/foo  (%3a = colon, lowercase)
    verifyEq(
      LspUtil.normalizeFileUri("file:///c%3a/Users/foo/Bar.fan"),
      "file:///c:/Users/foo/Bar.fan")
  }

  Void testNormalizeWindowsBackslashes()
  {
    verifyEq(
      LspUtil.normalizeFileUri("file:///C:\\Users\\foo\\Bar.fan"),
      "file:///c:/Users/foo/Bar.fan")
  }

  Void testNormalizeNonFileUriPassthrough()
  {
    // Non-file URIs must be returned unchanged
    verifyEq(
      LspUtil.normalizeFileUri("http://example.com/foo"),
      "http://example.com/foo")
  }

  Void testNormalizeSingleSlashPassthrough()
  {
    // normalizeFileUri only processes "file://" URIs; single-slash URIs pass through
    verifyEq(
      LspUtil.normalizeFileUri("file:/home/user/Foo.fan"),
      "file:/home/user/Foo.fan")
  }

//////////////////////////////////////////////////////////////////////////
// uriToFile — osPath extraction
//////////////////////////////////////////////////////////////////////////

  Void testUriToFileUnix()
  {
    f := LspUtil.uriToFile("file:///home/user/project/Foo.fan")
    verifyEq(f.osPath, "/home/user/project/Foo.fan")
  }

  Void testUriToFileWindowsUppercaseDrive()
  {
    // Root cause of the Windows completions bug:
    // Before the fix, File(Uri.decode(...)) passed "/c:/Users/foo" to
    // java.io.File, which on Windows resolves to C:\c:\Users\foo.
    // After the fix, File.os("c:/Users/foo") is used instead.
    f := LspUtil.uriToFile("file:///C:/Users/foo/Bar.fan")
    verifyEq(f.osPath, "c:/Users/foo/Bar.fan")
  }

  Void testUriToFileWindowsLowercaseDrive()
  {
    f := LspUtil.uriToFile("file:///c:/Users/foo/Bar.fan")
    verifyEq(f.osPath, "c:/Users/foo/Bar.fan")
  }

  Void testUriToFileWindowsPercentEncodedColon()
  {
    f := LspUtil.uriToFile("file:///c%3A/Users/foo/Bar.fan")
    verifyEq(f.osPath, "c:/Users/foo/Bar.fan")
  }

  Void testUriToFileWindowsBackslashes()
  {
    f := LspUtil.uriToFile("file:///C:\\Users\\foo\\Bar.fan")
    verifyEq(f.osPath, "c:/Users/foo/Bar.fan")
  }

  Void testUriToFileSpacesDecoded()
  {
    // %20 must be decoded to space in the OS path
    f := LspUtil.uriToFile("file:///home/my%20docs/Foo.fan")
    verifyEq(f.osPath, "/home/my docs/Foo.fan")
  }

  Void testUriToFileWindowsSpacesDecoded()
  {
    f := LspUtil.uriToFile("file:///c:/My%20Documents/Foo.fan")
    verifyEq(f.osPath, "c:/My Documents/Foo.fan")
  }

//////////////////////////////////////////////////////////////////////////
// pathToFileUri
//////////////////////////////////////////////////////////////////////////

  Void testPathToFileUriUnix()
  {
    verifyEq(
      LspUtil.pathToFileUri("/home/user/project/Foo.fan"),
      "file:///home/user/project/Foo.fan")
  }

  Void testPathToFileUriWindowsUppercase()
  {
    // Backslashes replaced, drive letter lowercased
    verifyEq(
      LspUtil.pathToFileUri("C:\\Users\\foo\\Bar.fan"),
      "file:///c:/Users/foo/Bar.fan")
  }

  Void testPathToFileUriWindowsLowercase()
  {
    verifyEq(
      LspUtil.pathToFileUri("c:/Users/foo/Bar.fan"),
      "file:///c:/Users/foo/Bar.fan")
  }

  Void testPathToFileUriWindowsForwardSlashes()
  {
    // Already using forward slashes but no leading /
    verifyEq(
      LspUtil.pathToFileUri("C:/Users/foo/Bar.fan"),
      "file:///c:/Users/foo/Bar.fan")
  }

//////////////////////////////////////////////////////////////////////////
// normalizeFileUri round-trips with uriToFile
//////////////////////////////////////////////////////////////////////////

  Void testRoundTripUnix()
  {
    uri := "file:///home/user/project/Foo.fan"
    verifyEq(LspUtil.normalizeFileUri(uri), uri)
    f := LspUtil.uriToFile(uri)
    verifyEq(f.osPath, "/home/user/project/Foo.fan")
  }

  Void testRoundTripWindowsVariants()
  {
    variants := [
      "file:///C:/Users/foo/Bar.fan",
      "file:///c:/Users/foo/Bar.fan",
      "file:///C%3A/Users/foo/Bar.fan",
      "file:///c%3a/Users/foo/Bar.fan",
    ]
    variants.each |v|
    {
      norm := LspUtil.normalizeFileUri(v)
      verifyEq(norm, "file:///c:/Users/foo/Bar.fan",
        "normalizeFileUri failed for: $v")
      f := LspUtil.uriToFile(v)
      verifyEq(f.osPath, "c:/Users/foo/Bar.fan",
        "uriToFile osPath failed for: $v")
    }
  }

//////////////////////////////////////////////////////////////////////////
// getLine — line splitting
//////////////////////////////////////////////////////////////////////////

  Void testGetLineUnixEndings()
  {
    src := "line0\nline1\nline2"
    verifyEq(LspUtil.getLine(src, 0), "line0")
    verifyEq(LspUtil.getLine(src, 1), "line1")
    verifyEq(LspUtil.getLine(src, 2), "line2")
  }

  Void testGetLineWindowsEndingsNoTrailingCr()
  {
    // splitLines() must strip \r so callers don't see it in word extraction
    src := "line0\r\nline1\r\nline2"
    verifyEq(LspUtil.getLine(src, 0), "line0")
    verifyEq(LspUtil.getLine(src, 1), "line1")
    verifyEq(LspUtil.getLine(src, 2), "line2")
  }

  Void testGetLineOutOfBoundsReturnsNull()
  {
    src := "only one line"
    verifyNull(LspUtil.getLine(src, 1))
  }

}
