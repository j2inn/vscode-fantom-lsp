/**
 * declarationRange.ts
 *
 * Pure helper to find the last line of a Fantom variable declaration that may
 * span multiple lines (list literals, constructor with-blocks, etc.).
 *
 * No VS Code dependency — accepts a plain line-getter so it can be unit-tested
 * with plain arrays.
 */

/**
 * Returns the index of the first non-blank line >= `from`, or -1 if none.
 */
function nextNonBlankLine(
  getLine: (i: number) => string,
  lineCount: number,
  from: number
): number {
  for (let i = from; i < lineCount; i++) {
    if (getLine(i).trim() !== '') { return i; }
  }
  return -1;
}

/**
 * Given the line number where an unused variable is declared, returns the
 * index of the last line that belongs to that declaration.
 *
 * Rules:
 *  - Tracks brace/bracket/paren depth character-by-character.
 *  - If the start line ends with depth > 0, the declaration is multi-line;
 *    scanning continues until depth returns to 0 (or goes negative = safety stop).
 *  - If the start line ends with depth == 0, check whether the next non-blank
 *    line opens a Fantom with-block (`{`).  If so, continue scanning.
 *  - String content is not parsed: brackets inside string literals may cause
 *    false positives in pathological cases, but these are rare in practice.
 */
export function getDeclarationEndLine(
  getLine: (i: number) => string,
  lineCount: number,
  startLine: number
): number {
  let depth = 0;
  let hasOpened = false; // true once we've seen at least one opening bracket

  for (let i = startLine; i < lineCount; i++) {
    const text = getLine(i);

    for (const ch of text) {
      if (ch === '{' || ch === '[' || ch === '(') { depth++; hasOpened = true; }
      else if (ch === '}' || ch === ']' || ch === ')') { depth--; }
    }

    if (i === startLine) {
      if (depth > 0) {
        // Unclosed bracket on the start line — multi-line block, keep scanning.
        continue;
      }
      // depth === 0 (brackets balanced on start line or none at all):
      // check whether the next non-blank line starts a Fantom with-block.
      const next = nextNonBlankLine(getLine, lineCount, i + 1);
      if (next !== -1 && getLine(next).trimStart().startsWith('{')) {
        // With-block attached to this declaration — keep scanning.
        continue;
      }
      return startLine;
    }

    // Past the start line: only stop once we have actually entered a block.
    // Before seeing any opening bracket we may be crossing blank lines between
    // the declaration and its with-block — don't stop yet.
    if (hasOpened && depth <= 0) {
      // depth < 0 means we walked into the enclosing block's closing brace.
      return depth < 0 ? i - 1 : i;
    }
  }

  return startLine;
}
