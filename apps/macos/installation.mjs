import { randomUUID } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { cpSync, lstatSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { defaultConfig, parseConfig } from './config.mjs'
import { buildApp, sourceRoot } from './build.mjs'
import { InstallError, appTreeHash, atomic, bootoutJob, canonical, checkAgentLaunch, checkOwned, context, createExclusive, digest, executable, jobRunning, kickstartJob, label, loadManifest, loadedJob, ownedJob, ownedJobRunning, plist, preserveLegacyState, present, sameEntries, scanTree, startJob, stopJob, syncTree, waitForStop, withLock, within } from './ownership.mjs'
import { discardPendingUpdate, reconcileUpdate, removeUpdaterArea } from './update-transaction.mjs'

/** @typedef {import('./ownership.mjs').InstallState} InstallState */
/** `prebuilt` installs an already built app (the one the setup helper ships in) instead of building from the source checkout: `app` is the
 * physical path of that bundle. When it is the very app at the destination it is adopted in place and never copied.
 * @typedef {import('./ownership.mjs').OwnershipOptions & {sourceRoot?:string, node?:string, omp?:string, profile?:string, build?:(options:{outputDirectory:string})=>string, prebuilt?:{app:string}, lockWaitMs?:number}} InstallOptions */
/** @typedef {import('./ownership.mjs').OwnershipOptions & {launch:{app:string, hostPid:number}, lockWaitMs?:number}} LaunchOptions */
/** @typedef {{action:'relaunch'|'activate'|'continue', pid?:number}} LaunchResult */
/** @typedef {ReturnType<typeof installContext>} InstallContext */

const bundleIdentity = new RegExp(`<key>\\s*CFBundleIdentifier\\s*</key>\\s*<string>\\s*${label.replaceAll('.', '\\.')}\\s*</string>`)

/** @param {unknown} error */
function describe(error) { return error instanceof Error ? error.message : String(error) }
/** @param {InstallOptions} options */
function installContext(options) {
  return { ...context(options), source: path.resolve(options.prebuilt?.app ?? options.sourceRoot ?? sourceRoot), sourceKind: options.prebuilt ? 'source app' : 'source checkout', lockWaitMs: options.lockWaitMs ?? 0 }
}
/** @param {string} file @returns {InstallState|null} */
function readState(file) {
  try { return loadManifest(file) } catch (error) { throw new InstallError('manifest-invalid', describe(error), error) }
}
/** A pending Sparkle update is a legitimate owner of the app on disk, never a foreign one; a live one is never overridden. The one
 * typed refusal that already belongs to the recovery contract, a destination differing from the recorded paths, keeps its own code.
 * @param {import('./ownership.mjs').Context} c @param {InstallState|null} state */
function reconcile(c, state) {
  try { return reconcileUpdate(c, state) } catch (error) {
    if (error instanceof Error && /** @type {{code?:unknown}} */ (error).code === 'ownership-mismatch') throw error
    throw new InstallError('update-in-progress', describe(error), error)
  }
}
/** @param {NodeJS.ProcessEnv} env @param {string} home */
function resolveOmp(env, home) {
  const choices = env.OMP_BIN ? [path.resolve(env.OMP_BIN)] : [path.join(home, '.local/bin/omp'), ...(env.PATH || '').split(path.delimiter).filter(Boolean).map(p => path.resolve(p, 'omp'))]
  const found = choices.find(p => executable(p) && (env.OMP_BIN || !realpathSync(p).split(path.sep).includes('node_modules')))
  if (!found) throw new InstallError('omp-unavailable', 'Cannot find executable omp; set OMP_BIN')
  return found
}
/** @param {string} file */
function executableFile(file) { try { return executable(file) && statSync(file).isFile() } catch { return false } }
/** @param {string} profile */
function validProfile(profile) {
  if (profile.trim().length === 0 || /[\u0000-\u001f\u007f]/.test(profile)) throw new InstallError('invalid-profile', 'The profile name must be non-blank text without control characters')
  return profile
}
/** The configuration a first install creates: the caller's explicit choices, else the same discovery `macos:install` always used.
 * @param {InstallContext} c @param {InstallOptions} options */
function initialConfig(c, options) {
  const nodePath = path.resolve(options.node || process.execPath)
  const ompPath = options.omp !== undefined ? path.resolve(options.omp) : resolveOmp(c.env, c.home)
  return defaultConfig({ nodePath, ompPath, profile: validProfile(options.profile !== undefined ? options.profile : c.env.OMP_PROFILE || 'default') })
}
/** An existing configuration is authoritative and is never rewritten: unreadable or invalid files are a controlled refusal, not a reset.
 * @param {InstallContext|import('./ownership.mjs').Context} c */
function readConfig(c) {
  try {
    if (!statSync(c.config).isFile()) throw new Error('it is not a regular file')
    return parseConfig(JSON.parse(readFileSync(c.config, 'utf8')))
  } catch (error) { throw new InstallError('config-invalid', `The configuration at ${c.config} is missing, unreadable or invalid and was left unchanged: ${describe(error)}`, error) }
}
/** `checkOmp:false` leaves the omp path of an existing configuration alone: that configuration is authoritative, setup needs only a
 * usable Node to start the app, and a missing omp is the collector's runtime problem, never a reason to rewrite or refuse the file.
 * @param {InstallContext} c @param {string} node @param {string} omp @param {{inPlace:boolean, fromConfig:boolean, checkOmp:boolean}} where */
function validatePaths(c, node, omp, where) {
  const origin = where.fromConfig ? ' (from the existing configuration)' : ''
  /** @type {[string,string,string][]} */
  const runtimes = [['Node', 'node-unavailable', node]]
  if (where.checkOmp) runtimes.push(['omp', 'omp-unavailable', omp])
  for (const [name, code, file] of runtimes) {
    if (!path.isAbsolute(file) || !executableFile(file)) throw new InstallError(code, `${name} is not an absolute executable: ${file}${origin}`)
    if (within(canonical(file), canonical(c.source))) throw new InstallError(code, `${name} must be outside the ${c.sourceKind}`)
  }
  let reported
  try { reported = c.run(node, ['--version']).trim() } catch (error) { throw new InstallError('node-unavailable', `Node could not be run: ${node}${origin}`, error) }
  const version = /^v(\d+)\.(\d+)\.(\d+)/.exec(reported)
  if (!version || Number(version[1]) < 22 || (Number(version[1]) === 22 && Number(version[2]) < 18)) throw new InstallError('node-unavailable', `Node 22.18.0 or newer is required${origin}`)
  for (const file of [c.app, c.stateDir, c.agent, c.config]) {
    // An app adopted in place is, by definition, where the app is installed.
    if (file === c.app && where.inPlace) continue
    if (within(canonical(file), canonical(c.source))) throw new InstallError('invalid-source', `Install paths must be outside the ${c.sourceKind}`)
  }
}
/** A prebuilt install never terminates a running app: the user quits it and retries. A loaded job without a process is idle and is
 * replaced like any other owned job.
 * @param {InstallContext} c @param {InstallState|null} state */
function loadedIdleJob(c, state) {
  const job = ownedJob(c, state)
  if (job?.pid !== undefined) throw new InstallError('running', `OMP Usage is still running (process ${job.pid}); save your work, quit it, then try again`)
  return job
}
/** @param {InstallContext} c @param {string} app */
function verifySignature(c, app) {
  try { c.run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]) } catch (error) { throw new InstallError('invalid-source', `The code signature of ${app} is invalid: ${describe(error)}`, error) }
}
/** Validate the prebuilt app that is about to be installed: a real OMP Usage bundle whose whole tree the ownership scanner accepts. A
 * copy source (a download, a disk image) need not belong to this user; an app adopted in place becomes the managed app, so the very
 * path that will be registered (never a link to some other copy) is inspected and must belong to this user.
 * @param {InstallContext} c @param {string} source @param {boolean} inPlace */
function inspectSource(c, source, inPlace) {
  const app = inPlace ? c.app : source
  /** @param {string} message @param {unknown} [cause] */
  const invalid = (message, cause) => new InstallError('invalid-source', message, cause)
  /** @type {import('node:fs').Stats} */
  let stat
  try { stat = lstatSync(app) } catch (error) { throw invalid(`The source app does not exist: ${app}`, error) }
  if (!stat.isDirectory() || !app.endsWith('.app')) throw invalid(`The source is not an app bundle: ${app}`)
  if (!executableFile(path.join(app, 'Contents/MacOS/OMPUsagePanel'))) throw invalid(`The source app has no OMPUsagePanel executable: ${app}`)
  let info
  try { info = readFileSync(path.join(app, 'Contents/Info.plist'), 'utf8') } catch (error) { throw invalid(`The source app has no readable Info.plist: ${app}`, error) }
  if (!bundleIdentity.test(info)) throw invalid(`The source app is not OMP Usage: ${app}`)
  try { return scanTree(app, inPlace ? { uid: c.owner } : {}) } catch (error) { throw invalid(`The source app cannot be verified: ${describe(error)}`, error) }
}
/** Copy an app the way Finder does: extended attributes (the quarantine flag included), resource forks, ACLs and framework symlinks
 * verbatim. DITTONORSRC is removed from the environment because it silently strips all of that.
 * @param {string} source @param {string} destination */
function copyApp(source, destination) {
  const env = { ...process.env }
  delete env.DITTONORSRC
  try { execFileSync('/usr/bin/ditto', ['--rsrc', '--extattr', '--qtn', source, destination], { env, encoding: 'utf8', stdio: ['ignore', 'ignore', 'pipe'] }) } catch (error) { throw new InstallError('copy-failed', `The app could not be copied: ${describe(error)}`, error) }
}
/** The copy must be the source, entry for entry and byte for byte, and its signature must verify; only then may it be installed.
 * @param {InstallContext} c @param {ReturnType<typeof scanTree>} source @param {string} staged */
function verifyCopy(c, source, staged) {
  let copy
  try { copy = scanTree(staged, { uid: c.owner }) } catch (error) { throw new InstallError('invalid-source', `The copied app cannot be verified: ${describe(error)}`, error) }
  if (copy.hash !== source.hash || !sameEntries(source.entries, copy.entries)) throw new InstallError('invalid-source', 'The copied app differs from the source app; nothing was installed')
  verifySignature(c, staged)
  return copy.hash
}

/** @param {InstallOptions} [options] @returns {string[]} */
export function install(options = {}) {
  const c = installContext(options)
  if (c.platform !== 'darwin') throw new InstallError('unsupported', 'Installation requires macOS')
  return withLock(c, () => {
    const stateFile = path.join(c.stateDir, 'install.json'), stored = readState(stateFile)
    const { state, pending, manifest } = reconcile(c, stored)
    // An update that already replaced the app but is not yet acknowledged still owns it: its receipt and verified backup are the only way
    // back. Setup, which would discard them, never supersedes it (a source install deliberately does).
    if (options.prebuilt && pending) throw new InstallError('update-in-progress', 'An update replaced the app and is waiting for the new version to confirm startup; open the installed app so it can finish, then try again')
    const prebuiltApp = options.prebuilt?.app
    // Source and destination are one app when the running copy is installed where it already sits: it is adopted, never copied over itself.
    const inPlace = prebuiltApp !== undefined && canonical(prebuiltApp) === canonical(c.app)
    checkOwned(c, state, { adopting: inPlace && state === null })
    // The job's identity is verified, and a running prebuilt target refused, before anything is built, copied or created.
    if (prebuiltApp !== undefined) loadedIdleJob(c, state); else ownedJob(c, state)
    const prebuilt = prebuiltApp === undefined ? null : { app: prebuiltApp, scan: inspectSource(c, prebuiltApp, inPlace) }
    const configExists = present(c.config)
    const config = configExists ? readConfig(c) : initialConfig(c, options)
    validatePaths(c, config.nodePath, config.ompPath, { inPlace, fromConfig: configExists, checkOmp: !configExists || prebuilt === null })
    const content = plist(c.app, c.config, c.home)
    const actions = [`App: ${c.app}`, `Config: ${c.config}`, `LaunchAgent: ${c.agent}`, `Node: ${config.nodePath}`, `omp: ${config.ompPath}`]
    if (c.dry) return actions
    preserveLegacyState(stateFile, manifest)
    // The staged copy keeps the .app extension: codesign identifies bundles by it, and it is what gets verified before it is installed.
    const workspace = path.join(tmpdir(), `omp-panel-${randomUUID()}`), staged = path.join(path.dirname(c.app), `.omp-app-${randomUUID()}.app`), backup = path.join(path.dirname(c.app), `.omp-backup-${randomUUID()}`), agentBackup = path.join(path.dirname(c.agent), `.omp-agent-${randomUUID()}`)
    let appMoved = false, oldAppMoved = false, agentMoved = false, oldAgentMoved = false, startAttempted = false, stopped = false, configCreated = false
    try {
      const prepareParents = () => { mkdirSync(path.dirname(c.app), { recursive: true }); mkdirSync(path.dirname(c.agent), { recursive: true }) }
      /** @type {string} */
      let appHash
      if (prebuilt) {
        prepareParents()
        if (inPlace) {
          verifySignature(c, c.app)
          appHash = prebuilt.scan.hash
        } else {
          copyApp(prebuilt.app, staged)
          appHash = verifyCopy(c, prebuilt.scan, staged)
          syncTree(staged)
        }
      } else {
        mkdirSync(workspace, { recursive: true, mode: 0o700 })
        const built = (options.build || buildApp)({ outputDirectory: workspace })
        prepareParents()
        // Frameworks inside the app are relative symlinks; they must be copied verbatim, never rewritten to absolute paths.
        cpSync(built, staged, { recursive: true, verbatimSymlinks: true, errorOnExist: true, force: false })
        syncTree(staged)
        appHash = appTreeHash(staged, { uid: c.owner })
      }
      if (!configExists) {
        if (!createExclusive(c.config, JSON.stringify(config, null, 2) + '\n')) throw new InstallError('config-changed', `A configuration appeared at ${c.config} during setup and was left untouched; try again`)
        configCreated = true
      }
      checkOwned(c, state, { adopting: inPlace && state === null })
      const job = prebuilt ? loadedIdleJob(c, state) : ownedJob(c, state)
      if (job) { bootoutJob(c); stopped = true; waitForStop(c) }
      if (!inPlace) {
        if (present(c.app)) { renameSync(c.app, backup); oldAppMoved = true }
        renameSync(staged, c.app); appMoved = true
      }
      if (present(c.agent)) { renameSync(c.agent, agentBackup); oldAgentMoved = true }
      atomic(c.agent, content, 0o644); agentMoved = true
      // The adopted app starts as a job: it must still be exactly the tree that was verified.
      if (inPlace && appTreeHash(c.app, { uid: c.owner }) !== appHash) throw new InstallError('invalid-source', 'The app changed while it was being set up; nothing was started')
      startAttempted = true; startJob(c)
      const next = { version: 2, appPath: c.app, agentPath: c.agent, appHash, agentHash: digest(content) }
      atomic(stateFile, JSON.stringify(next, null, 2) + '\n')
    } catch (error) {
      /** @type {string[]} */
      const failures = []
      /** @param {()=>void} fn */
      const attempt = fn => { try { fn() } catch (e) { failures.push(String(e)) } }
      // The replacement may be running: files are restored only after its shutdown is verified. An inspection or stop failure
      // preserves both apps (and the previous LaunchAgent) untouched for recovery.
      if (startAttempted) {
        try { if (jobRunning(c)) stopJob(c) } catch (e) {
          throw new InstallError('rollback-incomplete', `Installation failed: ${String(error)}; rollback incomplete: replacement shutdown could not be verified (${String(e)}); no live path was modified. The previous app is preserved at ${backup} and the previous LaunchAgent at ${agentBackup}`, error)
        }
      }
      if (agentMoved) attempt(() => rmSync(c.agent)); if (oldAgentMoved) attempt(() => renameSync(agentBackup, c.agent))
      if (appMoved) attempt(() => rmSync(c.app, { recursive: true })); if (oldAppMoved) attempt(() => renameSync(backup, c.app))
      if (configCreated) attempt(() => rmSync(c.config))
      if (stopped && present(c.agent)) attempt(() => { waitForStop(c); startJob(c) })
      if (failures.length) throw new InstallError('rollback-incomplete', `Installation failed: ${String(error)}; rollback incomplete: ${failures.join('; ')}`, error)
      throw error instanceof InstallError ? error : new InstallError('install-failed', describe(error), error)
    } finally { rmSync(staged, { recursive: true, force: true }); rmSync(workspace, { recursive: true, force: true }) }
    if (oldAppMoved) rmSync(backup, { recursive: true }); if (oldAgentMoved) rmSync(agentBackup)
    // The new ownership record supersedes a pending update's receipt and backup.
    if (pending) discardPendingUpdate(c)
    return actions
  }, c.lockWaitMs)
}
/** Hand a Finder launch of the managed app over to its registered LaunchAgent job, which is the only process that may run the app.
 * The installation (record, app tree, LaunchAgent, loaded job and configuration) is verified exactly as an install would verify it
 * before anything is started, and no process is ever signalled: a running job is activated, an idle loaded job is kickstarted
 * (never with -k) and an unloaded one is bootstrapped.
 * @param {LaunchOptions} options @returns {LaunchResult} */
export function launchManaged(options) {
  const c = { ...context(options), lockWaitMs: options.lockWaitMs ?? 0 }
  if (c.platform !== 'darwin') throw new InstallError('unsupported', 'Launching requires macOS')
  return withLock(c, /** @returns {LaunchResult} */ () => {
    const stored = readState(path.join(c.stateDir, 'install.json'))
    if (!stored) throw new InstallError('not-managed', 'No managed OMP Usage installation is recorded for this account')
    if (canonical(options.launch.app) !== canonical(c.app)) throw new InstallError('not-managed', `This copy is not the managed installation at ${c.app}`)
    const { state, pending } = reconcile(c, stored)
    if (!state || pending) throw new InstallError('update-in-progress', 'An update is waiting for the new version to confirm startup')
    if (!present(c.app) || !present(c.agent)) throw new InstallError('not-managed', 'The managed app or its LaunchAgent is missing')
    checkOwned(c, state)
    checkAgentLaunch(c)
    readConfig(c)
    const job = loadedJob(c, state), running = job?.pid
    if (job && running !== undefined) return running === options.launch.hostPid ? { action: 'continue' } : { action: 'activate', pid: running }
    if (job) kickstartJob(c); else startJob(c)
    return { action: 'relaunch' }
  }, c.lockWaitMs)
}
/** @param {InstallOptions} [options] */
export function uninstall(options = {}) {
  const c = context(options)
  if (c.platform !== 'darwin') throw new InstallError('unsupported', 'Uninstallation requires macOS')
  return withLock(c, () => {
    const file = path.join(c.stateDir, 'install.json'), stored = readState(file)
    if (!stored) return [`No tracked installation at ${file}`]
    const { state } = reconcile(c, stored)
    checkOwned(c, state)
    const running = ownedJobRunning(c, state)
    const updater = path.join(c.stateDir, 'updater')
    const actions = [`Remove owned LaunchAgent ${c.agent}`, `Remove owned app ${c.app}`, `Preserve config and legacy migration records in ${c.stateDir}`, ...(present(updater) ? [`Remove updater helper copies and pending update state in ${updater}`] : [])]
    if (c.dry) return actions
    if (running) stopJob(c)
    if (present(c.agent)) rmSync(c.agent)
    if (present(c.app)) rmSync(c.app, { recursive: true })
    removeUpdaterArea(c)
    return actions
  })
}
