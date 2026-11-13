/**
 * removalSafety.ts
 *
 * Pure checks that decide whether a line reported by a diagnostic is still
 * safe to delete. Diagnostics can lag behind the buffer (they are produced
 * after a debounce) and are heuristic, so the bulk "remove unused" commands
 * re-check the current text of each line before deleting it.
 *
 * No VS Code dependency — runs under plain Node for unit tests.
 */

/** Modifiers that mark a class member (not a local variable) declaration. */
const MEMBER_MODIFIERS = /^\s*(?:private|public|protected|internal|static|const|virtual|override|native|final|abstract|readonly)\b/;

/** Extracts the quoted variable name from an "is declared but never used" message. */
export function unusedVariableName(message: string): string | undefined {
  const match = /'([^']+)' is declared but never used/.exec(message);
  return match ? match[1] : undefined;
}

/** True if the current text of the line is still a `using` import. */
export function isUnusedImportLineSafeToDelete(lineText: string): boolean {
  return /^\s*using\s+\S/.test(lineText);
}

/**
 * True if `declText` (the full text of the declaration, possibly joined from
 * several lines) is a local `[Type] name := value` statement that can be
 * deleted without losing a side effect: no member modifier and no call in the
 * initializer.
 */
export function isUnusedVariableSafeToDelete(declText: string, varName: string): boolean {
  if (MEMBER_MODIFIERS.test(declText)) { return false; }

  const escaped = varName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const decl = new RegExp(`^\\s*(?:[A-Za-z_][\\w?\\[\\]:]*\\s+)?${escaped}\\s*:=(.*)$`, 's');
  const match = decl.exec(declText);
  if (!match) { return false; }

  // A call in the initializer may have side effects; keep it.
  return !match[1].includes('(');
}
