export type SyntaxTheme = Record<string, string>

export class ColorDiff {
  constructor(_opts?: unknown) {}
  diff(_a: string, _b: string): string[] { return [] }
}

export class ColorFile {
  constructor(_opts?: unknown) {}
  highlight(_code: string, _lang: string): string { return '' }
}

export function getSyntaxTheme(_name: string): SyntaxTheme | null { return null }
