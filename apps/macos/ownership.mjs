import { createHash, randomUUID } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { accessSync, closeSync, constants, existsSync, fsyncSync, linkSync, lstatSync, mkdirSync, openSync, readFileSync, readdirSync, readlinkSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { DatabaseSync } from 'node:sqlite'
import path from 'node:path'

/** @typedef {{home?:string, stateDir?:string, appPath?:string, agentPath?:string, configPath?:string, run?:(file:string,args:string[])=>string, sleep?:(milliseconds:number)=>void, env?:NodeJS.ProcessEnv, dryRun?:boolean, platform?:string, uid?:number, owner?:number, alive?:(pid:number)=>boolean, processStart?:(pid:number)=>string|null, inspectProcess?:(pid:number)=>{uid:number, start:string, args:string}|null, now?:()=>number, pid?:number}} OwnershipOptions */
/** @typedef {{version:1|2, appPath:string, agentPath:string, appHash:string, agentHash:string}} InstallState */
/** @typedef {ReturnType<typeof context>} Context */
/** @typedef {{kind:'d'}|{kind:'f', mode:number, size:number, digest:string}|{kind:'l', type:'d'|'f', target:string}} TreeEntry */

export const label = 'com.dhkim.omp-usage-panel'
/** A failure the setup protocol reports by `code`. The message is human-readable and never contains credentials. */
export class InstallError extends Error {
  /** @param {string} code @param {string} message @param {unknown} [cause] */
  constructor(code, message, cause) { super(message, cause === undefined ? undefined : { cause }); this.name = 'InstallError'; this.code = code }
}
/** @param {string} file @param {string[]} args */
export const runCommand = (file, args) => execFileSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
/** @param {number} milliseconds */
export function sleep(milliseconds) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds) }
/** @param {string} file */
export function present(file) { try { lstatSync(file); return true } catch (e) { if (/** @type {NodeJS.ErrnoException} */ (e).code === 'ENOENT') return false; throw e } }
/** @param {string} file */
export function executable(file) { try { accessSync(file, constants.X_OK); return true } catch { return false } }
/** @param {string} file */
export function canonical(file) { let p = path.resolve(file), parts = []; while (!existsSync(p)) { parts.unshift(path.basename(p)); const next = path.dirname(p); if (next === p) break; p = next } return path.join(realpathSync(p), ...parts) }
/** @param {string} file @param {string} root */
export function within(file, root) { return file === root || file.startsWith(root + path.sep) }
/** @param {string|Buffer} data */
export function digest(data) { return createHash('sha256').update(data).digest('hex') }
/** @param {number} pid */
export function processAlive(pid) { try { process.kill(pid, 0); return true } catch (e) { return /** @type {NodeJS.ErrnoException} */ (e).code === 'EPERM' } }

/**
 * Hash an app tree and describe every entry without trusting symlinks.
 *
 * Directories and regular files keep the original hash records, so symlink-free apps and legacy ownership records stay valid.
 * A symlink must be relative and resolve, lexically and physically, to an entry inside the app; it is hashed by its link
 * target text and target type and is never followed or hashed twice. Symlink permission bits are deliberately not hashed:
 * they follow the creator's umask on macOS, the kernel ignores them, and archive extraction would otherwise change the hash.
 * @param {string} root @param {{uid?:number}} [options] `uid` rejects any entry owned by another user.
 * @returns {{hash:string, entries:Map<string,TreeEntry>}}
 */
export function scanTree(root, options = {}) {
  const { uid } = options
  const aggregate = createHash('sha256'), lexicalRoot = path.resolve(root), physicalRoot = realpathSync(lexicalRoot)
  /** @type {Map<string,TreeEntry>} */
  const entries = new Map()
  /** @param {string} file @param {string} rel */
  function visit(file, rel) {
    const stat = lstatSync(file)
    if (uid !== undefined && stat.uid !== uid) throw new Error(`App entry is owned by another user: ${file}`)
    if (stat.isSymbolicLink()) {
      if (rel === '') throw new Error(`Unexpected symlink in app: ${file}`)
      const target = readlinkSync(file)
      if (target === '' || path.isAbsolute(target)) throw new Error(`Symlink in app must be relative: ${file}`)
      const lexical = path.resolve(path.dirname(file), target)
      if (lexical === lexicalRoot || !within(lexical, lexicalRoot)) throw new Error(`Symlink escapes app: ${file}`)
      let physical
      try { physical = realpathSync(file) } catch { throw new Error(`Unresolvable symlink in app: ${file}`) }
      if (physical === physicalRoot || !within(physical, physicalRoot)) throw new Error(`Symlink escapes app: ${file}`)
      const resolved = statSync(file)
      if (!resolved.isDirectory() && !resolved.isFile()) throw new Error(`Unexpected symlink target in app: ${file}`)
      const type = resolved.isDirectory() ? 'd' : 'f'
      aggregate.update(`l\0${rel}\0${type}\0${target}\0`)
      entries.set(rel, { kind: 'l', type, target })
      return
    }
    if (stat.isDirectory()) {
      aggregate.update(`d\0${rel}\0`); entries.set(rel, { kind: 'd' })
      for (const name of readdirSync(file).sort()) visit(path.join(file, name), path.join(rel, name))
      return
    }
    if (!stat.isFile()) throw new Error(`Unexpected app entry: ${file}`)
    const data = readFileSync(file), mode = stat.mode & 0o777
    aggregate.update(`f\0${rel}\0${mode}\0${data.length}\0`).update(data)
    entries.set(rel, { kind: 'f', mode, size: data.length, digest: digest(data) })
  }
  visit(lexicalRoot, '')
  return { hash: aggregate.digest('hex'), entries }
}
/** Ownership tree hash shared by installer, updater and release publishing. @param {string} root @param {{uid?:number}} [options] */
export function appTreeHash(root, options = {}) { return scanTree(root, options).hash }
/** @param {string} root @param {number} owner @returns {string|null} */
export function safeTreeHash(root, owner) { try { return appTreeHash(root, { uid: owner }) } catch { return null } }
/** @param {TreeEntry} entry */
function describeEntry(entry) { return entry.kind === 'd' ? 'd' : entry.kind === 'f' ? `f:${entry.mode}:${entry.size}:${entry.digest}` : `l:${entry.type}:${entry.target}` }
/** @param {Map<string,TreeEntry>} left @param {Map<string,TreeEntry>} right */
export function sameEntries(left, right) {
  if (left.size !== right.size) return false
  for (const [rel, entry] of left) { const other = right.get(rel); if (!other || describeEntry(entry) !== describeEntry(other)) return false }
  return true
}
/** @param {string} directory */
export function syncDirectory(directory) { const fd = openSync(directory, 'r'); try { fsyncSync(fd) } finally { closeSync(fd) } }
/** Durable replacement: contents are fsynced before the rename, then the directory entry is fsynced.
 * @param {string} file @param {string|Buffer} content @param {number} [mode] */
export function atomic(file, content, mode = 0o600) {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 })
  const temp = path.join(path.dirname(file), `.omp-${randomUUID()}`)
  try {
    const fd = openSync(temp, 'wx', mode)
    try { writeFileSync(fd, content); fsyncSync(fd) } finally { closeSync(fd) }
    renameSync(temp, file); syncDirectory(path.dirname(file))
  } finally { rmSync(temp, { force: true }) }
}
/** Durably create `file` only when nothing exists there: it is linked into place, never renamed over an existing entry. Returns false
 * when something appeared at `file` first, in which case that entry is left untouched.
 * @param {string} file @param {string|Buffer} content @param {number} [mode] */
export function createExclusive(file, content, mode = 0o600) {
  mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 })
  const temp = path.join(path.dirname(file), `.omp-${randomUUID()}`)
  try {
    const fd = openSync(temp, 'wx', mode)
    try { writeFileSync(fd, content); fsyncSync(fd) } finally { closeSync(fd) }
    try { linkSync(temp, file) } catch (error) { if (/** @type {NodeJS.ErrnoException} */ (error).code === 'EEXIST') return false; throw error }
    syncDirectory(path.dirname(file)); return true
  } finally { rmSync(temp, { force: true }) }
}
/** Create or verify a real directory owned by `owner` and inaccessible to others. @param {string} directory @param {number} owner */
export function ensurePrivateDirectory(directory, owner) {
  mkdirSync(directory, { recursive: true, mode: 0o700 })
  const stat = lstatSync(directory)
  if (!stat.isDirectory() || stat.uid !== owner || (stat.mode & 0o077) !== 0) throw new Error(`Not a private directory owned by this user: ${directory}`)
}
/** Flush every regular file and directory beneath `root` (symlinks are covered by their directory), children before parents.
 * @param {string} root */
export function syncTree(root) {
  /** @param {string} file */
  const visit = file => {
    const stat = lstatSync(file)
    if (stat.isSymbolicLink()) return
    if (stat.isDirectory()) for (const name of readdirSync(file)) visit(path.join(file, name))
    const fd = openSync(file, 'r'); try { fsyncSync(fd) } finally { closeSync(fd) }
  }
  visit(root)
}
/** @param {string} file @returns {InstallState|null} */
export function loadManifest(file) {
  if (!present(file)) return null
  const value = JSON.parse(readFileSync(file, 'utf8'))
  if (!value || ![1, 2].includes(value.version) || typeof value.appPath !== 'string' || typeof value.agentPath !== 'string' ||
      !/^[a-f0-9]{64}$/.test(value.appHash) || !/^[a-f0-9]{64}$/.test(value.agentHash) ||
      (value.version === 1 && !Array.isArray(value.snapshots))) throw new Error('Invalid installation manifest; refusing changes')
  return value
}
/** Retain the original provider migration record byte-for-byte, without replacing an existing backup. The record's inode and its
 * directory are flushed before this returns, so a later manifest commit or backup deletion can never outlive it.
 * @param {string} file @param {InstallState|null} state */
export function preserveLegacyState(file, state) {
  if (state?.version !== 1) return
  const directory = path.dirname(file), backup = path.join(directory, 'install-v1.json'), content = readFileSync(file)
  const temp = path.join(directory, `.omp-${randomUUID()}`)
  try {
    const fd = openSync(temp, 'wx', 0o600)
    try { writeFileSync(fd, content); fsyncSync(fd) } finally { closeSync(fd) }
    try { linkSync(temp, backup) }
    catch (error) {
      if (/** @type {NodeJS.ErrnoException} */ (error).code !== 'EEXIST') throw error
      if (!lstatSync(backup).isFile() || !readFileSync(backup).equals(content)) throw new Error(`Unrelated legacy migration backup at ${backup}; refusing replacement`)
      const existing = openSync(backup, 'r'); try { fsyncSync(existing) } finally { closeSync(existing) }
    }
    syncDirectory(directory)
  } finally { rmSync(temp, { force: true }) }
}
/** @param {string} s */
function xml(s) { return s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;') }
/** The job pins the account home explicitly, so it never depends on what launchd would otherwise provide.
 * @param {string} app @param {string} config @param {string} home */
export function plist(app, config, home) { return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>Label</key><string>${label}</string><key>ProgramArguments</key><array><string>${xml(path.join(app, 'Contents/MacOS/OMPUsagePanel'))}</string><string>--config</string><string>${xml(config)}</string></array><key>EnvironmentVariables</key><dict><key>HOME</key><string>${xml(home)}</string></dict><key>RunAtLoad</key><true/></dict></plist>\n` }
/** @param {string} text */
function unxml(text) { return text.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&amp;', '&') }
/** ProgramArguments of a LaunchAgent, read from its bytes; null when the file has none. @param {string} text @returns {string[]|null} */
export function agentProgramArguments(text) {
  const block = /<key>ProgramArguments<\/key>\s*<array>([\s\S]*?)<\/array>/.exec(text)?.[1]
  return block === undefined ? null : [...block.matchAll(/<string>([\s\S]*?)<\/string>/g)].map(match => unxml(match[1] ?? ''))
}
/** The LaunchAgent file must launch exactly this app with exactly this configuration, whatever generation of installer wrote it.
 * @param {Context} c */
export function checkAgentLaunch(c) {
  const args = agentProgramArguments(readFileSync(c.agent, 'utf8')), program = path.join(c.app, 'Contents/MacOS/OMPUsagePanel')
  if (!args || args.length !== 3 || args[0] !== program || args[1] !== '--config' || args[2] !== c.config) throw new InstallError('foreign-agent', `The LaunchAgent at ${c.agent} does not launch the managed app with the managed configuration`)
}
/** Start time of a process as ps reports it; pins a pid to one process instance. null when it cannot be determined.
 * @param {number} pid @returns {string|null} */
export function defaultProcessStart(pid) {
  try { return execFileSync('/bin/ps', ['-o', 'lstart=', '-p', String(pid)], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() || null } catch { return null }
}
/** Owner, kernel-reported start time and full command line of a process, or null when it is gone or unreadable.
 * @param {number} pid @returns {{uid:number, start:string, args:string}|null} */
export function defaultInspectProcess(pid) {
  try {
    const line = execFileSync('/bin/ps', ['-o', 'uid=,lstart=,args=', '-p', String(pid)], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    const match = /^(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+[\d:]{8}\s+\d{4})\s+(.+)$/.exec(line)
    return match ? { uid: Number(match[1]), start: String(match[2]), args: String(match[3]) } : null
  } catch { return null }
}
/** @param {OwnershipOptions} options */
export function context(options) {
  const home = path.resolve(options.home || homedir()), stateDir = path.resolve(options.stateDir || path.join(home, 'Library/Application Support/omp-usage-panel'))
  const uid = options.uid ?? process.getuid?.() ?? -1
  return { home, stateDir, app: path.resolve(options.appPath || path.join(home, 'Applications/OMP Usage.app')), agent: path.resolve(options.agentPath || path.join(home, `Library/LaunchAgents/${label}.plist`)), config: path.resolve(options.configPath || path.join(stateDir, 'config.json')), run: options.run || runCommand, sleep: options.sleep || sleep, env: options.env || process.env, dry: !!options.dryRun, platform: options.platform || process.platform, uid, owner: options.owner ?? process.getuid?.() ?? -1, alive: options.alive || processAlive, processStart: options.processStart || defaultProcessStart, inspectProcess: options.inspectProcess || defaultInspectProcess, now: options.now || Date.now, self: options.pid ?? process.pid }
}
/** Whether `pid` is still the process instance that recorded `start`. Fails closed: a live pid whose start time cannot be read, or
 * that was recorded without one, counts as the same process. @param {Context} c @param {number} pid @param {string|null|undefined} start */
export function sameProcess(c, pid, start) {
  if (!c.alive(pid)) return false
  if (start === null || start === undefined) return true
  const current = c.processStart(pid)
  return current === null || current === start
}
/** @param {string} file */
function readLockOwner(file) {
  try { return /** @type {{pid?:unknown, start?:unknown, token?:unknown}|null} */ (JSON.parse(readFileSync(file, 'utf8'))) } catch { return null }
}
/** The state root hosts the mutex database, so it must be a real directory owned by this user that nobody else can write, under
 * ancestors, both along the lexical route (links included) and resolved, that only this user or root can modify (or sticky
 * world-writable ones such as /tmp). Anyone able to unlink the database could
 * split the kernel exclusion. @param {Context} c */
function assertSafeStateRoot(c) {
  const stat = lstatSync(c.stateDir), reject = () => new InstallError('state-unsafe', `State directory is not a private real directory owned by this user: ${c.stateDir}`)
  if (!stat.isDirectory() || stat.uid !== c.owner || (stat.mode & 0o022) !== 0) throw reject()
  /** Resolve the route exactly as the kernel does, one component at a time and without lexical normalization: `..` applies to the
   * directory actually reached (after earlier links were followed), every directory that is entered must be modifiable only by this
   * user or root (or be sticky), and every symlink, including links reached through another link's target, must belong to this user
   * or root before its target is followed. @param {string} base directory a relative target starts from @param {string} target @param {number} depth @returns {string} */
  const route = (base, target, depth) => {
    if (depth > 40) throw reject()
    let current = path.isAbsolute(target) ? path.sep : base
    for (const part of target.split(path.sep)) {
      if (part === '' || part === '.') continue
      const directory = lstatSync(current)
      if (!directory.isDirectory() || (directory.uid !== c.owner && directory.uid !== 0) || ((directory.mode & 0o022) !== 0 && (directory.mode & 0o1000) === 0)) throw reject()
      if (part === '..') { current = path.dirname(current); continue }
      const next = path.join(current, part), entry = lstatSync(next)
      if (entry.isSymbolicLink()) {
        if (entry.uid !== c.owner && entry.uid !== 0) throw reject()
        current = route(current, readlinkSync(next), depth + 1)
      } else current = next
    }
    return current
  }
  route(path.sep, c.stateDir, 0)
}
/** The private, stable mutex database. It is created once, never renamed or unlinked, and kept after uninstall: the state root is
 * retained too. Creating it only when absent also avoids opening and closing a descriptor of a file whose POSIX locks this process
 * may hold (closing any descriptor would drop them). @param {Context} c */
function lockDatabase(c) {
  const file = path.join(c.stateDir, 'lock.sqlite')
  try { closeSync(openSync(file, 'wx', 0o600)) } catch (e) { if (/** @type {NodeJS.ErrnoException} */ (e).code !== 'EEXIST') throw e }
  const stat = lstatSync(file)
  if (!stat.isFile() || stat.uid !== c.owner || (stat.mode & 0o077) !== 0) throw new Error(`Installer lock database is not a private regular file owned by this user: ${file}`)
  return file
}
/** @param {unknown} error */
function databaseBusy(error) { const failure = /** @type {{errcode?:number, message?:string}|null} */ (error); return failure?.errcode === 5 || /database is locked/i.test(String(failure?.message)) }
/** Legacy installers coordinate with a `lock` directory. Under the exclusive database lock, a legacy lock whose recorded owner
 * process is provably gone is removed; a live, unidentifiable or ownerless legacy lock is respected (never judged by age). While
 * a critical section runs this process holds the directory too, so legacy tools stay out. Returns the release function.
 * @param {Context} c */
function claimLegacyLock(c) {
  const lock = path.join(c.stateDir, 'lock'), ownerFile = path.join(lock, 'owner'), token = randomUUID()
  if (present(lock)) {
    const owner = readLockOwner(ownerFile)
    if (owner && typeof owner.pid === 'number' && Number.isInteger(owner.pid) && !sameProcess(c, owner.pid, typeof owner.start === 'string' ? owner.start : null)) rmSync(lock, { recursive: true, force: true })
    else throw new InstallError('busy', `Installer lock exists: ${lock}`)
  }
  try { mkdirSync(lock, { mode: 0o700 }) } catch (e) { if (/** @type {NodeJS.ErrnoException} */ (e).code === 'EEXIST') throw new InstallError('busy', `Installer lock exists: ${lock}`); throw e }
  try { writeFileSync(ownerFile, JSON.stringify({ pid: c.self, start: c.processStart(c.self), token }), { mode: 0o600 }) } catch (e) { rmSync(lock, { recursive: true, force: true }); throw e }
  return () => { if (readLockOwner(ownerFile)?.token === token) rmSync(lock, { recursive: true, force: true }) }
}
/** One installer/updater critical section across processes: a SQLite `BEGIN EXCLUSIVE` on a private mutex database for the whole
 * synchronous callback. The kernel releases it if the process dies, so there is no owner, age or stale-lock heuristic. Contention
 * fails clearly; with `waitMs` it is retried in bounded 100 ms steps.
 * @template T @param {Context} c @param {()=>T} action @param {number} [waitMs] @returns {T} */
export function withLock(c, action, waitMs = 0) {
  if (c.dry) return action()
  mkdirSync(c.stateDir, { recursive: true, mode: 0o700 })
  assertSafeStateRoot(c)
  const file = lockDatabase(c), attempts = Math.ceil(waitMs / 100)
  const database = new DatabaseSync(file)
  try {
    for (let attempt = 0; ; attempt++) {
      try { database.exec('BEGIN EXCLUSIVE'); break } catch (error) {
        if (!databaseBusy(error)) throw error
        if (attempt >= attempts) throw new InstallError('busy', `Installer lock exists: ${file}`)
        c.sleep(100)
      }
    }
    try {
      const release = claimLegacyLock(c)
      try { return action() } finally { release() }
    } finally { try { database.exec('ROLLBACK') } catch { /* The transaction ends with the connection. */ } }
  } finally { database.close() }
}
/** @param {Context} c @param {InstallState|null} state @param {{adopting?:boolean}} [options] `adopting` exempts the app at the destination: the caller
 * has verified it is the very copy being adopted in place. Foreign LaunchAgents are never exempt. */
export function checkOwned(c, state, options = {}) {
  if (state && (state.appPath !== c.app || state.agentPath !== c.agent)) throw new InstallError('foreign-state', 'Tracked installation uses different app or LaunchAgent paths')
  if (!options.adopting && present(c.app) && (!state || safeTreeHash(c.app, c.owner) !== state.appHash)) throw new InstallError('foreign-app', `Foreign or modified app at ${c.app}; refusing replacement`)
  if (present(c.agent) && (!state || !lstatSync(c.agent).isFile() || lstatSync(c.agent).uid !== c.owner || digest(readFileSync(c.agent)) !== state.agentHash)) throw new InstallError('foreign-agent', `Foreign or modified LaunchAgent at ${c.agent}; refusing replacement`)
}
/** Whether launchd answered that the service does not exist. Any other failure is an inspection error, not absence. @param {unknown} error */
export function serviceNotFound(error) {
  const failure = /** @type {{status?:number, stderr?:string|Buffer}|null} */ (error)
  return failure?.status === 113 && String(failure.stderr || '').includes('Could not find service')
}
/** Fails closed: only a recognized service-not-found answer means the job is not running. @param {Context} c */
export function jobRunning(c) { try { c.run('/bin/launchctl', ['print', `gui/${c.uid}/${label}`]); return true } catch (error) { return !serviceNotFound(error) } }
/** Verify the loaded launchd job's identity (path, program, arguments) before ever stopping it. Returns null when no job is loaded.
 * `appRequired:false` tolerates a missing app directory, as during interrupted-replacement recovery.
 * @param {Context} c @param {InstallState|null} state @param {{appRequired?:boolean}} [options] @returns {{state:string|undefined, pid:number|undefined}|null} */
export function loadedJob(c, state, options = {}) {
  let description
  try { description = c.run('/bin/launchctl', ['print', `gui/${c.uid}/${label}`]) } catch (error) { if (serviceNotFound(error)) return null; throw error }
  const jobPath = /^\s*path = (.+)$/m.exec(description)?.[1]
  const program = /^\s*program = (.+)$/m.exec(description)?.[1]
  const argumentsBlock = /^\s*arguments = \{\s*\n([\s\S]*?)^\s*\}/m.exec(description)?.[1]
  const args = argumentsBlock?.split('\n').map(line => line.trim()).filter(Boolean)
  const expectedProgram = path.join(c.app, 'Contents/MacOS/OMPUsagePanel')
  if (!state || !present(c.agent) || (options.appRequired !== false && !present(c.app)) || jobPath !== c.agent || program !== expectedProgram ||
      !args || args.length !== 3 || args[0] !== expectedProgram || args[1] !== '--config' || args[2] !== c.config) {
    throw new InstallError('foreign-job', `Foreign or unverified loaded LaunchAgent ${label}; refusing to stop it`)
  }
  const pid = /^\s*pid = (\d+)$/m.exec(description)?.[1]
  return { state: /^\s*state = (.+)$/m.exec(description)?.[1]?.trim(), pid: pid === undefined ? undefined : Number(pid) }
}
/** Verify the loaded job and the owned files. Returns the job, whose pid is present while a process is running, or null when no job is
 * loaded. @param {Context} c @param {InstallState|null} state */
export function ownedJob(c, state) {
  const job = loadedJob(c, state)
  if (job) checkOwned(c, state)
  return job
}
/** Verify the loaded job and the owned files before stopping it. @param {Context} c @param {InstallState|null} state */
export function ownedJobRunning(c, state) { return ownedJob(c, state) !== null }
/** @param {Context} c */
export function startJob(c) { c.run('/bin/launchctl', ['bootstrap', `gui/${c.uid}`, c.agent]) }
/** Start a loaded job that is not running. Never `-k`: a running process is not killed. @param {Context} c */
export function kickstartJob(c) { c.run('/bin/launchctl', ['kickstart', `gui/${c.uid}/${label}`]) }
/** @param {Context} c */
export function bootoutJob(c) { c.run('/bin/launchctl', ['bootout', `gui/${c.uid}/${label}`]) }
/** @param {Context} c */
export function waitForStop(c) {
  for (let attempt = 0; attempt < 100; attempt++) {
    try { c.run('/bin/launchctl', ['print', `gui/${c.uid}/${label}`]) }
    catch (error) { if (serviceNotFound(error)) return; throw error }
    c.sleep(100)
  }
  throw new Error(`Timed out waiting for LaunchAgent ${label} to leave launchd after bootout`)
}
/** @param {Context} c */
export function stopJob(c) { bootoutJob(c); waitForStop(c) }
/** launchd labels of the host-specific jobs Sparkle 2.10.1 submits (`<host bundle identifier>-sparkle-updater` and `-sparkle-progress`;
 * the bundle identifier is the app label). */
export const installerLabel = `${label}-sparkle-updater`
export const progressLabel = `${label}-sparkle-progress`
/** @typedef {{domain:string, label:string, running:boolean}} InstallerJob */
/** @param {string} left @param {string} right */
function samePath(left, right) { if (left === right) return true; try { return realpathSync(left) === realpathSync(right) } catch { return false } }
/** Observe Sparkle's host-specific installer and progress jobs. Every registered job must be identified exactly (bundled executable
 * and full arguments for this app; path-valued arguments are compared by physical path, because the SDK standardizes them, e.g. /tmp
 * versus /private/tmp, while the process command line is compared byte for byte against launchd's own record) and a running one must additionally be the expected executable, owned by this user, with a stable
 * kernel start time. Anything unidentifiable or uninspectable throws: it is unknown, never absent. Returns the jobs still registered.
 * @param {Context} c @returns {InstallerJob[]} */
export function inspectInstaller(c) {
  const bundled = path.join(c.app, 'Contents/Frameworks/Sparkle.framework/Versions/B')
  const expected = [
    { label: installerLabel, exec: path.join(bundled, 'Autoupdate'), valid: (/** @type {string[]} */ args) => args.length === 4 && args[1] === label },
    { label: progressLabel, exec: path.join(bundled, 'Updater.app/Contents/MacOS/Updater'), valid: (/** @type {string[]} */ args) => args.length === 3 && typeof args[1] === 'string' && samePath(args[1], c.app) },
  ]
  /** @type {InstallerJob[]} */
  const jobs = []
  for (const job of expected) for (const domain of [`gui/${c.uid}`, `user/${c.uid}`]) {
    let description
    try { description = c.run('/bin/launchctl', ['print', `${domain}/${job.label}`]) } catch (error) { if (serviceNotFound(error)) continue; throw error }
    const program = /^\s*program = (.+)$/m.exec(description)?.[1]
    const args = /^\s*arguments = \{\s*\n([\s\S]*?)^\s*\}/m.exec(description)?.[1]?.split('\n').map(line => line.trim()).filter(Boolean)
    if (!args || !args[0] || !samePath(args[0], job.exec) || !samePath(program ?? args[0], job.exec) || !job.valid(args)) throw new Error(`Launchd service ${domain}/${job.label} is not Sparkle's installer for this app; it cannot be treated as gone`)
    const pid = /^\s*pid = (\d+)$/m.exec(description)?.[1]
    const running = pid !== undefined || /^\s*state = (.+)$/m.exec(description)?.[1]?.trim() !== 'not running'
    if (pid !== undefined) {
      const first = c.inspectProcess(Number(pid)), again = c.inspectProcess(Number(pid))
      if (!first || !again || first.uid !== c.owner || first.args !== args.join(' ') || first.start !== again.start) throw new Error(`Process ${pid} of ${domain}/${job.label} could not be identified; it cannot be treated as gone`)
    }
    jobs.push({ domain, label: job.label, running })
  }
  return jobs
}
/** Remove identified installer jobs that are loaded but not running (a finished Sparkle job stays registered and could be launched
 * again on demand) and verify each left launchd. Never signals a process; callers must have established nothing is running.
 * @param {Context} c @param {InstallerJob[]} jobs */
export function removeIdleInstallerJobs(c, jobs) {
  for (const job of jobs) {
    if (job.running) throw new Error(`${job.label} is still running`)
    c.run('/bin/launchctl', ['bootout', `${job.domain}/${job.label}`])
    let gone = false
    for (let attempt = 0; attempt < 20 && !gone; attempt++) {
      try { c.run('/bin/launchctl', ['print', `${job.domain}/${job.label}`]) } catch (error) { if (serviceNotFound(error)) { gone = true; break } throw error }
      c.sleep(100)
    }
    if (!gone) throw new Error(`Timed out waiting for ${job.label} to leave launchd`)
  }
}
