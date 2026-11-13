/**
 * configSafety.ts
 *
 * Pure checks for values read from fan.config.json, a file that lives in the
 * workspace and so can come from an untrusted repository. On Windows the fan
 * launcher is a .bat script and is spawned through cmd.exe, which interprets
 * metacharacters in its command line.
 *
 * No VS Code dependency — runs under plain Node for unit tests.
 */

/** Characters cmd.exe treats as command separators, redirections or escapes. */
const SHELL_METACHARACTERS = /[&|<>^%"\r\n]/;

/** A build target is one plain token such as `compile` or `test`. */
const SAFE_BUILD_TARGET = /^[\w.:-]+$/;

/** True if `value` contains a character that a shell would interpret. */
export function hasShellMetacharacters(value: string): boolean {
  return SHELL_METACHARACTERS.test(value);
}

/** True if `target` is safe to pass as the fan build target argument. */
export function isSafeBuildTarget(target: string): boolean {
  return SAFE_BUILD_TARGET.test(target);
}
