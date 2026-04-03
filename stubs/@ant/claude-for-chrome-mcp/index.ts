/** Stub for @ant/claude-for-chrome-mcp (Chrome extension MCP server) */

export const BROWSER_TOOLS: string[] = []

export type ClaudeForChromeContext = Record<string, unknown>
export type Logger = { log: (...args: unknown[]) => void }
export type PermissionMode = string

export function createClaudeForChromeMcpServer(
  _context: ClaudeForChromeContext,
): { connect: (_transport: unknown) => Promise<void> } {
  return { connect: async () => {} }
}
