import { constants } from 'node:fs';
import { access, chmod, lstat, mkdir, open, readFile, realpath, rename, unlink } from 'node:fs/promises';
import { createHash, randomBytes } from 'node:crypto';
import { execFile } from 'node:child_process';
import { homedir, platform } from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { normalizeUsage } from './normalize.mjs';

/** @typedef {import('./types.js').CollectorOptions} CollectorOptions */
/** @typedef {import('./types.js').CollectionResult} CollectionResult */
/** @typedef {import('./types.js').UsageSnapshot} UsageSnapshot */
const run = promisify(execFile);
/** @param {NodeJS.ProcessEnv} [env] @returns {CollectorOptions} */
export function collectorOptionsFromEnv(env = process.env) {
  return { ...(env.OMP_BIN ? { ompBin: env.OMP_BIN } : {}), ...(env.OMP_PROFILE !== undefined ? { profile: env.OMP_PROFILE } : env.PI_PROFILE !== undefined ? { profile: env.PI_PROFILE } : {}),
    ...(env.OMP_USAGE_CACHE_DIR ? { cacheDir: env.OMP_USAGE_CACHE_DIR } : {}) };
}
/** @param {string} candidate */
async function executable(candidate) {
  try { await access(candidate, constants.X_OK); return true; } catch { return false; }
}
/** @param {string} p */
function sourceBin(p) { return p.split(/[\\/]+/).includes('node_modules'); }
/** @param {string | undefined} override */
async function resolveBin(override) {
  if (override) return path.resolve(override);
  const local = path.join(homedir(), '.local', 'bin', 'omp');
  if (await executable(local) && !sourceBin(await realpath(local).catch(() => local))) return local;
  for (const dir of (process.env.PATH ?? '').split(path.delimiter)) {
    if (!dir || sourceBin(dir)) continue;
    const candidate = path.resolve(dir, 'omp');
    if (await executable(candidate)) {
      const target = await realpath(candidate).catch(() => candidate);
      if (!sourceBin(target)) return candidate;
    }
  }
  return local;
}
/** @param {unknown} x @returns {x is Record<string, unknown>} */
const object = x => x !== null && typeof x === 'object' && !Array.isArray(x);
/** @param {unknown} x */
const finite = x => typeof x === 'number' && Number.isFinite(x);
/** @param {unknown} x */
const stringArray = x => Array.isArray(x) && x.every(v => typeof v === 'string');
/** @param {unknown} x */
const optionalNumber = x => x === undefined || finite(x);
/** @param {unknown} x */
const optionalString = x => x === undefined || typeof x === 'string';
/** @param {unknown} value @returns {value is UsageSnapshot} */
export function validUsageSnapshot(value) {
  if (!object(value) || value.version !== 1 || !finite(value.capturedAt) || !Array.isArray(value.accounts) || !Array.isArray(value.unavailable)) return false;
  return value.unavailable.every(u => object(u) && typeof u.provider === 'string' && typeof u.label === 'string' && typeof u.reason === 'string') && value.accounts.every(a => {
    if (!object(a) || typeof a.id !== 'string' || typeof a.provider !== 'string' || typeof a.label !== 'string' || !finite(a.fetchedAt) || !optionalString(a.plan) || !stringArray(a.notes) || !Array.isArray(a.limits)) return false;
    return a.limits.every(l => {
      if (!object(l) || typeof l.id !== 'string' || typeof l.label !== 'string' || !object(l.amount) || typeof l.amount.unit !== 'string' || !optionalNumber(l.amount.used) || !optionalNumber(l.amount.limit) || !optionalNumber(l.amount.remaining) || !optionalNumber(l.usedFraction) || !optionalString(l.status) || !stringArray(l.notes)) return false;
      return l.window === undefined || (object(l.window) && typeof l.window.id === 'string' && typeof l.window.label === 'string' && optionalNumber(l.window.durationMs) && optionalNumber(l.window.resetsAt) && optionalString(l.window.resetLabel) && (l.window.estimated === undefined || typeof l.window.estimated === 'boolean'));
    });
  });
}
/** @param {CollectorOptions} [options] @returns {Promise<CollectionResult>} */
export async function collectUsage(options = {}) {
  const now = options.now ?? Date.now(), maxAge = options.maxAgeMs ?? 300000, timeout = options.timeoutMs ?? 25000;
  const bin = await resolveBin(options.ompBin), profile = (options.profile ?? process.env.OMP_PROFILE ?? process.env.PI_PROFILE)?.trim() || 'default';
  const roots = [process.env.HOME, process.env.PI_CONFIG_DIR, process.env.PI_CODING_AGENT_DIR, process.env.XDG_DATA_HOME, process.env.XDG_STATE_HOME, process.env.XDG_CONFIG_HOME];
  const identity = createHash('sha256').update(JSON.stringify([bin, profile, roots])).digest('hex');
  const cacheDir = options.cacheDir ?? (platform() === 'darwin' ? path.join(homedir(), 'Library', 'Caches', 'omp-usage') : path.join(process.env.XDG_CACHE_HOME || path.join(homedir(), '.cache'), 'omp-usage'));
  const cacheFile = path.join(cacheDir, `${identity}.json`);
  /** @type {UsageSnapshot | null} */ let previous = null;
  try {
    const stat = await lstat(cacheFile);
    if (stat.isFile() && !stat.isSymbolicLink()) {
      const data = /** @type {unknown} */ (JSON.parse(await readFile(cacheFile, 'utf8')));
      if (object(data) && data.version === 1 && data.identity === identity && validUsageSnapshot(data.snapshot)) previous = data.snapshot;
    }
  } catch { /* Missing or corrupt cache is a miss. */ }
  if (!options.force && previous && now >= previous.capturedAt && now - previous.capturedAt < maxAge) return { snapshot: previous, source: 'cache' };
  /** @type {NodeJS.ProcessEnv} */
  const env = { ...process.env, OMP_PROFILE: profile };
  delete env.PI_PROFILE;
  const deadline = performance.now() + timeout;
  /** @returns {number} */
  const remainingTimeout = () => {
    const remaining = Math.floor(deadline - performance.now());
    if (!Number.isFinite(remaining) || remaining <= 0) throw new Error('Usage refresh timed out');
    return remaining;
  };
  try {
    if (!options.ompBin && sourceBin(await realpath(bin).catch(() => bin))) throw new Error('No installed omp executable');
    if (options.force) await run(bin, ['usage', 'invalidate'], { env, timeout: remainingTimeout(), killSignal: 'SIGKILL', maxBuffer: 4 * 1024 * 1024 });
    const { stdout } = await run(bin, ['usage', '--json'], { env, timeout: remainingTimeout(), killSignal: 'SIGKILL', maxBuffer: 4 * 1024 * 1024 });
    const snapshot = normalizeUsage(JSON.parse(stdout), now);
    try {
      await mkdir(cacheDir, { recursive: true, mode: 0o700 });
      const dirStat = await lstat(cacheDir);
      if (!dirStat.isDirectory() || dirStat.isSymbolicLink()) throw new Error('Invalid cache directory');
      await chmod(cacheDir, 0o700);
      const temporary = path.join(cacheDir, `.${identity}.${randomBytes(12).toString('hex')}.tmp`);
      try {
        const file = await open(temporary, 'wx', 0o600);
        try { await file.writeFile(JSON.stringify({ version: 1, identity, snapshot })); } finally { await file.close(); }
        await rename(temporary, cacheFile);
      } finally { await unlink(temporary).catch(() => {}); }
    } catch { /* A cache write failure must not hide a successful live result. */ }
    return { snapshot, source: 'live' };
  } catch {
    return previous ? { snapshot: previous, source: 'stale', error: 'Usage refresh failed' } : { snapshot: null, source: 'unavailable', error: 'Usage refresh failed' };
  }
}
