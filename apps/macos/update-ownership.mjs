import { readFileSync } from 'node:fs'
import path from 'node:path'
import { UpdateError, abortUpdate, acknowledgeUpdate, authorizeRestart, prepareUpdate, recoverUpdate, revokeUpdate, updateStatus, watchUpdate } from './update-transaction.mjs'

/**
 * Update-ownership CLI: `node update-ownership.mjs <status|prepare|authorize|revoke|abort|acknowledge|recover>`.
 * One JSON object on stdin, one JSON line on stdout. Exit 0: {"ok":true,"command":C,...}. Exit 1:
 * {"ok":false,"command":C,"error":{"code":string,"message":string,"recovery"?:string}}.
 *
 * Every command takes {"appPath","configPath"} (absolute; `stateDir`/`agentPath` are optional and normally omitted).
 *   status       {}                                  -> {managed, reason?, recovery?, pending, outcome}
 *                pending: null | {transactionId, phase, fromVersion, toVersion, armed, ownerAlive}
 *   prepare      {expectedVersion, expectedAppTreeSHA256, currentVersion, ownerPid} -> {transactionId, armed:true}
 *                `ownerPid` must be the invoking process (this process's parent), whose start time is pinned in the lease.
 *                Leases the update to the live host `ownerPid`, makes a durable verified backup and starts the detached watcher.
 *   authorize    {transactionId}                     -> {authorized, reason?}   final handoff: permits the managed restart
 *   revoke       {transactionId}                     -> {revoked, code?, reason?}  durable withdrawal; deletes nothing (code: unknown-transaction|relaunching|replaced)
 *   abort        {transactionId, installerLabel?}    -> {aborted, code?, reason?}  `installerLabel` is only validated
 *                Revokes the restart authorization at once but keeps the transaction and backup; discards them (aborted:true) only
 *                while the old app is unreplaced and launchd proves Sparkle's host-specific installer and progress jobs
 *                (`<bundle id>-sparkle-updater`/`-sparkle-progress`, identified by bundled executable + full arguments) are not running. Non-terminal: code "installer-live" (retry). Terminal: "unknown-transaction", "relaunching", "replaced".
 *                An uninspectable installer fails with error code "inspection-failed" (retry).
 *   acknowledge  {version}                           -> {committed, pending, reason?}
 *                {committed:true}: done. {committed:false,pending:false}: nothing pending. pending:true is retryable only with
 *                reason "installer-quiescing" (acknowledged and retained; committed once Sparkle's installer is gone); "rolling-back"
 *                and "not-replaced" are not. A wrong replacement is the error "ownership-mismatch". Transient errors: busy, io-error.
 *   recover      {action?: "reconcile"|"rollback"}   -> status result
 * `watch` is internal: `node update-ownership.mjs watch '<json {stateDir, transactionId, armToken}>'` is the detached watcher that
 * `prepare` starts from the copied runtime; its output is discarded.
 */
const commonKeys = ['appPath', 'configPath', 'stateDir', 'agentPath']
const maxInputBytes = 65536

/** @param {unknown} value */
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value) }
/** @param {Record<string,unknown>} request @param {string} key */
function requiredString(request, key) {
  const value = request[key]
  if (typeof value !== 'string' || value.length === 0) throw new UpdateError('invalid-request', `${key} must be a non-empty string`)
  return value
}
/** @param {Record<string,unknown>} request @param {string} key */
function requiredInteger(request, key) {
  const value = request[key]
  if (typeof value !== 'number' || !Number.isInteger(value) || value <= 1) throw new UpdateError('invalid-request', `${key} must be a process id`)
  return value
}
/** @param {Record<string,unknown>} request @param {string} key */
function absolutePath(request, key) {
  const value = requiredString(request, key)
  if (!path.isAbsolute(value)) throw new UpdateError('invalid-request', `${key} must be an absolute path`)
  return value
}
/** @param {Record<string,unknown>} request @param {string[]} allowed */
function rejectUnknown(request, allowed) {
  for (const key of Object.keys(request)) if (!allowed.includes(key)) throw new UpdateError('invalid-request', `Unknown field: ${key}`)
}
/** @param {Record<string,unknown>} request @param {string[]} extra */
function baseOptions(request, extra) {
  rejectUnknown(request, [...commonKeys, ...extra])
  /** @type {import('./update-transaction.mjs').UpdateOptions} */
  const options = { appPath: absolutePath(request, 'appPath'), configPath: absolutePath(request, 'configPath') }
  if (request.stateDir !== undefined) options.stateDir = absolutePath(request, 'stateDir')
  if (request.agentPath !== undefined) options.agentPath = absolutePath(request, 'agentPath')
  return options
}

/** Run one command against a parsed request. @param {string} command @param {Record<string,unknown>} request @returns {Record<string,unknown>} */
export function execute(command, request) {
  switch (command) {
    case 'status': return { ...updateStatus(baseOptions(request, [])) }
    case 'prepare': {
      const options = baseOptions(request, ['expectedVersion', 'expectedAppTreeSHA256', 'currentVersion', 'ownerPid'])
      if (requiredInteger(request, 'ownerPid') !== process.ppid) throw new UpdateError('invalid-request', 'ownerPid must be the process that invoked the updater')
      return { ...prepareUpdate({ ...options, expectedVersion: requiredString(request, 'expectedVersion'), expectedAppTreeSHA256: requiredString(request, 'expectedAppTreeSHA256'), currentVersion: requiredString(request, 'currentVersion'), ownerPid: requiredInteger(request, 'ownerPid') }) }
    }
    case 'authorize': {
      const options = baseOptions(request, ['transactionId'])
      return { ...authorizeRestart({ ...options, transactionId: requiredString(request, 'transactionId') }) }
    }
    case 'revoke': {
      const options = baseOptions(request, ['transactionId'])
      return { ...revokeUpdate({ ...options, transactionId: requiredString(request, 'transactionId') }) }
    }
    case 'acknowledge': {
      const options = baseOptions(request, ['version'])
      return { ...acknowledgeUpdate({ ...options, version: requiredString(request, 'version') }) }
    }
    case 'abort': {
      const options = baseOptions(request, ['transactionId', 'installerLabel'])
      return { ...abortUpdate({ ...options, transactionId: requiredString(request, 'transactionId'), ...(request.installerLabel === undefined ? {} : { installerLabel: requiredString(request, 'installerLabel') }) }) }
    }
    case 'recover': {
      const options = baseOptions(request, ['action'])
      const action = request.action ?? 'reconcile'
      if (action !== 'reconcile' && action !== 'rollback') throw new UpdateError('invalid-request', 'action must be "reconcile" or "rollback"')
      return { ...recoverUpdate({ ...options, action }) }
    }
    default: throw new UpdateError('invalid-request', `Unknown command: ${command}`)
  }
}
/** The detached watcher entry. @param {unknown} request */
export function watch(request) {
  if (!isObject(request)) throw new UpdateError('invalid-request', 'Request must be a JSON object')
  const fields = /** @type {Record<string,unknown>} */ (request)
  rejectUnknown(fields, ['stateDir', 'transactionId', 'armToken'])
  return watchUpdate({ stateDir: absolutePath(fields, 'stateDir'), transactionId: requiredString(fields, 'transactionId'), armToken: requiredString(fields, 'armToken') })
}

/** Translate a command's result or failure into the stdout payload and exit code. @param {string} command @param {()=>Record<string,unknown>} action */
export function respond(command, action) {
  try {
    return { exitCode: 0, payload: { ok: true, command, ...action() } }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    if (error instanceof UpdateError) return { exitCode: 1, payload: { ok: false, command, error: { code: error.code, message, ...(error.recovery ? { recovery: error.recovery } : {}) } } }
    // A critical section held by another process is transient; every other unexpected failure is an I/O problem.
    return { exitCode: 1, payload: { ok: false, command, error: { code: message.startsWith('Installer lock exists') ? 'busy' : 'io-error', message } } }
  }
}

if (import.meta.main) {
  const command = process.argv[2] ?? ''
  const { exitCode, payload } = respond(command, () => {
    if (command === 'watch') {
      let request
      try { request = JSON.parse(process.argv[3] ?? '') } catch { throw new UpdateError('invalid-request', 'Request is not valid JSON') }
      return { ...watch(request) }
    }
    const raw = readFileSync(0)
    if (raw.length > maxInputBytes) throw new UpdateError('invalid-request', 'Request is too large')
    let request
    try { request = raw.length ? JSON.parse(raw.toString('utf8')) : {} } catch { throw new UpdateError('invalid-request', 'Request is not valid JSON') }
    if (!isObject(request)) throw new UpdateError('invalid-request', 'Request must be a JSON object')
    return execute(command, /** @type {Record<string,unknown>} */ (request))
  })
  process.stdout.write(`${JSON.stringify(payload)}\n`)
  process.exitCode = exitCode
}
