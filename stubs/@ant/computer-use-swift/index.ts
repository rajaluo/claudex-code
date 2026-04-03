/** Stub for @ant/computer-use-swift (macOS native swift module) */

export interface ComputerUseAPI {
  screenshot(): Promise<Buffer>
  click(x: number, y: number): Promise<void>
  type(text: string): Promise<void>
}
