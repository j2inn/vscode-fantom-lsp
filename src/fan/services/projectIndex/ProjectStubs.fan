
**
** ProjectStubs - Caches signature-only stubs of project files (see
** 'SourceStubber') and the subset of them that can be compiled together.
**
** A stub is usable only when it compiles cleanly up to expression
** resolution: a stub that references a type from an unloadable pod, or a
** project type whose own stub is unusable, is excluded. Usability is decided
** by compiling the stubs together (see 'StubbedCompiler.stubsWithErrs') and
** excluding the files that report errors until no errors remain. Types of
** excluded files stay unresolved, and the diagnostics fall back to
** replacing them.
**
class ProjectStubs
{
  ** Upper bound on validation rounds (each round excludes at least one file)
  private static const Int maxValidationRounds := 32

  ** Last successfully generated stub per file URI
  private Str:ProjectStubEntry entryByUri := Str:ProjectStubEntry[:]

  ** Source each file was last stubbed from (successfully or not), per URI
  private Str:Str stubbedSourceByUri := Str:Str[:]

  ** Cache key of the last validation (pod name + stub hashes)
  private Str? validatedKey := null

  ** URIs of the stubs that passed the last validation
  private Str[] validatedUris := Str[,]

  **
  ** Return the usable stubs among 'sources' (file URI -> source), keyed by
  ** file URI. 'typeNamesByUri' lists the types each file declares, and
  ** 'podUri' is any file of the pod, used to pick the pod name the stubs
  ** are validated under.
  **
  Str:Str usableStubs(Str:Str sources, Str:Str[] typeNamesByUri, Str podUri)
  {
    stubs := Str:Str[:]
    sources.each |source, uri|
    {
      entry := entryFor(uri, source, typeNamesByUri)
      if (entry != null) stubs[uri] = entry.stub
    }
    if (stubs.isEmpty) return stubs

    key := validationKey(podUri, stubs.keys)
    if (key != validatedKey)
    {
      validatedUris = validate(podUri, stubs)
      validatedKey = key
    }
    return stubs.findAll |stub, uri| { validatedUris.contains(uri) }
  }

  **
  ** Names of the types referenced by the compiled part of the cached stub
  ** of a file (see 'SourceStub.referencedTypes'), empty if it has no stub.
  **
  Str[] stubReferencedTypes(Str uri)
  {
    return entryByUri[uri]?.referencedTypes ?: Str[,]
  }

  **
  ** Return 'stubs' plus a placeholder unit declaring the project types
  ** named in the stubs' text that no stub declares, so that the stubs can
  ** be parsed (see 'SourceStubber.placeholders'). 'typeNamesByUri' lists
  ** the project types per file; 'excludedNames' are never declared.
  **
  ** Only for stubs whose signatures reference compiled types exclusively
  ** (see 'ProjectIndex.stubsFor'): placeholders then only stand for types
  ** used in stub bodies and field initializers, which are not compiled.
  ** Validation never uses placeholders, since a placeholder would satisfy
  ** a signature that references an unusable type.
  **
  Str:Str withPlaceholders(Str:Str stubs, Str:Str[] typeNamesByUri, Str[] excludedNames)
  {
    projectTypes := Str:Bool[:]
    typeNamesByUri.each |names| { names.each |name| { projectTypes[name] = true } }

    declared := Str:Bool[:]
    stubs.each |stub, uri| { typeNamesByUri[uri]?.each |name| { declared[name] = true } }
    excludedNames.each |name| { declared[name] = true }

    missing := Str:Bool[:]
    stubs.each |stub, uri|
    {
      entryByUri[uri]?.identifiers?.each |name|
      {
        if (projectTypes.containsKey(name) && !declared.containsKey(name)) missing[name] = true
      }
    }
    if (missing.isEmpty) return stubs
    return stubs.dup.set(SourceStubber.placeholderUri, SourceStubber.placeholders(missing.keys.sort))
  }

  **
  ** Stub entry for a file, regenerated only when its source changed. When
  ** the current source cannot be stubbed (e.g. a syntax error while
  ** typing), the last good stub is kept.
  **
  private ProjectStubEntry? entryFor(Str uri, Str source, Str:Str[] typeNamesByUri)
  {
    if (stubbedSourceByUri[uri] != source)
    {
      stubbedSourceByUri[uri] = source
      stub := SourceStubber.stub(uri, source, otherTypeNames(uri, typeNamesByUri))
      if (stub != null)
        entryByUri[uri] = ProjectStubEntry(stub, SourceStubber.identifiers(uri, stub.source))
    }
    return entryByUri[uri]
  }

  ** Project type names declared outside the file 'uri'
  private static Str[] otherTypeNames(Str uri, Str:Str[] typeNamesByUri)
  {
    own := typeNamesByUri[uri] ?: Str[,]
    names := Str:Bool[:]
    typeNamesByUri.each |fileNames| { fileNames.each |name| { if (!own.contains(name)) names[name] = true } }
    return names.keys
  }

  **
  ** Compile the stubs together and exclude the files that report
  ** errors, repeating until no errors remain.
  **
  private Str[] validate(Str podUri, Str:Str stubs)
  {
    remaining := stubs.dup
    for (round := 0; round < maxValidationRounds && !remaining.isEmpty; round++)
    {
      compiler := (StubbedCompiler)LspCompiler.create(podUri, "", remaining)
      failed := compiler.stubsWithErrs
      if (failed == null)
      {
        LspProtocol.logInfo("ProjectStubs: errors outside stubs, stubs disabled")
        return Str[,]
      }
      if (failed.isEmpty) break
      failed.each |uri| { remaining.remove(uri) }
    }
    LspProtocol.logInfo("ProjectStubs: ${remaining.size} of ${stubs.size} stubs usable")
    return remaining.keys
  }

  private Str validationKey(Str podUri, Str[] uris)
  {
    buf := StrBuf().add(LspCompiler.podNameFor(podUri))
    uris.sort.each |uri| { buf.addChar('\n').add(uri).addChar(' ').add(entryByUri[uri].stubHash) }
    return buf.toStr
  }
}

**************************************************************************
** ProjectStubEntry
**************************************************************************

**
** A cached stub of one file with the data derived from it.
**
internal class ProjectStubEntry
{
  ** Stub source text
  Str stub

  ** Hash of 'stub', used to detect signature changes
  Int stubHash

  ** Types referenced by the compiled part of the stub
  Str[] referencedTypes

  ** Identifier tokens of the stub text (see 'SourceStubber.identifiers')
  Str[] identifiers

  new make(SourceStub stub, Str[] identifiers)
  {
    this.stub = stub.source
    this.stubHash = stub.source.hash
    this.referencedTypes = stub.referencedTypes
    this.identifiers = identifiers
  }
}
