/** Stub for @ant/computer-use-mcp/types */

export type CoordinateMode = 'pixels' | 'percent'

export interface CuSubGates {
  pixelValidation?: boolean
  clipboardPasteMultiline?: boolean
  mouseAnimation?: boolean
  hideBeforeAction?: boolean
  autoTargetDisplay?: boolean
  clipboardGuard?: boolean
}

export type CuPermissionRequest = Record<string, unknown>
export type CuPermissionResponse = Record<string, unknown>
export const DEFAULT_GRANT_FLAGS = {}
