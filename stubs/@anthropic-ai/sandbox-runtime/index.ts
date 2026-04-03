import { z } from 'zod'

export const SandboxRuntimeConfigSchema = z.object({}).passthrough()

export interface FsReadRestrictionConfig { paths: string[] }
export interface FsWriteRestrictionConfig { paths: string[] }
export interface IgnoreViolationsConfig { enabled: boolean }
export interface NetworkHostPattern { host: string }
export interface NetworkRestrictionConfig { hosts: NetworkHostPattern[] }
export type SandboxAskCallback = (event: unknown) => Promise<boolean>
export type SandboxDependencyCheck = () => Promise<boolean>
export type SandboxRuntimeConfig = z.infer<typeof SandboxRuntimeConfigSchema>
export type SandboxViolationEvent = { type: string; details: unknown }

export class SandboxViolationStore {
  add(_event: SandboxViolationEvent): void {}
  getAll(): SandboxViolationEvent[] { return [] }
  clear(): void {}
}

export class SandboxManager {
  constructor(_config: SandboxRuntimeConfig) {}
  async start(): Promise<void> {}
  async stop(): Promise<void> {}
  isRunning(): boolean { return false }
  getViolationStore(): SandboxViolationStore { return new SandboxViolationStore() }
}
