using afIoc

**
** LspModule - afIoc service registrations for Fantom LSP
**
const class LspModule
{
  Void defineServices(RegistryBuilder bob)
  {
    bob.addService(DocumentManager#)
    bob.addService(ProjectIndex#)
    bob.addService(DiagnosticService#)
    bob.addService(CompletionService#)
    bob.addService(DefinitionService#)
    bob.addService(HoverService#)
    bob.addService(LspServer#)
  }
}
