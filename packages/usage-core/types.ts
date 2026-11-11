interface UsageAmount { unit: string; used?: number; limit?: number; remaining?: number }
interface UsageWindow { id: string; label: string; durationMs?: number; resetsAt?: number; resetLabel?: string; estimated?: boolean }
export interface UsageLimit { id: string; label: string; amount: UsageAmount; window?: UsageWindow; usedFraction?: number; status?: string; notes: string[] }
export interface UsageAccount { id: string; provider: string; label: string; fetchedAt: number; plan?: string; notes: string[]; limits: UsageLimit[] }
export interface UsageUnavailable { provider: string; label: string; reason: string }
export interface UsageSnapshot { version: 1; capturedAt: number; accounts: UsageAccount[]; unavailable: UsageUnavailable[] }
export interface CollectionResult { snapshot: UsageSnapshot | null; source: 'live' | 'cache' | 'stale' | 'unavailable'; error?: string }
export interface CollectorOptions { ompBin?: string; profile?: string; cacheDir?: string; maxAgeMs?: number; timeoutMs?: number; force?: boolean; now?: number }
