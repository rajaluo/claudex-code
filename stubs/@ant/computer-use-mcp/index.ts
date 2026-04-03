/**
 * Stub for @ant/computer-use-mcp (Anthropic private package).
 * Computer Use MCP server - only used when CHICAGO_MCP feature is enabled.
 * Since feature('CHICAGO_MCP') returns false in our polyfill,
 * these exports are never called at runtime.
 */

export const API_RESIZE_PARAMS = { width: 1366, height: 768 }
export const targetImageSize = { width: 1366, height: 768 }
export const DEFAULT_GRANT_FLAGS = {}

export function buildComputerUseTools(): never[] {
  return []
}

export function bindSessionContext(_ctx: unknown): void {
  // no-op stub
}

export type ComputerUseSessionContext = Record<string, unknown>
export type CuCallToolResult = Record<string, unknown>
export type CuPermissionRequest = Record<string, unknown>
export type CuPermissionResponse = Record<string, unknown>
export type ScreenshotDims = { width: number; height: number }
