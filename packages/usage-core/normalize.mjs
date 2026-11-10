/** @typedef {import('./types.js').UsageSnapshot} UsageSnapshot */
/** @typedef {import('./types.js').UsageLimit} UsageLimit */
/** @param {unknown} x @returns {Record<string, unknown>} */
const obj = x => x !== null && typeof x === 'object' && !Array.isArray(x) ? /** @type {Record<string, unknown>} */ (x) : {};
/** @param {unknown} x @returns {string | undefined} */
const text = x => typeof x === 'string' && x.trim() ? x : undefined;
/** @param {unknown} x @returns {number | undefined} */
const num = x => typeof x === 'number' && Number.isFinite(x) ? x : undefined;
/** @param {unknown} x @returns {number | undefined} */
const nonnegative = x => { const n = num(x); return n !== undefined && n >= 0 ? n : undefined; };
/** @param {unknown} x @returns {string[]} */
const notes = x => Array.isArray(x) ? x.filter((/** @type {unknown} */ v) => typeof v === 'string') : [];
/** @param {number} resetsAt @returns {number | undefined} */
function estimatedMonthDuration(resetsAt) {
  const end = new Date(resetsAt);
  if (!Number.isFinite(end.getTime())) return undefined;
  const start = new Date(end);
  const day = start.getUTCDate();
  start.setUTCDate(1);
  start.setUTCMonth(start.getUTCMonth() - 1);
  const month = start.getUTCMonth(), year = start.getUTCFullYear();
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month];
  start.setUTCDate(Math.min(day, days));
  const duration = resetsAt - start.getTime();
  return Number.isFinite(duration) && duration > 0 ? duration : undefined;
}
/** @param {unknown} payload @param {number} [capturedAt] @returns {UsageSnapshot} */
export function normalizeUsage(payload, capturedAt = Date.now()) {
  const root = obj(payload);
  if (!Array.isArray(root.reports)) throw new Error('Invalid usage response');
  /** @type {UsageSnapshot} */
  const snapshot = { version: 1, capturedAt, accounts: [], unavailable: [] };
  for (const [index, raw] of root.reports.entries()) {
    const report = obj(raw), metadata = obj(report.metadata);
    const provider = text(report.provider);
    if (!provider || !Array.isArray(report.limits)) throw new Error('Invalid usage report');
    const firstScope = obj(obj(report.limits[0]).scope);
    const identity = text(metadata.accountId) ?? text(firstScope.accountId) ?? text(metadata.email) ?? text(metadata.orgId) ?? text(firstScope.orgId) ?? String(index + 1);
    const org = text(metadata.orgId) ?? text(firstScope.orgId);
    const fetchedAt = num(report.fetchedAt);
    if (fetchedAt === undefined) throw new Error('Invalid usage report timestamp');
    const plan = text(metadata.planType);
    const account = { id: `${provider}:${identity}${org && org !== identity ? `:${org}` : ''}:${index + 1}`, provider,
      label: text(metadata.email) ?? text(metadata.accountName) ?? text(metadata.orgName) ?? `Account ${index + 1}`,
      fetchedAt, ...(plan ? { plan } : {}),
      notes: notes(report.notes), limits: /** @type {UsageLimit[]} */ ([]) };
    const groups = new Set(/** @type {string[]} */ ([]));
    for (const item of report.limits) {
      const limit = obj(item), scope = obj(limit.scope), amount = obj(limit.amount), id = text(limit.id);
      if (!id || !text(limit.label) || !text(amount.unit) || !limit.amount || typeof limit.amount !== 'object' || Array.isArray(limit.amount)) throw new Error('Invalid usage limit');
      const group = text(scope.sharedGroup);
      if (group && groups.has(group)) continue;
      if (group) groups.add(group);
      const monthly = id === 'commandcode:monthly' ? obj(metadata.monthly) : {};
      const used = num(monthly.used) ?? num(amount.used);
      const usedForFraction = nonnegative(used);
      const cap = nonnegative(monthly.limit) ?? nonnegative(amount.limit);
      const remaining = num(monthly.remaining) ?? num(amount.remaining);
      const unit = text(amount.unit) ?? 'unknown';
      const explicit = nonnegative(monthly.usedFraction) ?? nonnegative(amount.usedFraction);
      const remainingFraction = nonnegative(amount.remainingFraction);
      const fraction = explicit ?? (usedForFraction !== undefined && cap !== undefined && cap > 0 ? usedForFraction / cap : undefined)
        ?? (unit.toLowerCase() === 'percent' && usedForFraction !== undefined ? usedForFraction / 100 : undefined)
        ?? (remainingFraction !== undefined && remainingFraction <= 1 ? 1 - remainingFraction : undefined);
      const w = obj(limit.window), windowId = text(w.id);
      const resets = num(w.resetsAt), resetLabel = text(w.resetLabel), status = text(limit.status);
      const reportedDuration = nonnegative(w.durationMs);
      const estimatedDuration = provider === 'mistral' && windowId === 'monthly' && !(reportedDuration !== undefined && reportedDuration > 0) && resets !== undefined
        ? estimatedMonthDuration(resets) : undefined;
      const duration = estimatedDuration ?? reportedDuration;
      const limitNotes = notes(limit.notes);
      if (estimatedDuration !== undefined) limitNotes.push('Period estimated as one UTC calendar month ending at reset; the API does not report its start.');
      account.limits.push({ id, label: text(limit.label) ?? id, amount: { unit,
        ...(used !== undefined ? { used } : {}), ...(cap !== undefined ? { limit: cap } : {}), ...(remaining !== undefined ? { remaining } : {}) },
        ...(windowId ? { window: { id: windowId, label: text(w.label) ?? windowId,
          ...(duration !== undefined && duration > 0 ? { durationMs: duration } : {}), ...(resets !== undefined ? { resetsAt: resets } : {}), ...(resetLabel ? { resetLabel } : {}),
          ...(estimatedDuration !== undefined ? { estimated: true } : {}) } } : {}),
        ...(fraction !== undefined && Number.isFinite(fraction) ? { usedFraction: fraction } : {}), ...(status ? { status } : {}), notes: limitNotes });
    }
    if (Array.isArray(metadata.unavailableModels)) {
      for (const model of metadata.unavailableModels) {
        const label = text(model);
        if (label) snapshot.unavailable.push({ provider, label: `${account.label}: ${label}`, reason: 'Usage unavailable' });
      }
    }
    snapshot.accounts.push(account);
  }
  for (const [key, reason] of /** @type {const} */ ([['accountsWithoutUsage', 'Usage unavailable'], ['disabledCredentials', 'Credential disabled']])) {
    const entries = root[key];
    if (!Array.isArray(entries)) continue;
    for (const entry of entries) {
      const item = obj(entry), provider = text(item.provider);
      if (provider) snapshot.unavailable.push({ provider, label: text(item.email) ?? text(item.label) ?? text(item.accountId) ?? provider, reason });
    }
  }
  return snapshot;
}
