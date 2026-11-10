import path from 'node:path'

/** @typedef {import('./types.js').PanelConfig} PanelConfig */
/** @param {unknown} value @returns {value is Record<string,unknown>} */
function object(value) { return value !== null && typeof value === 'object' && !Array.isArray(value) }
/** @param {unknown} value */
function nonempty(value) { return typeof value === 'string' && value.trim().length > 0 }
/** @param {unknown} value @returns {value is Record<string,string>} */
function stringMap(value) { return object(value) && Object.entries(value).every(([key, entry]) => nonempty(key) && nonempty(entry)) }
/** @param {{nodePath:string,ompPath:string,profile?:string}} options @returns {PanelConfig} */
export function defaultConfig({ nodePath, ompPath, profile = 'default' }) {
  return parseConfig({ version: 1, nodePath, ompPath, profile, refreshSeconds: 60, cacheMinutes: 5, timeoutSeconds: 25, providers: null, labels: {}, metrics: {}, warnPercent: 70, criticalPercent: 90, showPace: true })
}
/** @param {unknown} value @returns {PanelConfig} */
export function parseConfig(value) {
  if (!object(value)) throw new Error('Invalid panel configuration')
  const keys = ['version', 'nodePath', 'ompPath', 'profile', 'refreshSeconds', 'cacheMinutes', 'timeoutSeconds', 'providers', 'labels', 'metrics', 'warnPercent', 'criticalPercent', 'showPace']
  if (Object.keys(value).some(key => !keys.includes(key)) || value.version !== 1 ||
      !nonempty(value.nodePath) || typeof value.nodePath !== 'string' || !path.isAbsolute(value.nodePath) ||
      !nonempty(value.ompPath) || typeof value.ompPath !== 'string' || !path.isAbsolute(value.ompPath) || !nonempty(value.profile) ||
      typeof value.refreshSeconds !== 'number' || !Number.isFinite(value.refreshSeconds) || value.refreshSeconds <= 0 ||
      typeof value.cacheMinutes !== 'number' || !Number.isFinite(value.cacheMinutes) || value.cacheMinutes < 0 ||
      typeof value.timeoutSeconds !== 'number' || !Number.isFinite(value.timeoutSeconds) || value.timeoutSeconds <= 0 ||
      !(value.providers === null || Array.isArray(value.providers) && value.providers.every(nonempty) && new Set(value.providers).size === value.providers.length) ||
      !stringMap(value.labels) || !stringMap(value.metrics) ||
      typeof value.warnPercent !== 'number' || !Number.isFinite(value.warnPercent) || value.warnPercent < 0 ||
      typeof value.criticalPercent !== 'number' || !Number.isFinite(value.criticalPercent) || value.criticalPercent < value.warnPercent ||
      typeof value.showPace !== 'boolean') throw new Error('Invalid panel configuration')
  if (!Number.isFinite(value.cacheMinutes * 60000) || !Number.isFinite(value.timeoutSeconds * 1000) || !Number.isFinite(value.refreshSeconds * 1000)) throw new Error('Invalid panel configuration')
  // Every required field and its value has been validated above.
  return /** @type {PanelConfig} */ (/** @type {unknown} */ (value))
}
/** @param {Record<string,unknown>} variables @param {PanelConfig} baseConfig @returns {PanelConfig} */
export function migrateSwiftbarVariables(variables, baseConfig) {
  const config = { ...parseConfig(baseConfig) }
  /** @param {string} key @returns {string|undefined} */
  function text(key) {
    const value = variables[key]
    if (value === undefined || value === null) return undefined
    if (typeof value !== 'string') throw new Error(`Invalid ${key}`)
    return value
  }
  /** @param {string} key */
  function number(key) {
    const value = text(key)
    if (value === undefined) return undefined
    if (!value.trim() || !Number.isFinite(Number(value))) throw new Error(`Invalid ${key}`)
    return Number(value)
  }
  /** @param {string} key */
  function map(key) {
    const value = text(key)
    if (value === undefined) return undefined
    /** @type {unknown} */ let parsed
    try { parsed = JSON.parse(value) } catch { throw new Error(`Invalid ${key}`) }
    if (!stringMap(parsed)) throw new Error(`Invalid ${key}`)
    return parsed
  }
  const omp = text('OMP_BIN'), profile = text('OMP_PROFILE'), providers = text('OMP_USAGE_PROVIDERS')
  if (omp !== undefined && omp.trim()) config.ompPath = omp
  if (profile !== undefined) config.profile = profile.trim() || 'default'
  if (providers !== undefined) {
    if (!providers.trim()) config.providers = null
    else {
      const parts = providers.split(',').map(part => part.trim())
      if (parts.some(part => !part)) throw new Error('Invalid OMP_USAGE_PROVIDERS')
      config.providers = [...new Set(parts)]
    }
  }
  const labels = map('OMP_USAGE_LABELS'), metrics = map('OMP_USAGE_METRICS')
  if (labels !== undefined) config.labels = labels
  if (metrics !== undefined) config.metrics = metrics
  const cache = number('OMP_USAGE_REFRESH_MINUTES'), warn = number('OMP_USAGE_WARN_PERCENT'), critical = number('OMP_USAGE_CRITICAL_PERCENT')
  if (cache !== undefined) config.cacheMinutes = cache
  if (warn !== undefined) config.warnPercent = warn
  if (critical !== undefined) config.criticalPercent = critical
  const pace = text('OMP_USAGE_SHOW_PACE')
  if (pace !== undefined) {
    if (!['true', 'false'].includes(pace.toLowerCase())) throw new Error('Invalid OMP_USAGE_SHOW_PACE')
    config.showPace = pace.toLowerCase() === 'true'
  }
  return parseConfig(config)
}
