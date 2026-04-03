export const OUTPUTS_SUBDIR = 'outputs'
export const DEFAULT_UPLOAD_CONCURRENCY = 5
export const FILE_COUNT_LIMIT = 100
export interface PersistedFile { path: string; content: string }
export interface FailedPersistence { path: string; error: string }
export interface FilesPersistedEventData { files: PersistedFile[] }
export type TurnStartTime = number
