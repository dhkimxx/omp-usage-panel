/** @typedef {import('./types.js').CollectionResult} CollectionResult */
/** @typedef {import('./types.js').UsageAccount} UsageAccount */
/** @typedef {import('./types.js').UsageLimit} UsageLimit */
/** @typedef {{providers:string[]|null,labels:Record<string,string>,metrics:Record<string,string>,warnPercent:number,criticalPercent:number}} SummarySettings */
/** @typedef {{provider:string,label:string,percent:number|null,value:string,severity:'normal'|'warning'|'critical'|'unknown',accountCount:number,accountId:string|null,accountLabel:string|null,metricId:string|null,metricLabel:string|null,windowLabel:string|null,notes:string[]}} ProviderSummary */

const order = ['openai-codex', 'opencode-go', 'minimax-code-cn', 'commandcode', 'mistral']
/** @type {Record<string,string>} */
const aliases = { 'openai-codex': 'Codex', 'opencode-go': 'Go', 'minimax-code-cn': 'MiniMax CN', commandcode: 'Cmd', mistral: 'Mistral' }
/** @param {string} value */
function clean(value) { return value.replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, ' ').replace(/\s+/g, ' ').trim() }
/** @param {number} percent @param {{warnPercent?:number,criticalPercent?:number}} [thresholds] */
export function formatPercent(percent, thresholds = {}) {
  if (percent > 0 && percent < 0.1) return '<0.1%'
  const scaled = percent * 10, nearest = Math.round(scaled)
  const nearInteger = Math.abs(scaled - nearest) <= Number.EPSILON * Math.abs(scaled)
  const rounded = nearest / 10
  const crossesBoundary = [100, thresholds.warnPercent ?? 70, thresholds.criticalPercent ?? 90].some(boundary => percent < boundary && rounded >= boundary)
  const floored = percent >= 1e15 ? percent : (nearInteger ? (crossesBoundary ? Math.ceil(scaled) - 1 : nearest) : Math.floor(scaled)) / 10
  return `${floored}%`
}
/** @typedef {{account:UsageAccount,limit:UsageLimit,percent:number|null}} Candidate */
/** @param {Candidate} a @param {Candidate} b */
function compareIdentity(a, b) { return a.limit.id < b.limit.id ? -1 : a.limit.id > b.limit.id ? 1 : a.account.id < b.account.id ? -1 : a.account.id > b.account.id ? 1 : 0 }
/** @param {CollectionResult} result @param {SummarySettings} settings @returns {ProviderSummary[]} */
export function summarizeProviders(result, settings) {
  const accounts = result.snapshot?.accounts ?? [], unavailable = result.snapshot?.unavailable ?? []
  const ids = new Set([...accounts.map(account => account.provider), ...unavailable.map(item => item.provider)])
  const providers = settings.providers ?? [...order.filter(id => ids.delete(id)), ...[...ids].sort()]
  return providers.map(provider => {
    const matching = accounts.filter(account => account.provider === provider)
    let metricFound = false
    const metric = Object.hasOwn(settings.metrics, provider) ? settings.metrics[provider] : undefined
    /** @type {Candidate[]} */ const numeric = []
    /** @type {Candidate[]} */ const exhausted = []
    for (const account of matching) for (const limit of account.limits) {
      if (metric !== undefined && limit.id !== metric) continue
      metricFound = true
      const fraction = limit.usedFraction
      const percent = fraction !== undefined && Number.isFinite(fraction) && fraction >= 0 ? fraction * 100 : null
      const candidate = { account, limit, percent: percent !== null && Number.isFinite(percent) ? percent : null }
      if (candidate.percent !== null) numeric.push(candidate)
      else if (limit.status === 'exhausted') exhausted.push(candidate)
    }
    numeric.sort((a, b) => /** @type {number} */ (b.percent) - /** @type {number} */ (a.percent) || compareIdentity(a, b))
    exhausted.sort(compareIdentity)
    const selected = numeric[0] ?? exhausted[0], percent = selected?.percent ?? null
    /** @type {ProviderSummary['severity']} */
    const severity = selected?.limit.status === 'exhausted' || percent !== null && percent >= settings.criticalPercent ? 'critical' : percent === null ? 'unknown' : percent >= settings.warnPercent ? 'warning' : 'normal'
    const label = Object.hasOwn(settings.labels, provider) ? settings.labels[provider] : Object.hasOwn(aliases, provider) ? aliases[provider] : provider
    return { provider, label: clean(label), percent, value: percent === null ? '—' : formatPercent(percent, settings), severity,
      accountCount: matching.length, accountId: selected?.account.id ?? null, accountLabel: selected ? clean(selected.account.label) : null,
      metricId: selected?.limit.id ?? null, metricLabel: selected ? clean(selected.limit.label) : null, windowLabel: selected?.limit.window ? clean(selected.limit.window.label) : null,
      notes: [...(metric !== undefined && !metricFound ? ['Configured metric not found'] : []), ...(unavailable.some(item => item.provider === provider) ? ['Some usage data is unavailable'] : [])] }
  })
}
