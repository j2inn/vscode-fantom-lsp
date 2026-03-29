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
	HoverService hoverService := HoverService()
	PodWatchService podWatcher := PodWatchService()
	CodeActionService codeActionSvc := CodeActionService()
	FormatterService formatterSvc := FormatterService()

	LspServer server

	new make()
	{
		server = LspServer(docMgr, projectIndex, diagnostics, completion, definition, hoverService, podWatcher, codeActionSvc, formatterSvc)
	}
}
