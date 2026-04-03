/**
 * Polyfill for Anthropic's custom bun:bundle module.
 *
 * In Anthropic's private build system, feature(name) is resolved at BUILD TIME
 * by their custom Bun fork - it acts like C's #define, enabling dead-code
 * elimination. Internal-only features return true in the internal build;
 * the external npm release has them hardcoded to false (DCE'd away).
 *
 * This polyfill returns false for ALL feature flags, matching the behavior
 * of the publicly released npm package (@anthropic-ai/claude-code).
 *
 * Features that return false (disabled in external build):
 *   ABLATION_BASELINE, TRANSCRIPT_CLASSIFIER, COORDINATOR_MODE, KAIROS,
 *   DIRECT_CONNECT, LODESTONE, SSH_REMOTE, BG_SESSIONS, CHICAGO_MCP,
 *   UPLOAD_USER_SETTINGS, FORK_SUBAGENT (some), etc.
 *
 * Features that return true (enabled in external build):
 *   FORK_SUBAGENT, MCP_SKILLS, and other public features.
 *   Since we can't know exactly which are enabled, we default all to false.
 *   This matches minimum viable external behavior.
 */
export function feature(_name: string): boolean {
  return false
}
