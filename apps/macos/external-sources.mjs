import { constants } from 'node:fs'
import { open } from 'node:fs/promises'
import { validUsageSnapshot } from '../../packages/usage-core/collector.mjs'

/** @typedef {import('../../packages/usage-core/types.js').UsageSnapshot} UsageSnapshot */
/** @typedef {import('../../packages/usage-core/types.js').CollectionResult} CollectionResult */
/** @typedef {import('../../packages/usage-core/types.js').ProviderSource} ProviderSource */
/** @typedef {import('./types.js').ExternalSource} ExternalSource */
const errorCodes = new Set(['CLI_NOT_FOUND', 'AUTH_REQUIRED', 'COLLECT_FAILED', 'INVALID_OUTPUT', 'NO_QUOTA', 'UNSAFE_CONFIG'])
const MAX_BYTES = 1024 * 1024
/** @param {unknown} value @returns {value is Record<string, unknown>} */
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value)

/** @param {ExternalSource} config @returns {Promise<{snapshot: UsageSnapshot|null, error?: string}>} */
async function readSnapshot(config) {
  let file
  try {
    // Only regular files: never execute a configured path or block on a FIFO/device.
    file = await open(config.path, constants.O_RDONLY | constants.O_NONBLOCK | constants.O_NOFOLLOW)
    const stat = await file.stat()
    if (!stat.isFile() || stat.size > MAX_BYTES) return { snapshot: null, error: 'External snapshot unavailable' }
    const envelope = /** @type {unknown} */ (JSON.parse(await file.readFile('utf8')))
    if (!object(envelope) || Object.keys(envelope).some(key => !['version', 'providerId', 'snapshot', 'errorCode'].includes(key)) ||
        envelope.version !== 1 || envelope.providerId !== config.providerId ||
        (envelope.errorCode !== undefined && (typeof envelope.errorCode !== 'string' || !errorCodes.has(envelope.errorCode))) ||
        !(envelope.snapshot === null || validUsageSnapshot(envelope.snapshot))) return { snapshot: null, error: 'INVALID_OUTPUT' }
    const snapshot = envelope.snapshot
    if (snapshot && (!snapshot.accounts.every(account => account.provider === config.providerId) ||
        !snapshot.unavailable.every(report => report.provider === config.providerId))) return { snapshot: null, error: 'INVALID_OUTPUT' }
    return { snapshot, ...(typeof envelope.errorCode === 'string' ? { error: envelope.errorCode } : {}) }
  } catch { return { snapshot: null, error: 'External snapshot unavailable' } }
  finally { await file?.close().catch(() => {}) }
}

/**
 * Configured providers belong to their external file even when that file fails. Freshness is never
 * inferred from file mtime or the merge time; each provider retains its own capture and account times.
 * @param {CollectionResult} omp
 * @param {ExternalSource[]} configs
 * @param {{maxAgeMs: number, now?: number}} options
 * @returns {Promise<CollectionResult>}
 */
export async function mergeExternalSources(omp, configs, { maxAgeMs, now = Date.now() }) {
  if (configs.length === 0) return omp
  const owned = new Set(configs.map(config => config.providerId))
  const accounts = (omp.snapshot?.accounts ?? []).filter(account => !owned.has(account.provider))
  const unavailable = (omp.snapshot?.unavailable ?? []).filter(report => !owned.has(report.provider))
  const ompProviders = new Set([...accounts.map(account => account.provider), ...unavailable.map(report => report.provider)])
  /** @type {ProviderSource[]} */
  const providerSources = [...ompProviders].map(provider => ({ provider, source: omp.source === 'partial' ? 'stale' : omp.source,
    capturedAt: omp.snapshot?.capturedAt ?? null, ...(omp.error ? { error: omp.error } : {}) }))
  const captures = omp.snapshot ? [omp.snapshot.capturedAt] : []
  let hasSnapshot = omp.snapshot !== null
  let healthy = (omp.source === 'live' || omp.source === 'cache') && !omp.error
  let failed = !healthy
  const results = await Promise.all(configs.map(readSnapshot))
  for (const [index, result] of results.entries()) {
    const provider = configs[index].providerId, snapshot = result.snapshot
    let error = result.error
    /** @type {ProviderSource['source']} */ let source = 'unavailable'
    if (snapshot) {
      // Accounts without displayable quota are metadata, not a healthy quota observation.
      const hasQuota = snapshot.accounts.some(account => account.limits.some(limit =>
        (limit.usedFraction !== undefined && limit.usedFraction >= 0 && Number.isFinite(limit.usedFraction * 100)) ||
        limit.status === 'exhausted'))
      if (hasQuota) { hasSnapshot = true; captures.push(snapshot.capturedAt) }
      accounts.push(...snapshot.accounts)
      unavailable.push(...snapshot.unavailable)
      const fresh = [snapshot.capturedAt, ...snapshot.accounts.map(account => account.fetchedAt)]
        .every(timestamp => timestamp >= 0 && timestamp <= now && now - timestamp < maxAgeMs)
      if (!hasQuota || snapshot.unavailable.length) error ??= 'NO_QUOTA'
      if (!fresh) error ??= 'External snapshot expired'
      source = error ? (hasQuota ? 'stale' : 'unavailable') : 'cache'
    } else { error ??= 'External snapshot unavailable' }
    if (source === 'cache') healthy = true
    else failed = true
    if (!snapshot || (!snapshot.accounts.length && !snapshot.unavailable.length)) {
      unavailable.push({ provider, label: provider, reason: error ?? 'External snapshot unavailable' })
    }
    providerSources.push({ provider, source, capturedAt: snapshot?.capturedAt ?? null, ...(error ? { error } : {}) })
  }
  const source = failed ? (healthy ? 'partial' : hasSnapshot ? 'stale' : 'unavailable') : omp.source
  // No usable captures means no snapshot, so the native last-good guard remains authoritative.
  // The oldest actual included capture is only a conservative aggregate, never an OMP clock.
  const snapshot = captures.length ? { version: /** @type {const} */ (1), capturedAt: Math.min(...captures), accounts, unavailable } : null
  return { snapshot, source, providerSources,
    ompSource: { source: omp.source, capturedAt: omp.snapshot?.capturedAt ?? null, providers: [...ompProviders], ...(omp.error ? { error: omp.error } : {}) },
    ...(failed ? { error: [omp.error, ...(providerSources.some(item => owned.has(item.provider) && item.error) ? ['External usage data is stale or unavailable'] : [])].filter(Boolean).join('; ') || 'Usage data is unavailable' } : {}) }
}
