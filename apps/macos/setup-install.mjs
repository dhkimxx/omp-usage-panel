import { readSync, realpathSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { install, launchManaged } from './installation.mjs'
import { InstallError, context } from './ownership.mjs'
import { UpdateError } from './update-transaction.mjs'

/**
 * First-run setup helper shipped inside the app: `node setup-install.mjs <install|launch>`. One JSON object on stdin, one JSON line on
 * stdout. Exit 0: {"ok":true,"command":C,"action":A,"appPath","configPath","pid"?}. Exit 1: {"ok":false,"command":C,"error":{"code","message"}}.
 *
 * Request (strict: no other field is accepted): {"sourceAppPath","hostPid","nodePath"?,"ompPath"?,"profile"?}. `sourceAppPath` must be
 * the app bundle that contains this very helper (compared by physical path), so only the running app itself can ever be the payload.
 * `nodePath`, `ompPath` and `profile` are install-only and used only when no configuration exists yet; an existing valid configuration
 * is authoritative, is never rewritten, and its paths and profile win over anything supplied.
 *
 *   install  Installs the prebuilt app that contains this helper (no Swift, Xcode or source checkout) into ~/Applications, creates the
 *            configuration only when absent, writes the per-user LaunchAgent and starts the registered job -> action "relaunch".
 *            The app is copied with ditto, so quarantine and every other extended attribute survive, and the copy must equal the
 *            source tree entry for entry and verify with codesign. When the app already sits at the destination (a fresh, deliberately
 *            launched copy) it is adopted in place instead. Foreign or modified apps and LaunchAgents, foreign jobs and live Sparkle
 *            transactions are refused. A running OMP Usage process is never signalled: error "running" until the user quits it.
 *   launch   The installed canonical app was opened without arguments: verify the managed installation, then hand over to its job.
 *            action "activate" (+ pid): a verified job is already running elsewhere; "continue": `hostPid` is that job's process;
 *            "relaunch": the idle loaded job was kickstarted (never -k) or the unloaded one bootstrapped, so the caller must exit.
 *
 * Error codes: invalid-request, source-mismatch, unsupported, busy, update-in-progress, running, not-managed, manifest-invalid,
 * foreign-app, foreign-agent, foreign-job, foreign-state, state-unsafe, config-invalid, config-changed, node-unavailable, omp-unavailable,
 * invalid-profile, invalid-source, copy-failed, install-failed, rollback-incomplete, io-error.
 */
export const helperPath = 'Contents/Resources/runtime/apps/macos/setup-install.mjs'
const maxInputBytes = 65536
// Another OMP Usage process may hold the installer lock for a few seconds while it checks its update state.
const lockWaitMs = 10_000
const fields = { install: ['sourceAppPath', 'hostPid', 'nodePath', 'ompPath', 'profile'], launch: ['sourceAppPath', 'hostPid'] }

/** `bundle` is the app that contains the running helper; production always derives it from this module's location.
 * @typedef {import('./ownership.mjs').OwnershipOptions & {bundle?:string}} SetupOptions */
/** @typedef {{sourceAppPath:string, hostPid:number, nodePath?:string, ompPath?:string, profile?:string}} SetupRequest */

/** @param {string} message */
function invalid(message) { return new InstallError('invalid-request', message) }
/** @param {unknown} value @returns {value is Record<string,unknown>} */
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value) }
/** @param {Record<string,unknown>} request @param {string} key @returns {string|undefined} */
function optionalString(request, key) {
  const value = request[key]
  if (value === undefined) return undefined
  if (typeof value !== 'string' || value.includes('\0')) throw invalid(`${key} must be a string`)
  return value
}
/** @param {Record<string,unknown>} request @param {'nodePath'|'ompPath'} key @param {string} code */
function executablePath(request, key, code) {
  const file = optionalString(request, key)
  if (file !== undefined && (!path.isAbsolute(file) || path.resolve(file) !== file)) throw new InstallError(code, `${key} must be a normalized absolute path`)
  return file
}
/** @param {'install'|'launch'} command @param {unknown} value @returns {SetupRequest} */
function parseRequest(command, value) {
  if (!isObject(value)) throw invalid('Request must be a JSON object')
  for (const key of Object.keys(value)) if (!fields[command].includes(key)) throw invalid(`Unknown field for ${command}: ${key}`)
  const sourceAppPath = optionalString(value, 'sourceAppPath')
  if (sourceAppPath === undefined || !path.isAbsolute(sourceAppPath)) throw invalid('sourceAppPath must be an absolute path')
  const hostPid = value.hostPid
  if (typeof hostPid !== 'number' || !Number.isInteger(hostPid) || hostPid <= 1) throw invalid('hostPid must be a process id')
  const nodePath = executablePath(value, 'nodePath', 'node-unavailable'), ompPath = executablePath(value, 'ompPath', 'omp-unavailable'), profile = optionalString(value, 'profile')
  return { sourceAppPath, hostPid, ...(nodePath === undefined ? {} : { nodePath }), ...(ompPath === undefined ? {} : { ompPath }), ...(profile === undefined ? {} : { profile }) }
}
/** The app bundle this helper runs from, by physical path. Anything else (a source checkout, a copied script) has no app to install.
 * @param {string} [helper] */
export function containingBundle(helper = fileURLToPath(import.meta.url)) {
  const real = realpathSync(helper), bundle = path.resolve(path.dirname(real), '../../../../..')
  if (!bundle.endsWith('.app') || path.join(bundle, helperPath) !== real) throw new InstallError('source-mismatch', 'The setup helper is not running from inside an OMP Usage app bundle')
  return bundle
}
/** @param {string} requested @param {string} bundle */
function matchSource(requested, bundle) {
  let actual, expected
  try { actual = realpathSync(requested); expected = realpathSync(bundle) } catch (error) { throw new InstallError('source-mismatch', 'sourceAppPath does not exist', error) }
  if (actual !== expected) throw new InstallError('source-mismatch', 'sourceAppPath is not the app that contains this setup helper')
  return expected
}

/** Run one command against a parsed request.
 * @param {string} command @param {unknown} value @param {SetupOptions} [options] @returns {{action:'relaunch'|'activate'|'continue', appPath:string, configPath:string, pid?:number}} */
export function execute(command, value, options = {}) {
  if (command !== 'install' && command !== 'launch') throw invalid(`Unknown command: ${command}`)
  const { bundle, ...ownership } = options
  const request = parseRequest(command, value)
  const source = matchSource(request.sourceAppPath, bundle ?? containingBundle())
  const { app: appPath, config: configPath } = context(ownership)
  if (command === 'launch') {
    const { action, pid } = launchManaged({ ...ownership, lockWaitMs, launch: { app: source, hostPid: request.hostPid } })
    return { action, appPath, configPath, ...(pid === undefined ? {} : { pid }) }
  }
  install({ ...ownership, lockWaitMs, prebuilt: { app: source }, node: request.nodePath ?? process.execPath, ...(request.ompPath === undefined ? {} : { omp: request.ompPath }), ...(request.profile === undefined ? {} : { profile: request.profile }) })
  return { action: 'relaunch', appPath, configPath }
}

/** The request from stdin, never holding more than `limit` bytes plus the one that proves an overflow: reading stops at once with a
 * typed error instead of buffering whatever a caller sends. @param {number} [limit] */
function readRequest(limit = maxInputBytes) {
  const buffer = Buffer.allocUnsafe(limit + 1)
  let length = 0
  for (;;) {
    const read = readSync(0, buffer, length, buffer.length - length, null)
    if (read === 0) return buffer.subarray(0, length)
    length += read
    if (length > limit) throw invalid('Request is too large')
  }
}
/** Translate a command's result or failure into the stdout payload and exit code. @param {string} command @param {()=>Record<string,unknown>} action */
export function respond(command, action) {
  try {
    return { exitCode: 0, payload: { ok: true, command, ...action() } }
  } catch (error) {
    return { exitCode: 1, payload: { ok: false, command, error: { code: error instanceof InstallError || (error instanceof UpdateError && error.code === 'ownership-mismatch') ? error.code : 'io-error', message: error instanceof Error ? error.message : String(error) } } }
  }
}

if (import.meta.main) {
  const command = process.argv[2] ?? ''
  const { exitCode, payload } = respond(command, () => {
    const raw = readRequest()
    let request
    try { request = JSON.parse(raw.toString('utf8')) } catch { throw invalid('Request is not valid JSON') }
    return execute(command, request)
  })
  process.stdout.write(`${JSON.stringify(payload)}\n`)
  process.exitCode = exitCode
}
