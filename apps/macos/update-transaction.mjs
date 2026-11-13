import { spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { copyFileSync, cpSync, lstatSync, mkdirSync, readFileSync, renameSync, rmSync, statSync } from 'node:fs'
import path from 'node:path'
import { parseConfig } from './config.mjs'
import { agentProgramArguments, appTreeHash, atomic, canonical, context, digest, ensurePrivateDirectory, inspectInstaller, installerLabel, loadManifest, loadedJob, preserveLegacyState, present, safeTreeHash, sameEntries, removeIdleInstallerJobs, sameProcess, scanTree, startJob, stopJob, syncDirectory, syncTree, withLock } from './ownership.mjs'

/** @typedef {import('./ownership.mjs').Context} Context */
/** @typedef {import('./ownership.mjs').InstallState} InstallState */
/** @typedef {import('./ownership.mjs').TreeEntry} TreeEntry */
/** @typedef {import('./ownership.mjs').OwnershipOptions & {readinessMs?:number, pollMs?:number, lockWaitMs?:number, replacementGraceMs?:number, armWaitMs?:number, spawnWatcher?:(command:string, args:string[])=>void}} UpdateOptions */
/** @typedef {UpdateOptions & {expectedVersion:string, expectedAppTreeSHA256:string, currentVersion:string, ownerPid:number}} PrepareOptions */
/** @typedef {{schema:1, id:string, phase:'prepared'|'relaunching'|'rolling-back', createdAt:number, fromVersion:string, toVersion:string, oldHash:string, expectedHash:string, appPath:string, agentPath:string, configPath:string, stateDir:string, agentHash:string, node:string, jobLoaded:boolean, hostPid:number, hostStart:string|null, restart:boolean, revoked:boolean, watcherPid:number|null, watcherStart:string|null, armToken:string|null, workerPid:number|null, workerStart:string|null, acknowledged:boolean, deadline:number|null, error:string|null}} Receipt */
/** @typedef {{transactionId:string, status:'updated'|'rolled-back'|'failed', fromVersion:string, toVersion:string, at:string, message:string}} Outcome */
/** @typedef {{transactionId:string, phase:Receipt['phase'], fromVersion:string, toVersion:string, armed:boolean, ownerAlive:boolean}} PendingInfo */
/** @typedef {{managed:boolean, reason?:string, recovery?:string, pending:PendingInfo|null, outcome:Outcome|null}} UpdateStatus */
/** @typedef {'none'|'finished'|'rolled-back'|'rollback-failed'|'authorized'|'awaiting'|'unexpected'|'busy'} Settled */

/** Modules the copied watcher needs; they are copied out of the verified bundle before any replacement. */
export const trustedRuntimeFiles = ['config.mjs', 'ownership.mjs', 'update-transaction.mjs', 'update-ownership.mjs']
const runtimeDirectory = 'Contents/Resources/runtime/apps/macos'
const recoveryHint = 'Resolve the problem, then run the OMP Usage updater recovery (update-ownership.mjs recover).'
const setupRecovery = 'Open OMP Usage from the downloaded disk image to run its one-time setup.'
const modifiedRecovery = 'Restore the original file, or move the modified one aside yourself, then open OMP Usage from the downloaded disk image to run its setup again. Setup never overwrites files it does not recognize.'
const liveUpdateMessage = 'A prebuilt update is authorized or in progress and may still replace the app; wait for it, or cancel it from the running app, before installing or uninstalling'
const hex64 = /^[a-f0-9]{64}$/
const versionPattern = /^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$/

export class UpdateError extends Error {
  /** @param {string} code @param {string} message @param {string} [recovery] */
  constructor(code, message, recovery) { super(message); this.name = 'UpdateError'; this.code = code; this.recovery = recovery }
}
/** @param {unknown} error */
function describe(error) { return error instanceof Error ? error.message : String(error) }
/** Detached watcher start. spawn() forks synchronously; the watcher reports for itself by registering in the receipt.
 * @param {string} command @param {string[]} args */
function defaultSpawnWatcher(command, args) {
  const child = spawn(command, args, { detached: true, stdio: 'ignore', cwd: '/' })
  child.on('error', () => { /* A watcher that cannot start never registers, which prepare reports as arm-failed. */ })
  child.unref()
}
/** @param {UpdateOptions} options */
function updateContext(options) {
  return { ...context(options), readinessMs: options.readinessMs ?? 45_000, pollMs: options.pollMs ?? 250, lockWaitMs: options.lockWaitMs ?? 10_000, graceMs: options.replacementGraceMs ?? 120_000, armWaitMs: options.armWaitMs ?? 10_000, spawnWatcher: options.spawnWatcher ?? defaultSpawnWatcher }
}
/** @param {{stateDir:string}} c */
function areas(c) {
  const updater = path.join(c.stateDir, 'updater'), transaction = path.join(updater, 'transaction'), backup = path.join(transaction, 'backup'), watcher = path.join(updater, 'watcher')
  return { updater, transaction, receipt: path.join(transaction, 'receipt.json'), backup, backupApp: path.join(backup, 'app'), backupManifest: path.join(backup, 'install.json'), watcher, watcherScript: path.join(watcher, 'runtime/apps/macos/update-ownership.mjs'), outcome: path.join(updater, 'outcome.json'), manifest: path.join(c.stateDir, 'install.json') }
}
/** Create or verify the private updater area and make its directory entry durable. @param {Context} c */
function ensureUpdater(c) {
  const a = areas(c)
  try {
    if (statSync(c.stateDir).uid !== c.owner) throw new Error(`State directory is owned by another user: ${c.stateDir}`)
    ensurePrivateDirectory(a.updater, c.owner)
    syncDirectory(c.stateDir)
  } catch (error) { throw new UpdateError('ownership-mismatch', describe(error)) }
  return a
}
/** @param {Context} c */
function readManifest(c) {
  try { return loadManifest(areas(c).manifest) } catch (error) { throw new UpdateError('not-managed', `The installation record is unreadable: ${describe(error)}`) }
}

/** @param {unknown} value @returns {Receipt} */
function parseReceipt(value) {
  const invalid = () => new UpdateError('invalid-transaction', 'The pending update receipt is invalid')
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw invalid()
  const r = /** @type {Record<string,unknown>} */ (value)
  const text = (/** @type {unknown} */ v) => typeof v === 'string' && v.length > 0
  const absolute = (/** @type {unknown} */ v) => typeof v === 'string' && path.isAbsolute(v)
  const version = (/** @type {unknown} */ v) => typeof v === 'string' && versionPattern.test(v)
  const hash = (/** @type {unknown} */ v) => typeof v === 'string' && hex64.test(v)
  if (r.schema !== 1 || !text(r.id) || !/^[0-9a-f-]{36}$/.test(String(r.id)) || !['prepared', 'relaunching', 'rolling-back'].includes(String(r.phase)) || typeof r.createdAt !== 'number' ||
      !version(r.fromVersion) || !version(r.toVersion) || !hash(r.oldHash) || !hash(r.expectedHash) || !hash(r.agentHash) ||
      !absolute(r.appPath) || !absolute(r.agentPath) || !absolute(r.configPath) || !absolute(r.stateDir) || !absolute(r.node) || typeof r.jobLoaded !== 'boolean' || typeof r.restart !== 'boolean' || typeof r.revoked !== 'boolean' || typeof r.acknowledged !== 'boolean' ||
      !Number.isInteger(r.hostPid) || Number(r.hostPid) <= 1 || !(r.hostStart === null || text(r.hostStart)) || !(r.watcherStart === null || text(r.watcherStart)) || !(r.workerStart === null || text(r.workerStart)) ||
      !(r.watcherPid === null || Number.isInteger(r.watcherPid)) || !(r.armToken === null || text(r.armToken)) ||
      !(r.workerPid === null || Number.isInteger(r.workerPid)) || !(r.deadline === null || typeof r.deadline === 'number') || !(r.error === null || typeof r.error === 'string')) throw invalid()
  return /** @type {Receipt} */ (/** @type {unknown} */ (value))
}
/** @param {Context} c @returns {Receipt|'incomplete'|null} */
function readReceipt(c) {
  const a = areas(c)
  if (!present(a.updater)) return null
  const updater = lstatSync(a.updater)
  if (!updater.isDirectory() || updater.uid !== c.owner || (updater.mode & 0o077) !== 0) throw new UpdateError('invalid-transaction', `The updater directory is not private to this user: ${a.updater}`, `Verify and remove ${a.updater}, then retry.`)
  if (!present(a.transaction)) return null
  const directory = lstatSync(a.transaction), recovery = `Verify no update is running, then remove ${a.transaction} and retry.`
  if (!directory.isDirectory() || directory.uid !== c.owner) throw new UpdateError('invalid-transaction', `The pending update directory is not owned by this user: ${a.transaction}`, recovery)
  if (!present(a.receipt)) return 'incomplete'
  const file = lstatSync(a.receipt)
  if (!file.isFile() || file.uid !== c.owner) throw new UpdateError('invalid-transaction', 'The pending update receipt is not a regular file owned by this user', recovery)
  let value
  try { value = JSON.parse(readFileSync(a.receipt, 'utf8')) } catch { throw new UpdateError('invalid-transaction', 'The pending update receipt is unreadable', recovery) }
  try { return parseReceipt(value) } catch (error) { throw new UpdateError('invalid-transaction', describe(error), recovery) }
}
/** @param {Context} c @param {Receipt} receipt */
function writeReceipt(c, receipt) { atomic(areas(c).receipt, JSON.stringify(receipt, null, 2) + '\n') }
/** @param {Context} c */
function discardTransaction(c) {
  const a = areas(c)
  if (!present(a.transaction)) return
  const stat = lstatSync(a.transaction)
  if (!stat.isDirectory() || stat.uid !== c.owner) throw new UpdateError('invalid-transaction', `The pending update directory is not owned by this user: ${a.transaction}`)
  rmSync(a.transaction, { recursive: true, force: true })
  syncDirectory(a.updater)
}
/** @param {Context} c @param {Receipt} receipt @param {Outcome['status']} status @param {string} message */
function writeOutcome(c, receipt, status, message) {
  /** @type {Outcome} */
  const outcome = { transactionId: receipt.id, status, fromVersion: receipt.fromVersion, toVersion: receipt.toVersion, at: new Date(c.now()).toISOString(), message }
  atomic(areas(c).outcome, JSON.stringify(outcome, null, 2) + '\n')
}
/** @param {Context} c @returns {Outcome|null} */
function readOutcome(c) {
  const file = areas(c).outcome
  try {
    if (!present(file) || !lstatSync(file).isFile()) return null
    const value = JSON.parse(readFileSync(file, 'utf8'))
    if (!value || typeof value.transactionId !== 'string' || !['updated', 'rolled-back', 'failed'].includes(value.status) || typeof value.message !== 'string') return null
    return value
  } catch { return null }
}
/** @param {Context} c @param {Receipt} receipt @returns {PendingInfo} */
function pendingInfo(c, receipt) {
  return { transactionId: receipt.id, phase: receipt.phase, fromVersion: receipt.fromVersion, toVersion: receipt.toVersion, armed: receipt.watcherPid !== null && sameProcess(c, receipt.watcherPid, receipt.watcherStart), ownerAlive: sameProcess(c, receipt.hostPid, receipt.hostStart) }
}
/** @param {Context} c @param {Receipt} receipt */
function workerAlive(c, receipt) {
  return receipt.workerPid !== null && sameProcess(c, receipt.workerPid, receipt.workerStart) && receipt.deadline !== null && c.now() < receipt.deadline + 60_000
}
/** A watcher other than this process that is still running. @param {Context} c @param {Receipt} receipt */
function otherWatcherAlive(c, receipt) { return receipt.watcherPid !== null && receipt.watcherPid !== c.self && sameProcess(c, receipt.watcherPid, receipt.watcherStart) }
/** Fail closed and read-only: any registered Sparkle installer job (running or idle and re-launchable) or an uninspectable one may still act. @param {Context} c */
function installerMayAct(c) { try { return inspectInstaller(c).length > 0 } catch { return true } }
/** Positive proof for the watcher after the host died unreplaced: nothing running, and every idle remaining job removed and verified gone. @param {Context} c */
function installerGone(c) {
  try { const jobs = inspectInstaller(c); if (jobs.some(job => job.running)) return false; removeIdleInstallerJobs(c, jobs); return true } catch { return false }
}
/** @param {Context} c */
function currentAppHash(c) { return present(c.app) ? safeTreeHash(c.app, c.owner) : null }
/** Cheap change detector for the app directory: a replaced bundle has a different inode or timestamps. @param {Context} c */
function appSignature(c) { try { const stat = lstatSync(c.app); return `${stat.ino}:${stat.mtimeMs}:${stat.ctimeMs}` } catch { return 'absent' } }
/** @param {Context} c @param {Receipt} receipt */
function agentMatches(c, receipt) {
  return present(c.agent) && lstatSync(c.agent).isFile() && lstatSync(c.agent).uid === c.owner && digest(readFileSync(c.agent)) === receipt.agentHash
}

/** Every recorded path must be the one the caller operates on, and the installation record must agree. A mismatch has no side
 * effects: the caller's destination, the backup and all evidence stay untouched.
 * @param {Context} c @param {Receipt} receipt @param {InstallState|null} state */
function assertRecordedPaths(c, receipt, state) {
  if (receipt.appPath !== c.app || receipt.agentPath !== c.agent || receipt.configPath !== c.config || receipt.stateDir !== c.stateDir || (state && (state.appPath !== receipt.appPath || state.agentPath !== receipt.agentPath))) {
    throw new UpdateError('ownership-mismatch', 'The pending update was prepared for a different installation location; nothing was changed.')
  }
}
/** Classify a pending transaction against the installation record, the app on disk and who may still act on it. Nothing is concluded
 * about the SDK's installer from elapsed time: while its host-specific jobs may act (or cannot be inspected) the transaction stays
 * live. With `remove`, idle leftover jobs are removed and verified gone when no owner or watcher is alive, which is what proves
 * quiescence; read-only callers treat any registered job as live.
 * @param {Context} c @param {InstallState|null} state @param {Receipt} receipt @param {boolean} [remove] */
function classify(c, state, receipt, remove = false) {
  if (state?.appHash === receipt.expectedHash) return 'committed'
  if (!state || state.appHash !== receipt.oldHash) return 'stale'
  if (receipt.phase !== 'prepared') return workerAlive(c, receipt) ? 'busy' : 'abandoned'
  const hash = currentAppHash(c), watcher = otherWatcherAlive(c, receipt), hostAlive = sameProcess(c, receipt.hostPid, receipt.hostStart)
  const quiet = () => !hostAlive && !watcher && remove ? installerGone(c) : !installerMayAct(c)
  if (hash === receipt.oldHash) return hostAlive || watcher || !quiet() ? 'authorized' : 'abandoned-prepared'
  if (watcher || !quiet()) return 'busy'
  return hash === receipt.expectedHash ? 'awaiting' : 'unexpected'
}
/** Restore the verified backup of the previous app. Nothing is replaced unless the backup verifies against the ownership record.
 * Callers must already have verified that the replacement job is gone.
 * @param {Context} c @param {Receipt} receipt */
function restoreApp(c, receipt) {
  const a = areas(c)
  if (present(c.app) && safeTreeHash(c.app, c.owner) === receipt.oldHash) return
  if (scanTree(a.backupApp, { uid: c.owner }).hash !== receipt.oldHash) throw new Error('The update backup no longer matches the installation record')
  const parent = path.dirname(c.app), staged = path.join(parent, `.omp-restore-${receipt.id}`), rejected = path.join(parent, `.omp-rejected-${receipt.id}`)
  rmSync(staged, { recursive: true, force: true }); rmSync(rejected, { recursive: true, force: true })
  try {
    cpSync(a.backupApp, staged, { recursive: true, verbatimSymlinks: true, errorOnExist: true, force: false })
    if (appTreeHash(staged, { uid: c.owner }) !== receipt.oldHash) throw new Error('The restored app copy failed verification')
    syncTree(staged)
    if (present(c.app)) renameSync(c.app, rejected)
    renameSync(staged, c.app)
    syncDirectory(parent)
  } finally { rmSync(staged, { recursive: true, force: true }) }
  rmSync(rejected, { recursive: true, force: true })
}
/** @param {Context} c @param {Receipt} receipt */
function restartAgent(c, receipt) {
  if (!agentMatches(c, receipt)) throw new Error('The LaunchAgent no longer matches the installation record; it was not restarted')
  if (loadedJob(c, loadManifest(areas(c).manifest))) return
  startJob(c)
}
/** Return the previous app to service. The replacement job is stopped and verified gone, and any inspection failure aborts, before
 * any file is overwritten; a failed stop leaves the journal and both apps in place so recovery can resume. Returns whether the
 * previous version was restored.
 * @param {Context} c @param {Receipt} receipt @param {string} reason */
function rollback(c, receipt, reason) {
  const a = areas(c)
  // An explicit rollback withdraws any earlier acknowledgment so it can never be committed over the requested rollback.
  writeReceipt(c, { ...receipt, phase: 'rolling-back', acknowledged: false, workerPid: c.self, workerStart: c.processStart(c.self), deadline: c.now() + 120_000, error: reason })
  try {
    // Rollback may rewrite the app only once Sparkle's installer can no longer write it.
    if (!installerGone(c)) throw new Error('the Sparkle installer may still be running')
    if (loadedJob(c, loadManifest(a.manifest), { appRequired: false })) stopJob(c)
    restoreApp(c, receipt)
    if (!present(a.manifest)) atomic(a.manifest, readFileSync(a.backupManifest))
  } catch (error) {
    const detail = `${reason}; rollback incomplete: ${describe(error)}`
    writeReceipt(c, { ...receipt, phase: 'rolling-back', acknowledged: false, workerPid: null, workerStart: null, deadline: null, error: detail })
    writeOutcome(c, receipt, 'failed', `${detail}. ${recoveryHint}`)
    return false
  }
  let note = ''
  try { restartAgent(c, receipt) } catch (error) { note = ` The previous version was restored but not restarted: ${describe(error)}` }
  writeOutcome(c, receipt, 'rolled-back', reason + note)
  discardTransaction(c)
  return true
}
/** @param {Context} c @param {Receipt} receipt @param {string} reason */
function rolledBack(c, receipt, reason) {
  if (rollback(c, receipt, reason)) return { kind: /** @type {Settled} */ ('rolled-back'), receipt }
  const next = readReceipt(c)
  return { kind: /** @type {Settled} */ ('rollback-failed'), receipt: next && next !== 'incomplete' ? next : receipt }
}
/** @param {Context} c @param {Receipt} receipt */
function finishCommit(c, receipt) {
  if (readOutcome(c)?.transactionId !== receipt.id) writeOutcome(c, receipt, 'updated', `Updated to ${receipt.toVersion}`)
  discardTransaction(c)
}
/** Commit ownership of the new app: only called after the new app proved it started. @param {Context} c @param {Receipt} receipt @param {InstallState} state */
function commit(c, receipt, state) {
  const a = areas(c)
  preserveLegacyState(a.manifest, state)
  atomic(a.manifest, JSON.stringify({ version: 2, appPath: c.app, agentPath: c.agent, appHash: receipt.expectedHash, agentHash: receipt.agentHash }, null, 2) + '\n')
  finishCommit(c, receipt)
}
/** Commit an acknowledged update once the app is the authenticated one and Sparkle's installer is provably gone, so the last recovery
 * barrier (receipt and backup) is never dropped while the installer could still write. @param {Context} c @param {Receipt} receipt @param {InstallState} state */
function commitIfQuiescent(c, receipt, state) {
  // An explicit rollback intent always dominates an acknowledgment.
  if (receipt.phase === 'rolling-back' || currentAppHash(c) !== receipt.expectedHash || !installerGone(c)) return false
  commit(c, receipt, state)
  return true
}
/** Apply the safe recovery for whatever a crash or failure left behind. Every disposal or rollback needs positively established
 * installer quiescence; unknown retains the transaction. A prepared update is discarded only once its owning host and watcher are
 * gone and no installer job remains. An app that matches neither the old nor the authenticated new tree is never replaced here:
 * only the watcher (after the installer is gone) or an explicit rollback may restore the backup.
 * @param {Context} c @param {InstallState|null} state @returns {{kind:Settled, receipt:Receipt|null}} */
function settle(c, state) {
  const receipt = readReceipt(c)
  if (!receipt) return { kind: 'none', receipt: null }
  if (receipt === 'incomplete') { discardTransaction(c); return { kind: 'none', receipt: null } }
  assertRecordedPaths(c, receipt, state)
  const kind = classify(c, state, receipt, true)
  // A valid acknowledgment is never rolled back automatically (only an explicit rollback clears it) and commits once the installer is gone.
  const acknowledgedPending = receipt.acknowledged && state !== null && receipt.phase !== 'rolling-back' && (kind === 'awaiting' || kind === 'busy' || kind === 'abandoned')
  if (acknowledgedPending && state && commitIfQuiescent(c, receipt, state)) return { kind: 'finished', receipt }
  if (acknowledgedPending && kind === 'abandoned') return { kind: 'busy', receipt }
  switch (kind) {
    case 'committed': case 'stale':
      if (!installerGone(c)) return { kind: 'busy', receipt }
      if (kind === 'committed') { finishCommit(c, receipt); return { kind: 'finished', receipt } }
      discardTransaction(c); return { kind: 'none', receipt: null }
    case 'abandoned-prepared': discardTransaction(c); return { kind: 'none', receipt: null }
    case 'authorized': return { kind: 'authorized', receipt }
    case 'awaiting': return { kind: 'awaiting', receipt }
    case 'busy': return { kind: 'busy', receipt }
    case 'unexpected': return { kind: 'unexpected', receipt }
    default:
      return rolledBack(c, receipt, receipt.phase === 'rolling-back' && receipt.error ? receipt.error.split('; rollback incomplete')[0] : 'The update worker stopped before the new version confirmed startup')
  }
}
/** @param {Settled} kind @param {Receipt} receipt */
function pendingReason(kind, receipt) {
  switch (kind) {
    case 'authorized': return `The update to ${receipt.toVersion} was authorized by a running instance of OMP Usage and may still be installed.`
    case 'awaiting': return `The update to ${receipt.toVersion} is waiting for the new version to confirm startup.`
    case 'busy': return `The update to ${receipt.toVersion} is being installed.`
    case 'unexpected': return `The installed app does not match the pending update to ${receipt.toVersion}. To restore the previous version run the updater recovery (update-ownership.mjs recover) with {"action":"rollback"}.`
    default: return `${receipt.error ?? `The update to ${receipt.toVersion} could not be rolled back`}. ${recoveryHint}`
  }
}

/** Verify this is a managed, same-user, unmodified installation that may be updated.
 * @param {Context} c */
function verifyManaged(c) {
  if (c.platform !== 'darwin') throw new UpdateError('not-managed', 'Updates require macOS.')
  const state = readManifest(c)
  if (!state) throw new UpdateError('not-managed', 'This copy of OMP Usage was not installed by the OMP Usage installer, so automatic updates are unavailable.', setupRecovery)
  if (state.appPath !== c.app || state.agentPath !== c.agent) throw new UpdateError('not-managed', 'This app is not at the location recorded by the installer, so automatic updates are unavailable.', setupRecovery)
  try { if (statSync(c.stateDir).uid !== c.owner) throw new Error('The state directory is owned by another user') } catch (error) { throw new UpdateError('ownership-mismatch', describe(error)) }
  /** @type {ReturnType<typeof scanTree>} */
  let scan
  try { scan = scanTree(c.app, { uid: c.owner }) } catch (error) { throw new UpdateError('ownership-mismatch', `The installed app cannot be verified: ${describe(error)}`) }
  if (scan.hash !== state.appHash) throw new UpdateError('ownership-mismatch', 'The installed app differs from the installer ownership record, so it will not be replaced.', modifiedRecovery)
  if (!present(c.agent) || !lstatSync(c.agent).isFile() || lstatSync(c.agent).uid !== c.owner || digest(readFileSync(c.agent)) !== state.agentHash) throw new UpdateError('ownership-mismatch', 'The LaunchAgent differs from the installer ownership record, so updates are unavailable.', modifiedRecovery)
  const args = agentProgramArguments(readFileSync(c.agent, 'utf8'))
  if (!args || args.length !== 3 || args[0] !== path.join(c.app, 'Contents/MacOS/OMPUsagePanel') || args[1] !== '--config' || args[2] !== c.config) throw new UpdateError('not-managed', 'This app was started with a configuration path that differs from the installed LaunchAgent, so automatic updates are unavailable.')
  /** @type {ReturnType<typeof loadedJob>} */
  let job
  try { job = loadedJob(c, state) } catch (error) { throw new UpdateError('ownership-mismatch', describe(error)) }
  let config
  try { config = parseConfig(JSON.parse(readFileSync(c.config, 'utf8'))) } catch (error) { throw new UpdateError('not-managed', `The configuration cannot be read: ${describe(error)}`) }
  return { state, scan, job, config }
}

/** Expected contents of the watcher directory for a verified app tree. @param {Map<string,TreeEntry>} entries */
function watcherPlan(entries) {
  /** @type {Map<string,TreeEntry>} */
  const plan = new Map()
  for (const rel of ['', 'runtime', 'runtime/apps', 'runtime/apps/macos']) plan.set(rel, { kind: 'd' })
  for (const file of trustedRuntimeFiles) {
    const entry = entries.get(path.join(runtimeDirectory, file))
    if (entry?.kind !== 'f') throw new UpdateError('not-managed', `This build of OMP Usage is missing the updater runtime file ${file}.`)
    plan.set(path.join('runtime/apps/macos', file), entry)
  }
  return plan
}
/** Create or refresh the copied watcher runtime outside the app bundle, verified entry-by-entry against the verified app and made
 * durable before it is published. Never call while a transaction is pending. @param {Context} c @param {Map<string,TreeEntry>} entries */
function ensureWatcherRuntime(c, entries) {
  const a = areas(c), plan = watcherPlan(entries)
  try { if (present(a.watcher) && sameEntries(scanTree(a.watcher, { uid: c.owner }).entries, plan)) return } catch { /* Rebuild an unreadable or tampered copy. */ }
  ensureUpdater(c)
  const staging = path.join(a.updater, `.watcher-${randomUUID()}`)
  try {
    mkdirSync(path.join(staging, 'runtime/apps/macos'), { recursive: true, mode: 0o700 })
    for (const file of trustedRuntimeFiles) copyFileSync(path.join(c.app, runtimeDirectory, file), path.join(staging, 'runtime/apps/macos', file))
    if (!sameEntries(scanTree(staging, { uid: c.owner }).entries, plan)) throw new UpdateError('ownership-mismatch', 'The app changed while the update watcher runtime was being copied.')
    syncTree(staging)
    const previous = `${a.watcher}.old-${randomUUID()}`
    if (present(a.watcher)) renameSync(a.watcher, previous)
    renameSync(staging, a.watcher)
    syncDirectory(a.updater)
    rmSync(previous, { recursive: true, force: true })
  } finally { rmSync(staging, { recursive: true, force: true }) }
}

/** @param {Context} c @returns {UpdateStatus} */
function snapshot(c) {
  const a = areas(c)
  /** @type {InstallState|null} */
  let state = null
  /** @type {string|null} */
  let unreadable = null
  try { state = loadManifest(a.manifest) } catch (error) { unreadable = describe(error) }
  /** @type {{kind:Settled, receipt:Receipt|null}} */
  let settled = { kind: 'none', receipt: null }
  try { if (unreadable === null) settled = settle(c, state) } catch (error) {
    if (!(error instanceof UpdateError)) throw error
    return { managed: false, reason: error.message, ...(error.recovery ? { recovery: error.recovery } : {}), pending: null, outcome: readOutcome(c) }
  }
  const outcome = readOutcome(c)
  if (unreadable !== null) return { managed: false, reason: `The installation record is unreadable: ${unreadable}`, pending: null, outcome }
  const pending = settled.receipt && settled.kind !== 'finished' && settled.kind !== 'rolled-back' ? settled.receipt : null
  if (pending) return { managed: false, reason: pendingReason(settled.kind, pending), pending: pendingInfo(c, pending), outcome }
  try {
    const verified = verifyManaged(c)
    ensureWatcherRuntime(c, verified.scan.entries)
    return { managed: true, pending: null, outcome }
  } catch (error) {
    if (!(error instanceof UpdateError)) throw error
    return { managed: false, reason: error.message, ...(error.recovery ? { recovery: error.recovery } : {}), pending: null, outcome }
  }
}

/** Ownership gate for the updater: reports whether this install may auto-update and recovers interrupted transactions whose
 * abandonment is established. A live authorization is never touched. @param {UpdateOptions} options @returns {UpdateStatus} */
export function updateStatus(options) {
  const c = updateContext(options)
  return withLock(c, () => snapshot(c), c.lockWaitMs)
}
/** Reconcile or, with action rollback, force back a pending update that has no live worker or watcher.
 * @param {UpdateOptions & {action?:'reconcile'|'rollback'}} options @returns {UpdateStatus} */
export function recoverUpdate(options) {
  const c = updateContext(options)
  return withLock(c, () => {
    if (options.action === 'rollback') {
      const receipt = readReceipt(c)
      if (!receipt || receipt === 'incomplete') throw new UpdateError('no-transaction', 'There is no pending update to roll back.')
      assertRecordedPaths(c, receipt, readManifest(c))
      if (workerAlive(c, receipt) || otherWatcherAlive(c, receipt)) throw new UpdateError('busy', 'An update worker or watcher is still running.')
      if (receipt.phase === 'prepared' && currentAppHash(c) === receipt.oldHash && sameProcess(c, receipt.hostPid, receipt.hostStart)) throw new UpdateError('busy', 'The update is still authorized by a running instance of OMP Usage; cancel it there.')
      rollback(c, receipt, 'The update was rolled back at the user\'s request')
    }
    return snapshot(c)
  }, c.lockWaitMs)
}

/** Arm the detached watcher for a prepared transaction and wait until it registered. A watcher that never registers is an error
 * so that nothing installs unwatched. @param {ReturnType<typeof updateContext>} c @param {string} id */
function armWatcher(c, id) {
  const a = areas(c), token = randomUUID()
  const launch = withLock(c, () => {
    const receipt = readReceipt(c)
    if (!receipt || receipt === 'incomplete' || receipt.id !== id || receipt.phase !== 'prepared') throw new UpdateError('no-transaction', 'There is no prepared update to arm.')
    assertRecordedPaths(c, receipt, readManifest(c))
    if (receipt.watcherPid !== null && sameProcess(c, receipt.watcherPid, receipt.watcherStart)) return null
    const backup = scanTree(a.backupApp, { uid: c.owner })
    if (backup.hash !== receipt.oldHash) throw new UpdateError('ownership-mismatch', 'The update backup no longer matches the installation record.')
    if (!sameEntries(scanTree(a.watcher, { uid: c.owner }).entries, watcherPlan(backup.entries))) throw new UpdateError('ownership-mismatch', 'The copied update watcher does not match the verified backup.')
    writeReceipt(c, { ...receipt, armToken: token, watcherPid: null })
    return { command: receipt.node, args: [a.watcherScript, 'watch', JSON.stringify({ stateDir: c.stateDir, transactionId: id, armToken: token })] }
  }, c.lockWaitMs)
  if (!launch) return
  try { c.spawnWatcher(launch.command, launch.args) } catch (error) { throw new UpdateError('arm-failed', `The update watcher could not be started: ${describe(error)}`) }
  for (let waited = 0; ; waited += c.pollMs) {
    const receipt = readReceipt(c)
    if (receipt && receipt !== 'incomplete' && receipt.id === id && receipt.watcherPid !== null && sameProcess(c, receipt.watcherPid, receipt.watcherStart)) return
    if (waited >= c.armWaitMs) throw new UpdateError('arm-failed', 'The update watcher did not start.')
    c.sleep(c.pollMs)
  }
}

/** Prepare and arm an update: verify ownership, create a private receipt that leases the update to `ownerPid`, a durable verified
 * backup of the running app and the copied watcher runtime, then start the detached watcher. Must succeed before any install-capable
 * Sparkle pipeline is entered. Idempotent for the same live owner, version and hash.
 * @param {PrepareOptions} options @returns {{transactionId:string, armed:true}} */
export function prepareUpdate(options) {
  if (typeof options.expectedVersion !== 'string' || !versionPattern.test(options.expectedVersion) || typeof options.currentVersion !== 'string' || !versionPattern.test(options.currentVersion) ||
      typeof options.expectedAppTreeSHA256 !== 'string' || !hex64.test(options.expectedAppTreeSHA256) || !Number.isInteger(options.ownerPid) || options.ownerPid <= 1) throw new UpdateError('invalid-request', 'prepare requires expectedVersion, currentVersion, a lowercase hex expectedAppTreeSHA256 and the owner process id')
  const c = updateContext(options)
  const id = withLock(c, () => {
    if (!c.alive(options.ownerPid)) throw new UpdateError('invalid-request', 'The owner process is not running.')
    const hostStart = c.processStart(options.ownerPid)
    if (hostStart === null) throw new UpdateError('invalid-request', 'The identity of the owner process cannot be established.')
    const a = areas(c), stored = readManifest(c)
    const settled = settle(c, stored)
    if (settled.receipt && settled.kind === 'authorized') {
      const live = settled.receipt
      if (live.revoked) throw new UpdateError('authorization-active', `The update to ${live.toVersion} is being cancelled; wait until the installer is gone before preparing another.`)
      if (live.hostPid === options.ownerPid && live.hostStart === hostStart && live.toVersion === options.expectedVersion && live.expectedHash === options.expectedAppTreeSHA256) return live.id
      throw new UpdateError('authorization-active', `The update to ${live.toVersion} is still authorized; resolve and abort it before preparing another.`)
    }
    if (settled.receipt && settled.kind !== 'finished' && settled.kind !== 'rolled-back') throw new UpdateError('pending-update', pendingReason(settled.kind, settled.receipt))
    const verified = verifyManaged(c)
    if (options.expectedAppTreeSHA256 === verified.state.appHash) throw new UpdateError('invalid-request', 'The update is identical to the installed app')
    if (verified.job?.pid !== undefined && verified.job.pid !== options.ownerPid) throw new UpdateError('ownership-mismatch', 'The owner process is not the registered LaunchAgent process.')
    ensureWatcherRuntime(c, verified.scan.entries)
    try {
      mkdirSync(a.transaction, { mode: 0o700 }); mkdirSync(a.backup, { mode: 0o700 })
      cpSync(c.app, a.backupApp, { recursive: true, verbatimSymlinks: true, errorOnExist: true, force: false })
      if (scanTree(a.backupApp, { uid: c.owner }).hash !== verified.state.appHash) throw new UpdateError('ownership-mismatch', 'The app changed while its backup was being created.')
      // Everything the receipt promises must be durable before the receipt is published.
      syncTree(a.backupApp); syncDirectory(a.backup)
      atomic(a.backupManifest, readFileSync(a.manifest))
      syncDirectory(a.transaction); syncDirectory(a.updater)
      /** @type {Receipt} */
      const receipt = { schema: 1, id: randomUUID(), phase: 'prepared', createdAt: c.now(), fromVersion: options.currentVersion, toVersion: options.expectedVersion, oldHash: verified.state.appHash, expectedHash: options.expectedAppTreeSHA256, appPath: c.app, agentPath: c.agent, configPath: c.config, stateDir: c.stateDir, agentHash: verified.state.agentHash, node: process.execPath, jobLoaded: verified.job !== null, hostPid: options.ownerPid, hostStart, restart: false, revoked: false, watcherPid: null, watcherStart: null, armToken: null, workerPid: null, workerStart: null, acknowledged: false, deadline: null, error: null }
      writeReceipt(c, receipt)
      return receipt.id
    } catch (error) { discardTransaction(c); throw error }
  }, c.lockWaitMs)
  try { armWatcher(c, id) } catch (error) {
    // Never leave an unwatched authorization behind.
    withLock(c, () => { const receipt = readReceipt(c); if (receipt && receipt !== 'incomplete' && receipt.id === id && receipt.phase === 'prepared' && currentAppHash(c) === receipt.oldHash) discardTransaction(c) }, c.lockWaitMs)
    throw error
  }
  return { transactionId: id, armed: true }
}
/** Durably withdraw the restart authorization of a prepared update without deleting anything: the transaction, backup and watcher stay.
 * Call it before the SDK is told to cancel. Terminal refusals: `unknown-transaction`, `relaunching`, `replaced`.
 * @param {UpdateOptions & {transactionId:string}} options @returns {{revoked:boolean, code?:string, reason?:string}} */
export function revokeUpdate(options) {
  const c = updateContext(options)
  return withLock(c, () => {
    const checked = revocable(c, options.transactionId)
    if ('code' in checked) return { revoked: false, ...checked }
    return { revoked: true }
  }, c.lockWaitMs)
}
/** @param {Context} c @param {string} transactionId @returns {{code:string, reason:string}|Receipt} */
function revocable(c, transactionId) {
  const receipt = readReceipt(c)
  if (!receipt || receipt === 'incomplete' || receipt.id !== transactionId) return { code: 'unknown-transaction', reason: 'There is no such prepared update.' }
  assertRecordedPaths(c, receipt, readManifest(c))
  if (receipt.phase !== 'prepared') return { code: 'relaunching', reason: 'The update is already being installed.' }
  if (currentAppHash(c) !== receipt.oldHash) return { code: 'replaced', reason: 'The app was already replaced.' }
  if (!receipt.revoked || receipt.restart) writeReceipt(c, { ...receipt, restart: false, revoked: true })
  return receipt
}
/** Cancel a prepared update after the SDK session was torn down locally. It always revokes first and keeps the transaction and backup
 * until launchd proves Sparkle's host-specific installer and progress jobs (identified exactly) are not running; idle registered jobs
 * are removed and verified gone. UI dismissal or the end of the SDK cycle is not that proof: while a job may still install the answer
 * is `installer-live` (retry); an unidentifiable or uninspectable job is the error `inspection-failed`. Terminal refusals:
 * `unknown-transaction`, `relaunching`, `replaced` (the installation is proceeding). `installerLabel` is only checked, never trusted.
 * @param {UpdateOptions & {transactionId:string, installerLabel?:string}} options @returns {{aborted:boolean, code?:string, reason?:string}} */
export function abortUpdate(options) {
  if (options.installerLabel !== undefined && options.installerLabel !== installerLabel) throw new UpdateError('invalid-request', 'installerLabel does not name this app\'s Sparkle installer job')
  const c = updateContext(options)
  return withLock(c, () => {
    const checked = revocable(c, options.transactionId)
    if ('code' in checked) return { aborted: false, ...checked }
    try {
      const jobs = inspectInstaller(c)
      if (jobs.some(job => job.running)) return { aborted: false, code: 'installer-live', reason: 'The Sparkle installer may still install the update.' }
      removeIdleInstallerJobs(c, jobs)
    } catch (error) { throw new UpdateError('inspection-failed', `The Sparkle installer jobs could not be verified gone: ${describe(error)}`) }
    discardTransaction(c)
    return { aborted: true }
  }, c.lockWaitMs)
}
/** Final live-safe handoff: only now may the replacement be followed by a managed restart. Without it, a host that quits (the user's
 * Quit) is never restarted, even if the SDK still replaces the app; the next real launch acknowledges instead.
 * @param {UpdateOptions & {transactionId:string}} options @returns {{authorized:boolean, reason?:string}} */
export function authorizeRestart(options) {
  const c = updateContext(options)
  return withLock(c, () => {
    const receipt = readReceipt(c)
    if (!receipt || receipt === 'incomplete' || receipt.id !== options.transactionId) return { authorized: false, reason: 'There is no such prepared update.' }
    assertRecordedPaths(c, receipt, readManifest(c))
    if (receipt.phase !== 'prepared' || currentAppHash(c) !== receipt.oldHash) return { authorized: false, reason: 'The app was already replaced or is being installed.' }
    if (receipt.revoked) return { authorized: false, reason: 'The update was cancelled.' }
    if (!sameProcess(c, receipt.hostPid, receipt.hostStart) || receipt.watcherPid === null || !sameProcess(c, receipt.watcherPid, receipt.watcherStart)) return { authorized: false, reason: 'The owner or the watcher is no longer running.' }
    if (!receipt.restart) writeReceipt(c, { ...receipt, restart: true })
    return { authorized: true }
  }, c.lockWaitMs)
}
/** Startup acknowledgment from the running app: record that it is exactly the authenticated update and commit ownership of it as
 * soon as Sparkle's installer is provably gone. Until then the acknowledgment is retained durably (receipt and backup stay) and the
 * watcher or the next status commits it; the answer is `pending`.
 * @param {UpdateOptions & {version:string}} options @returns {{committed:boolean, pending:boolean, reason?:'installer-quiescing'|'rolling-back'|'not-replaced'}} */
export function acknowledgeUpdate(options) {
  const c = updateContext(options)
  return withLock(c, () => {
    const receipt = readReceipt(c)
    if (!receipt || receipt === 'incomplete') return { committed: false, pending: false }
    const state = loadManifest(areas(c).manifest)
    assertRecordedPaths(c, receipt, state)
    if (state?.appHash === receipt.expectedHash) {
      if (!installerGone(c)) return { committed: false, pending: true, reason: 'installer-quiescing' }
      finishCommit(c, receipt); return { committed: true, pending: false }
    }
    if (!state || state.appHash !== receipt.oldHash) {
      if (!installerGone(c)) return { committed: false, pending: true, reason: 'installer-quiescing' }
      discardTransaction(c); return { committed: false, pending: false }
    }
    if (receipt.phase === 'rolling-back') return { committed: false, pending: true, reason: 'rolling-back' }
    const hash = currentAppHash(c)
    if (hash === receipt.oldHash) return { committed: false, pending: true, reason: 'not-replaced' }
    if (hash !== receipt.expectedHash) throw new UpdateError('ownership-mismatch', 'The running app does not match the authenticated update.')
    if (options.version !== receipt.toVersion) throw new UpdateError('ownership-mismatch', `The running app reports version ${options.version}, expected ${receipt.toVersion}.`)
    if (!agentMatches(c, receipt)) throw new UpdateError('ownership-mismatch', 'The LaunchAgent no longer matches the installation record.')
    try { loadedJob(c, state) } catch (error) { throw new UpdateError('ownership-mismatch', describe(error)) }
    const acknowledged = { ...receipt, acknowledged: true }
    if (!receipt.acknowledged) writeReceipt(c, acknowledged)
    return commitIfQuiescent(c, acknowledged, state) ? { committed: true, pending: false } : { committed: false, pending: true, reason: 'installer-quiescing' }
  }, c.lockWaitMs)
}

/** @param {Context} c @param {string} id @param {string} fallback @returns {{outcome:Outcome['status'], message:string}} */
function recordedResult(c, id, fallback) {
  const outcome = readOutcome(c)
  return outcome?.transactionId === id ? { outcome: outcome.status, message: outcome.message } : { outcome: 'failed', message: fallback }
}
/** Context for a transaction, built from the absolute paths its receipt recorded. @param {UpdateOptions} options @param {Receipt} receipt */
function contextFor(options, receipt) {
  return updateContext({ ...options, stateDir: receipt.stateDir, appPath: receipt.appPath, agentPath: receipt.agentPath, configPath: receipt.configPath })
}
/** @param {UpdateOptions} options @param {ReturnType<typeof updateContext>} base */
function beginRelaunch(options, base) {
  const first = readReceipt(base)
  if (!first || first === 'incomplete') return /** @type {const} */ ({ done: true, result: { outcome: /** @type {Outcome['status']} */ ('failed'), message: 'There is no pending update to relaunch.' } })
  if (canonical(first.stateDir) !== canonical(base.stateDir)) throw new UpdateError('ownership-mismatch', 'The pending update belongs to a different state directory.')
  const c = contextFor(options, first)
  const state = readManifest(c), settled = settle(c, state), receipt = settled.receipt
  /** @param {string} fallback */
  const finished = fallback => /** @type {const} */ ({ done: true, result: recordedResult(c, first.id, fallback) })
  switch (settled.kind) {
    case 'finished': return finished('Updated')
    case 'none': return finished('There is no pending update to relaunch.')
    case 'rolled-back': case 'rollback-failed': return finished('The update was rolled back.')
    case 'busy': case 'authorized': throw new UpdateError('busy', 'Another update worker is already running or the update is still authorized.')
    default:
  }
  if (!receipt) return finished('There is no pending update to relaunch.')
  if (settled.kind === 'unexpected') { rolledBack(c, receipt, 'The installed app did not match the authenticated update and was rolled back'); return finished('The update was rolled back.') }
  try {
    if (loadedJob(c, state)) stopJob(c)
    if (!agentMatches(c, receipt)) throw new Error('The LaunchAgent no longer matches the installation record')
    const deadline = c.now() + c.readinessMs
    writeReceipt(c, { ...receipt, phase: 'relaunching', workerPid: c.self, workerStart: c.processStart(c.self), deadline, error: null })
    startJob(c)
    return /** @type {const} */ ({ done: false, c, id: receipt.id, deadline })
  } catch (error) {
    rolledBack(c, receipt, `The updated app could not be started: ${describe(error)}`)
    return finished('The update was rolled back.')
  }
}
/** Commit an acknowledged update once the installer is gone (worker side). @param {ReturnType<typeof updateContext>} c @param {string} id */
function finalizeAcknowledged(c, id) {
  withLock(c, () => {
    const receipt = readReceipt(c), state = loadManifest(areas(c).manifest)
    if (receipt && receipt !== 'incomplete' && receipt.id === id && receipt.acknowledged && state && state.appHash === receipt.oldHash) commitIfQuiescent(c, receipt, state)
  }, c.lockWaitMs)
}
/** Restart the verified LaunchAgent on the replaced app and wait for the startup acknowledgment; on failure restore the previous app.
 * Run by the watcher once the host has exited, the authenticated replacement is in place and the installer is gone. A valid
 * acknowledgment is never rolled back: the worker then only waits for the installer to be gone so ownership can commit.
 * `options.stateDir` selects the updater area.
 * @param {UpdateOptions} options @returns {{outcome:Outcome['status'], message:string}} */
export function relaunchUpdate(options) {
  const base = updateContext(options)
  const begun = withLock(base, () => beginRelaunch(options, base), base.lockWaitMs)
  if (begun.done) return begun.result
  const { c, id, deadline } = begun
  let exited = 0, checkedAt = -Infinity, reason = `The updated app did not confirm startup within ${Math.round(c.readinessMs / 1000)} seconds`
  while (true) {
    c.sleep(c.pollMs)
    /** @type {Receipt|'incomplete'|null|undefined} */
    let pending
    try { pending = readReceipt(c) } catch { pending = undefined }
    if (pending === null || pending === 'incomplete') {
      const outcome = readOutcome(c)
      if (outcome?.transactionId === id) return { outcome: outcome.status, message: outcome.message }
      if (pending === null) return { outcome: 'failed', message: 'The update transaction ended without a recorded outcome.' }
      continue
    }
    if (pending === undefined) continue
    if (pending.id !== id) return { outcome: 'failed', message: 'The update transaction was replaced.' }
    if (pending.acknowledged) {
      if (c.now() - checkedAt >= 1000) { checkedAt = c.now(); try { finalizeAcknowledged(c, id) } catch { /* Retried; the receipt and backup stay. */ } }
      continue
    }
    if (c.now() >= deadline) break
    let job
    try { job = loadedJob(c, loadManifest(areas(c).manifest)) } catch { job = undefined }
    exited = job === null || job?.state === 'not running' ? exited + 1 : 0
    if (exited >= 8) { reason = 'The updated app exited before confirming startup'; break }
  }
  return withLock(c, () => {
    const last = readReceipt(c)
    if (!last || last === 'incomplete' || last.id !== id) return recordedResult(c, id, 'The update transaction ended without a recorded outcome.')
    if (last.acknowledged) return recordedResult(c, id, 'The new version acknowledged startup; ownership commits once the Sparkle installer is gone.')
    const restored = rollback(c, last, reason)
    return recordedResult(c, id, restored ? reason : `${reason}; rollback incomplete`)
  }, c.lockWaitMs)
}

/** Watcher start-up: bind this process to the transaction it was armed for. @param {UpdateOptions & {transactionId:string, armToken:string}} options */
export function registerWatcher(options) {
  const base = updateContext(options)
  withLock(base, () => {
    const receipt = readReceipt(base)
    if (!receipt || receipt === 'incomplete' || receipt.id !== options.transactionId || receipt.phase !== 'prepared' || receipt.armToken === null || receipt.armToken !== options.armToken) throw new UpdateError('no-transaction', 'The watcher is not armed for a prepared update.')
    writeReceipt(contextFor(options, receipt), { ...receipt, watcherPid: base.self, watcherStart: base.processStart(base.self), armToken: null })
  }, base.lockWaitMs)
}
/** The detached watcher process: register, then watch. @param {UpdateOptions & {transactionId:string, armToken:string}} options */
export function watchUpdate(options) {
  registerWatcher(options)
  return runWatcher(options)
}
/** The registered watcher, running from the copied runtime outside the replaced bundle. It does nothing while the host that holds the
 * authorization is alive (download and extraction can take as long as they need). Once the host has exited it waits for the
 * authenticated replacement, then takes over as relaunch worker, but only if the final handoff authorized a managed restart: a host
 * that merely quit is never restarted. If the host is gone and the app stays unreplaced for the grace period, the SDK did not install
 * and, once launchd confirms the installer is gone, the watcher exits, leaving the abandoned receipt for the next recovery to discard.
 * @param {UpdateOptions & {transactionId:string}} options @returns {{outcome:Outcome['status']|'lapsed'|'cancelled'|'deferred', message:string}} */
export function runWatcher(options) {
  const base = updateContext(options), first = readReceipt(base)
  if (!first || first === 'incomplete' || first.id !== options.transactionId) throw new UpdateError('no-transaction', 'The watcher is not armed for a prepared update.')
  const c = contextFor(options, first), id = first.id
  let hostGoneAt = /** @type {number|null} */ (null), signature = '', hash = /** @type {string|null} */ (null), checkedAt = -Infinity
  while (true) {
    /** @type {Receipt|'incomplete'|null|undefined} */
    let receipt
    try { receipt = readReceipt(c) } catch { receipt = undefined }
    if (receipt === null || receipt === 'incomplete') {
      const outcome = readOutcome(c)
      if (outcome?.transactionId === id) return { outcome: outcome.status, message: outcome.message }
      if (receipt === null) return { outcome: 'cancelled', message: 'The authorization ended.' }
    } else if (receipt !== undefined) {
      if (receipt.id !== id || receipt.watcherPid !== c.self) return { outcome: 'cancelled', message: 'The watcher was superseded.' }
      if (receipt.phase !== 'prepared') return { outcome: 'failed', message: 'Another worker owns the update transaction.' }
      const hostAlive = sameProcess(c, receipt.hostPid, receipt.hostStart)
      if (hostAlive) hostGoneAt = null
      else hostGoneAt ??= c.now()
      // The installer is inspected at most once a second; absence is only ever concluded from launchd, never from elapsed time.
      const inspect = c.now() - checkedAt >= 1000
      if (receipt.revoked && inspect) {
        checkedAt = c.now()
        try { if (abortUpdate({ ...options, stateDir: c.stateDir, transactionId: id }).aborted) return { outcome: 'cancelled', message: 'The update was cancelled and the installer is gone.' } } catch { /* Keep waiting; the installer could not be inspected. */ }
      }
      if (!hostAlive && hostGoneAt !== null) {
        const current = appSignature(c)
        if (current !== signature) { signature = current; hash = currentAppHash(c) }
        if (hash === receipt.oldHash) {
          // Nothing replaced the app: only launchd proof that the installer is gone, after the grace period, ends the authorization.
          if (inspect && c.now() - hostGoneAt >= c.graceMs) { checkedAt = c.now(); if (installerGone(c)) return { outcome: 'lapsed', message: 'The host exited and the installer is gone without the update being installed.' } }
        } else if (!receipt.restart) return { outcome: 'deferred', message: 'The app was replaced without restart authorization; the next launch confirms it.' }
        // The app is no longer the old tree. The moment launchd proves the installer gone, the replacement is final: it is either the
        // authenticated update (restart) or something else (relaunch rolls it back). No grace period applies, only that proof.
        else if (inspect) { checkedAt = c.now(); if (installerGone(c)) break }
      }
    }
    c.sleep(c.pollMs)
  }
  return relaunchUpdate({ ...options, stateDir: c.stateDir })
}

/** Recognize a pending update during source install/uninstall. Refuses (also for dry runs) while an authorization or worker is
 * live. Returns the ownership state those flows must verify against (the pending new app, when Sparkle already replaced it) and
 * whether a superseded transaction must be discarded afterwards.
 * @param {Context} c @param {InstallState|null} state @returns {{state:InstallState|null, pending:boolean, manifest:InstallState|null}} */
export function reconcileUpdate(c, state) {
  if (c.dry) {
    const receipt = readReceipt(c)
    if (!receipt || receipt === 'incomplete' || !state) return { state, pending: false, manifest: state }
    assertRecordedPaths(c, receipt, state)
    const kind = classify(c, state, receipt)
    if (kind === 'authorized' || kind === 'busy') throw new Error(liveUpdateMessage)
    return kind === 'awaiting' ? { state: { ...state, appHash: receipt.expectedHash }, pending: true, manifest: state } : { state, pending: false, manifest: state }
  }
  const settled = settle(c, state)
  switch (settled.kind) {
    case 'awaiting': return { state: state && settled.receipt ? { ...state, appHash: settled.receipt.expectedHash } : state, pending: true, manifest: state }
    case 'authorized': case 'busy': throw new Error(liveUpdateMessage)
    case 'rollback-failed': throw new Error(`An interrupted update could not be rolled back: ${settled.receipt?.error ?? 'unknown error'}`)
    case 'finished': { const committed = readManifest(c); return { state: committed, pending: false, manifest: committed } }
    default: return { state, pending: false, manifest: state }
  }
}
/** Drop a pending transaction superseded by a source install or uninstall. @param {Context} c */
export function discardPendingUpdate(c) { discardTransaction(c) }
/** Remove the installer-owned updater area (watcher copy, outcome and any transaction) on uninstall. @param {Context} c */
export function removeUpdaterArea(c) {
  const a = areas(c)
  if (!present(a.updater)) return
  const stat = lstatSync(a.updater)
  if (!stat.isDirectory() || stat.uid !== c.owner) throw new Error(`Refusing to remove an updater directory not owned by this user: ${a.updater}`)
  rmSync(a.updater, { recursive: true, force: true })
}
