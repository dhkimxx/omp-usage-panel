import { createHash, randomUUID } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { accessSync, constants, cpSync, existsSync, linkSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import path from 'node:path'
import { defaultConfig, migrateSwiftbarVariables, parseConfig } from './config.mjs'
import { buildApp, sourceRoot } from './build.mjs'

/** @typedef {{home?:string, stateDir?:string, appPath?:string, agentPath?:string, configPath?:string, sourceRoot?:string, swiftbarPluginDir?:string, node?:string, run?:(file:string,args:string[])=>string, sleep?:(milliseconds:number)=>void, env?:NodeJS.ProcessEnv, dryRun?:boolean, platform?:string, uid?:number, build?:(options:{outputDirectory:string})=>string}} InstallOptions */
/** @typedef {{version:1|2, appPath:string, agentPath:string, appHash:string, agentHash:string}} InstallState */
/** @typedef {ReturnType<typeof context>} Context */

const label = 'com.dhkim.omp-usage-panel'
/** @param {string} file @param {string[]} args */
const runCommand = (file, args) => execFileSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
/** @param {number} milliseconds */
function sleep(milliseconds) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds) }
/** @param {string} file */
function present(file) { try { lstatSync(file); return true } catch (e) { if (/** @type {NodeJS.ErrnoException} */ (e).code === 'ENOENT') return false; throw e } }
/** @param {string} file */
function executable(file) { try { accessSync(file, constants.X_OK); return true } catch { return false } }
/** @param {string} file */
function canonical(file) { let p = path.resolve(file), parts = []; while (!existsSync(p)) { parts.unshift(path.basename(p)); const next = path.dirname(p); if (next === p) break; p = next } return path.join(realpathSync(p), ...parts) }
/** @param {string} file @param {string} root */
function within(file, root) { return file === root || file.startsWith(root + path.sep) }
/** @param {string|Buffer} data */
function digest(data) { return createHash('sha256').update(data).digest('hex') }
/** @param {string} root */
function treeHash(root) {
  const hash = createHash('sha256')
  /** @param {string} file @param {string} rel */
  function visit(file, rel) {
    const stat = lstatSync(file)
    if (stat.isSymbolicLink()) throw new Error(`Unexpected symlink in app: ${file}`)
    if (stat.isDirectory()) { hash.update(`d\0${rel}\0`); for (const name of readdirSync(file).sort()) visit(path.join(file, name), path.join(rel, name)); return }
    if (!stat.isFile()) throw new Error(`Unexpected app entry: ${file}`)
    const data = readFileSync(file); hash.update(`f\0${rel}\0${stat.mode & 0o777}\0${data.length}\0`).update(data)
  }
  visit(root, ''); return hash.digest('hex')
}
/** @param {string} file @param {string} content @param {number} [mode] */
function atomic(file, content, mode = 0o600) {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 })
  const temp = path.join(path.dirname(file), `.omp-${randomUUID()}`)
  try { writeFileSync(temp, content, { mode, flag: 'wx' }); renameSync(temp, file) } finally { rmSync(temp, { force: true }) }
}
/** @param {string} file @returns {InstallState|null} */
function load(file) {
  if (!present(file)) return null
  const value = JSON.parse(readFileSync(file, 'utf8'))
  if (!value || ![1, 2].includes(value.version) || typeof value.appPath !== 'string' || typeof value.agentPath !== 'string' ||
      !/^[a-f0-9]{64}$/.test(value.appHash) || !/^[a-f0-9]{64}$/.test(value.agentHash) ||
      (value.version === 1 && !Array.isArray(value.snapshots))) throw new Error('Invalid installation manifest; refusing changes')
  return value
}
/** Retain the original provider migration record byte-for-byte, without replacing an existing backup.
 * @param {string} file @param {InstallState|null} state */
function preserveLegacyState(file, state) {
  if (state?.version !== 1) return
  const backup = path.join(path.dirname(file), 'install-v1.json'), content = readFileSync(file)
  const temp = path.join(path.dirname(file), `.omp-${randomUUID()}`)
  try {
    writeFileSync(temp, content, { mode: 0o600, flag: 'wx' })
    try { linkSync(temp, backup) }
    catch (error) {
      if (/** @type {NodeJS.ErrnoException} */ (error).code !== 'EEXIST') throw error
      if (!lstatSync(backup).isFile() || !readFileSync(backup).equals(content)) throw new Error(`Unrelated legacy migration backup at ${backup}; refusing replacement`)
    }
  } finally { rmSync(temp, { force: true }) }
}
/** @param {string} s */
function xml(s) { return s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;') }
/** @param {string} app @param {string} config */
function plist(app, config) { return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>Label</key><string>${label}</string><key>ProgramArguments</key><array><string>${xml(path.join(app, 'Contents/MacOS/OMPUsagePanel'))}</string><string>--config</string><string>${xml(config)}</string></array><key>RunAtLoad</key><true/></dict></plist>\n` }
/** @param {InstallOptions} options */
function context(options) {
  const home = path.resolve(options.home || homedir()), stateDir = path.resolve(options.stateDir || path.join(home, 'Library/Application Support/omp-usage-panel'))
  return { home, stateDir, app: path.resolve(options.appPath || path.join(home, 'Applications/OMP Usage.app')), agent: path.resolve(options.agentPath || path.join(home, `Library/LaunchAgents/${label}.plist`)), config: path.resolve(options.configPath || path.join(stateDir, 'config.json')), source: path.resolve(options.sourceRoot || sourceRoot), run: options.run || runCommand, sleep: options.sleep || sleep, env: options.env || process.env, dry: !!options.dryRun, platform: options.platform || process.platform, uid: options.uid ?? process.getuid?.() ?? -1 }
}
/** @param {Context} c @param {()=>string[]} action */
function lock(c, action) {
  if (c.dry) return action()
  mkdirSync(c.stateDir, { recursive: true, mode: 0o700 })
  const lock = path.join(c.stateDir, 'lock')
  try { mkdirSync(lock, { mode: 0o700 }) } catch (e) { if (/** @type {NodeJS.ErrnoException} */ (e).code === 'EEXIST') throw new Error(`Installer lock exists: ${lock}`); throw e }
  try { return action() } finally { rmSync(lock, { recursive: true }) }
}
/** @param {Context} c @param {InstallState|null} state */
function checkOwned(c, state) {
  if (state && (state.appPath !== c.app || state.agentPath !== c.agent)) throw new Error('Tracked installation uses different app or LaunchAgent paths')
  if (present(c.app) && (!state || treeHash(c.app) !== state.appHash)) throw new Error(`Foreign or modified app at ${c.app}; refusing replacement`)
  if (present(c.agent) && (!state || !lstatSync(c.agent).isFile() || digest(readFileSync(c.agent)) !== state.agentHash)) throw new Error(`Foreign or modified LaunchAgent at ${c.agent}; refusing replacement`)
}
/** @param {NodeJS.ProcessEnv} env @param {string} home */
function resolveOmp(env, home) {
  const choices = env.OMP_BIN ? [path.resolve(env.OMP_BIN)] : [path.join(home, '.local/bin/omp'), ...(env.PATH || '').split(path.delimiter).filter(Boolean).map(p => path.resolve(p, 'omp'))]
  const found = choices.find(p => executable(p) && (env.OMP_BIN || !realpathSync(p).split(path.sep).includes('node_modules')))
  if (!found) throw new Error('Cannot find executable omp; set OMP_BIN')
  return found
}
/** @param {Context} c @param {string} pluginDir */
function variables(c, pluginDir) {
  /** @type {Record<string,string>} */
  const result = {}
  const wanted = new Set(['OMP_BIN', 'OMP_PROFILE', 'OMP_USAGE_PROVIDERS', 'OMP_USAGE_LABELS', 'OMP_USAGE_METRICS', 'OMP_USAGE_REFRESH_MINUTES', 'OMP_USAGE_WARN_PERCENT', 'OMP_USAGE_CRITICAL_PERCENT', 'OMP_USAGE_SHOW_PACE'])
  /** @param {unknown} value */
  function extract(value) {
    if (!value || typeof value !== 'object') return
    for (const [key, entry] of Object.entries(value)) {
      if (wanted.has(key)) { if (typeof entry !== 'string' && typeof entry !== 'number' && typeof entry !== 'boolean') throw new Error(`Invalid SwiftBar variable ${key}`); result[key] = String(entry) }
      else if (entry && typeof entry === 'object') extract(entry)
    }
  }
  const pref = path.join(c.home, 'Library/Preferences/com.ameba.SwiftBar.plist')
  if (present(pref)) { let value; try { value = JSON.parse(c.run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', pref])) } catch { throw new Error('Cannot read SwiftBar preferences for migration') }; extract(value) }
  for (const name of ['orca-usage.1m.vars.json', 'omp-usage.1m.vars.json']) { const file = path.join(pluginDir, name); if (present(file)) { let value; try { value = JSON.parse(readFileSync(file, 'utf8')) } catch { throw new Error(`Cannot read SwiftBar variables: ${file}`) }; extract(value) } }
  return result
}
/** @param {Context} c */
function isRunning(c) { try { c.run('/bin/launchctl', ['print', `gui/${c.uid}/${label}`]); return true } catch { return false } }
/** Verify the loaded launchd job before ever stopping it. @param {Context} c @param {InstallState|null} state */
function ownedJobRunning(c, state) {
  let description
  try { description = c.run('/bin/launchctl', ['print', `gui/${c.uid}/${label}`]) } catch { return false }
  const jobPath = /^\s*path = (.+)$/m.exec(description)?.[1]
  const program = /^\s*program = (.+)$/m.exec(description)?.[1]
  const argumentsBlock = /^\s*arguments = \{\s*\n([\s\S]*?)^\s*\}/m.exec(description)?.[1]
  const args = argumentsBlock?.split('\n').map(line => line.trim()).filter(Boolean)
  const expectedProgram = path.join(c.app, 'Contents/MacOS/OMPUsagePanel')
  if (!state || !present(c.agent) || !present(c.app) || jobPath !== c.agent || program !== expectedProgram ||
      !args || args.length !== 3 || args[0] !== expectedProgram || args[1] !== '--config' || args[2] !== c.config) {
    throw new Error(`Foreign or unverified loaded LaunchAgent ${label}; refusing to stop it`)
  }
  checkOwned(c, state)
  return true
}
/** @param {Context} c */
function start(c) { c.run('/bin/launchctl', ['bootstrap', `gui/${c.uid}`, c.agent]) }
/** @param {Context} c */
function bootout(c) { c.run('/bin/launchctl', ['bootout', `gui/${c.uid}/${label}`]) }
/** @param {Context} c */
function waitForStop(c) {
  for (let attempt = 0; attempt < 100; attempt++) {
    try { c.run('/bin/launchctl', ['print', `gui/${c.uid}/${label}`]) }
    catch (error) {
      const failure = /** @type {{status?:number, stderr?:string|Buffer}} */ (error)
      if (failure?.status === 113 && String(failure.stderr || '').includes('Could not find service')) return
      throw error
    }
    c.sleep(100)
  }
  throw new Error(`Timed out waiting for LaunchAgent ${label} to leave launchd after bootout`)
}
/** @param {Context} c */
function stop(c) { bootout(c); waitForStop(c) }
/** @param {Context} c @param {string} node @param {string} omp */
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
  const c = context(options)
  if (c.platform !== 'darwin') throw new Error('Installation requires macOS')
  return lock(c, () => {
    const stateFile = path.join(c.stateDir, 'install.json'), state = load(stateFile)
    checkOwned(c, state)
    ownedJobRunning(c, state)
    const node = path.resolve(options.node || process.execPath)
    let config
    if (present(c.config)) config = parseConfig(JSON.parse(readFileSync(c.config, 'utf8')))
    else {
      const pluginDir = path.resolve(options.swiftbarPluginDir || (() => {
        try { return c.run('/usr/bin/defaults', ['read', 'com.ameba.SwiftBar', 'PluginDirectory']).trim() || path.join(c.home, '.config/swiftbar/plugins') }
        catch (error) {
          if (!String(error).includes('does not exist')) throw new Error('Cannot read SwiftBar plugin directory')
          return path.join(c.home, '.config/swiftbar/plugins')
        }
      })())
      const vars = variables(c, pluginDir)
      const omp = resolveOmp({ ...c.env, ...(vars.OMP_BIN ? { OMP_BIN: vars.OMP_BIN } : {}) }, c.home)
      config = migrateSwiftbarVariables(vars, defaultConfig({ nodePath: node, ompPath: omp, profile: c.env.OMP_PROFILE || 'default' }))
    }
    validatePaths(c, config.nodePath, config.ompPath)
    const content = plist(c.app, c.config)
    const actions = [`App: ${c.app}`, `Config: ${c.config}`, `LaunchAgent: ${c.agent}`, `Node: ${config.nodePath}`, `omp: ${config.ompPath}`]
    if (c.dry) return actions
    preserveLegacyState(stateFile, state)
    const workspace = path.join(tmpdir(), `omp-panel-${randomUUID()}`), staged = path.join(path.dirname(c.app), `.omp-app-${randomUUID()}`), backup = path.join(path.dirname(c.app), `.omp-backup-${randomUUID()}`), agentBackup = path.join(path.dirname(c.agent), `.omp-agent-${randomUUID()}`)
    let appMoved = false, oldAppMoved = false, agentMoved = false, oldAgentMoved = false, startAttempted = false, stopped = false, configCreated = false
    try {
      mkdirSync(workspace, { recursive: true, mode: 0o700 })
      const built = (options.build || buildApp)({ outputDirectory: workspace })
      mkdirSync(path.dirname(c.app), { recursive: true }); mkdirSync(path.dirname(c.agent), { recursive: true })
      cpSync(built, staged, { recursive: true, errorOnExist: true, force: false })
      const appHash = treeHash(staged)
      if (!present(c.config)) { atomic(c.config, JSON.stringify(config, null, 2) + '\n'); configCreated = true }
      checkOwned(c, state)
      if (ownedJobRunning(c, state)) { bootout(c); stopped = true; waitForStop(c) }
      if (present(c.app)) { renameSync(c.app, backup); oldAppMoved = true }
      renameSync(staged, c.app); appMoved = true
      if (present(c.agent)) { renameSync(c.agent, agentBackup); oldAgentMoved = true }
      atomic(c.agent, content, 0o644); agentMoved = true
      startAttempted = true; start(c)
      const next = { version: 2, appPath: c.app, agentPath: c.agent, appHash, agentHash: digest(content) }
      atomic(stateFile, JSON.stringify(next, null, 2) + '\n')
    } catch (error) {
      /** @type {string[]} */
      const failures = []
      /** @param {()=>void} fn */
      const attempt = fn => { try { fn() } catch (e) { failures.push(String(e)) } }
      if (startAttempted && isRunning(c)) attempt(() => stop(c))
      if (agentMoved) attempt(() => rmSync(c.agent)); if (oldAgentMoved) attempt(() => renameSync(agentBackup, c.agent))
      if (appMoved) attempt(() => rmSync(c.app, { recursive: true })); if (oldAppMoved) attempt(() => renameSync(backup, c.app))
      if (configCreated) attempt(() => rmSync(c.config))
      if (stopped && present(c.agent)) attempt(() => { waitForStop(c); start(c) })
      if (failures.length) throw new Error(`Installation failed: ${String(error)}; rollback incomplete: ${failures.join('; ')}`)
      throw error
    } finally { rmSync(staged, { recursive: true, force: true }); rmSync(workspace, { recursive: true, force: true }) }
    if (oldAppMoved) rmSync(backup, { recursive: true }); if (oldAgentMoved) rmSync(agentBackup)
    return actions
  })
}
/** @param {InstallOptions} [options] */
export function uninstall(options = {}) {
  const c = context(options)
  if (c.platform !== 'darwin') throw new Error('Uninstallation requires macOS')
  return lock(c, () => {
    const file = path.join(c.stateDir, 'install.json'), state = load(file)
    if (!state) return [`No tracked installation at ${file}`]
    checkOwned(c, state)
    const running = ownedJobRunning(c, state)
    const actions = [`Remove owned LaunchAgent ${c.agent}`, `Remove owned app ${c.app}`, `Preserve config and legacy migration records in ${c.stateDir}`]
    if (c.dry) return actions
    if (running) stop(c)
    if (present(c.agent)) rmSync(c.agent)
    if (present(c.app)) rmSync(c.app, { recursive: true })
    return actions
  })
}
