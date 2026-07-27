**
** LspModule - service registry (manual wiring; no external IoC required)
**
class LspModule
{
	DocumentManager docMgr := DocumentManager()
	ProjectIndex projectIndex := ProjectIndex()
	DiagnosticService diagnostics := DiagnosticService()
	CompletionService completion := CompletionService()
	DefinitionService definition := DefinitionService()
	TypeDefinitionService typeDefinition := TypeDefinitionService()
	InlayHintService inlayHintSvc := InlayHintService()
	HoverService hoverService := HoverService()
	PodWatchService podWatcher := PodWatchService()
	CodeActionService codeActionSvc := CodeActionService()
	FormatterService formatterSvc := FormatterService()
	ReferencesService referencesSvc := ReferencesService()
	RenameService renameSvc := RenameService()

	LspServer server

	new make()
	{
		server = LspServer(docMgr, projectIndex, diagnostics, completion, definition, typeDefinition, inlayHintSvc, hoverService, podWatcher, codeActionSvc, formatterSvc, referencesSvc, renameSvc)
	}
}
