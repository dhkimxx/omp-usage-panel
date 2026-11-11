import { randomUUID } from 'node:crypto'
import { cpSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { defaultConfig, parseConfig } from './config.mjs'
import { buildApp, sourceRoot } from './build.mjs'
import { appTreeHash, atomic, bootoutJob, canonical, checkOwned, context, digest, executable, jobRunning, loadManifest, ownedJobRunning, plist, preserveLegacyState, present, startJob, stopJob, syncTree, waitForStop, withLock, within } from './ownership.mjs'
import { discardPendingUpdate, reconcileUpdate, removeUpdaterArea } from './update-transaction.mjs'

/** @typedef {import('./ownership.mjs').OwnershipOptions & {sourceRoot?:string, node?:string, build?:(options:{outputDirectory:string})=>string}} InstallOptions */
/** @typedef {ReturnType<typeof installContext>} InstallContext */

/** @param {InstallOptions} options */
function installContext(options) { return { ...context(options), source: path.resolve(options.sourceRoot || sourceRoot) } }
/** @param {NodeJS.ProcessEnv} env @param {string} home */
function resolveOmp(env, home) {
  const choices = env.OMP_BIN ? [path.resolve(env.OMP_BIN)] : [path.join(home, '.local/bin/omp'), ...(env.PATH || '').split(path.delimiter).filter(Boolean).map(p => path.resolve(p, 'omp'))]
  const found = choices.find(p => executable(p) && (env.OMP_BIN || !realpathSync(p).split(path.sep).includes('node_modules')))
  if (!found) throw new Error('Cannot find executable omp; set OMP_BIN')
  return found
}
/** @param {InstallContext} c @param {string} node @param {string} omp */
function validatePaths(c, node, omp) {
  for (const [name, file] of [['Node', node], ['omp', omp]]) {
    if (!path.isAbsolute(file) || !executable(file)) throw new Error(`${name} is not an absolute executable: ${file}`)
    if (within(canonical(file), canonical(c.source))) throw new Error(`${name} must be outside the source checkout`)
  }
  const version = /^v(\d+)\.(\d+)\.(\d+)/.exec(c.run(node, ['--version']).trim())
  if (!version || Number(version[1]) < 22 || (Number(version[1]) === 22 && Number(version[2]) < 18)) throw new Error('Node 22.18.0 or newer is required')
  for (const file of [c.app, c.stateDir, c.agent, c.config]) if (within(canonical(file), canonical(c.source))) throw new Error('Install paths must be outside the source checkout')
}
/** @param {InstallOptions} [options] */
export function install(options = {}) {
  const c = installContext(options)
  if (c.platform !== 'darwin') throw new Error('Installation requires macOS')
  return withLock(c, () => {
    const stateFile = path.join(c.stateDir, 'install.json'), stored = loadManifest(stateFile)
    // A pending Sparkle update is a legitimate owner of the app on disk, never a foreign one.
    const { state, pending, manifest } = reconcileUpdate(c, stored)
    checkOwned(c, state)
    ownedJobRunning(c, state)
    const node = path.resolve(options.node || process.execPath)
    let config
    if (present(c.config)) config = parseConfig(JSON.parse(readFileSync(c.config, 'utf8')))
    else config = defaultConfig({ nodePath: node, ompPath: resolveOmp(c.env, c.home), profile: c.env.OMP_PROFILE || 'default' })
    validatePaths(c, config.nodePath, config.ompPath)
    const content = plist(c.app, c.config)
    const actions = [`App: ${c.app}`, `Config: ${c.config}`, `LaunchAgent: ${c.agent}`, `Node: ${config.nodePath}`, `omp: ${config.ompPath}`]
    if (c.dry) return actions
    preserveLegacyState(stateFile, manifest)
    const workspace = path.join(tmpdir(), `omp-panel-${randomUUID()}`), staged = path.join(path.dirname(c.app), `.omp-app-${randomUUID()}`), backup = path.join(path.dirname(c.app), `.omp-backup-${randomUUID()}`), agentBackup = path.join(path.dirname(c.agent), `.omp-agent-${randomUUID()}`)
    let appMoved = false, oldAppMoved = false, agentMoved = false, oldAgentMoved = false, startAttempted = false, stopped = false, configCreated = false
    try {
      mkdirSync(workspace, { recursive: true, mode: 0o700 })
      const built = (options.build || buildApp)({ outputDirectory: workspace })
      mkdirSync(path.dirname(c.app), { recursive: true }); mkdirSync(path.dirname(c.agent), { recursive: true })
      // Frameworks inside the app are relative symlinks; they must be copied verbatim, never rewritten to absolute paths.
      cpSync(built, staged, { recursive: true, verbatimSymlinks: true, errorOnExist: true, force: false })
      syncTree(staged)
      const appHash = appTreeHash(staged, { uid: c.owner })
      if (!present(c.config)) { atomic(c.config, JSON.stringify(config, null, 2) + '\n'); configCreated = true }
      checkOwned(c, state)
      if (ownedJobRunning(c, state)) { bootoutJob(c); stopped = true; waitForStop(c) }
      if (present(c.app)) { renameSync(c.app, backup); oldAppMoved = true }
      renameSync(staged, c.app); appMoved = true
      if (present(c.agent)) { renameSync(c.agent, agentBackup); oldAgentMoved = true }
      atomic(c.agent, content, 0o644); agentMoved = true
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
          throw new Error(`Installation failed: ${String(error)}; rollback incomplete: replacement shutdown could not be verified (${String(e)}); no live path was modified. The previous app is preserved at ${backup} and the previous LaunchAgent at ${agentBackup}`)
        }
      }
      if (agentMoved) attempt(() => rmSync(c.agent)); if (oldAgentMoved) attempt(() => renameSync(agentBackup, c.agent))
      if (appMoved) attempt(() => rmSync(c.app, { recursive: true })); if (oldAppMoved) attempt(() => renameSync(backup, c.app))
      if (configCreated) attempt(() => rmSync(c.config))
      if (stopped && present(c.agent)) attempt(() => { waitForStop(c); startJob(c) })
      if (failures.length) throw new Error(`Installation failed: ${String(error)}; rollback incomplete: ${failures.join('; ')}`)
      throw error
    } finally { rmSync(staged, { recursive: true, force: true }); rmSync(workspace, { recursive: true, force: true }) }
    if (oldAppMoved) rmSync(backup, { recursive: true }); if (oldAgentMoved) rmSync(agentBackup)
    // The new ownership record supersedes a pending update's receipt and backup.
    if (pending) discardPendingUpdate(c)
    return actions
  })
}
/** @param {InstallOptions} [options] */
export function uninstall(options = {}) {
  const c = context(options)
  if (c.platform !== 'darwin') throw new Error('Uninstallation requires macOS')
  return withLock(c, () => {
    const file = path.join(c.stateDir, 'install.json'), stored = loadManifest(file)
    if (!stored) return [`No tracked installation at ${file}`]
    const { state } = reconcileUpdate(c, stored)
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
