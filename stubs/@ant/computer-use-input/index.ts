/** Stub for @ant/computer-use-input */

export interface ComputerUseInput {
  type: string
}

export interface ComputerUseInputAPI {
  execute(input: ComputerUseInput): Promise<void>
}
