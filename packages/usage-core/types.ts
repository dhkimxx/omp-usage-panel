interface UsageAmount { unit: string; used?: number; limit?: number; remaining?: number }
interface UsageWindow { id: string; label: string; durationMs?: number; resetsAt?: number; resetLabel?: string; estimated?: boolean }
export interface UsageLimit { id: string; label: string; amount: UsageAmount; window?: UsageWindow; usedFraction?: number; status?: string; notes: string[] }
export interface UsageAccount { id: string; provider: string; label: string; fetchedAt: number; plan?: string; notes: string[]; limits: UsageLimit[] }
export interface UsageUnavailable { provider: string; label: string; reason: string }
export interface UsageSnapshot { version: 1; capturedAt: number; accounts: UsageAccount[]; unavailable: UsageUnavailable[] }
export interface ProviderSource { provider: string; source: 'live' | 'cache' | 'stale' | 'unavailable'; capturedAt: number | null; error?: string }
/** Bridge-only provenance: the OMP clock and membership are independent of external file observations. */
export interface OMPSource { source: CollectionResult['source']; capturedAt: number | null; providers: string[]; error?: string }
export interface CollectionResult { snapshot: UsageSnapshot | null; source: 'live' | 'cache' | 'stale' | 'unavailable' | 'partial'; error?: string; providerSources?: ProviderSource[]; ompSource?: OMPSource }
export interface CollectorOptions { ompBin?: string; profile?: string; cacheDir?: string; maxAgeMs?: number; timeoutMs?: number; force?: boolean; now?: number }
