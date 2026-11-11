import test from 'node:test'
import assert from 'node:assert/strict'
import { chmodSync, copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { install, uninstall } from './installation.mjs'
import { appTreeHash } from './ownership.mjs'
import { abortUpdate, acknowledgeUpdate, authorizeRestart, prepareUpdate, recoverUpdate, registerWatcher, revokeUpdate, runWatcher, trustedRuntimeFiles, updateStatus } from './update-transaction.mjs'

const sourceDirectory = path.dirname(fileURLToPath(import.meta.url))
const otherUser = (process.getuid?.() ?? 0) + 1
const HOST = 7001, WATCHER = 7002, OTHER_HOST = 7003, CALLER = 7009
const liveMessage = /authorized or in progress/

/** A complete app tree: executable, runtime modules and a framework with relative symlinks, as the Sparkle build ships.
 * @param {string} root @param {string} version */
function makeApp(root, version) {
  /** @param {string} rel @param {string} content @param {number} [mode] */
  const put = (rel, content, mode = 0o644) => { const file = path.join(root, rel); mkdirSync(path.dirname(file), { recursive: true }); writeFileSync(file, content); chmodSync(file, mode) }
  put('Contents/MacOS/OMPUsagePanel', `binary-${version}`, 0o755)
  put('Contents/Info.plist', `<plist>${version}</plist>`)
  for (const file of trustedRuntimeFiles) put(`Contents/Resources/runtime/apps/macos/${file}`, readFileSync(path.join(sourceDirectory, file), 'utf8'))
  // Sparkle's bundled installer executables must really exist: jobs are identified by their physical path.
  put('Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate', `autoupdate-${version}`, 0o755)
  put('Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater', `updater-${version}`, 0o755)
  put('Contents/Frameworks/Fake.framework/Versions/B/Fake', `framework-${version}`, 0o755)
  symlinkSync('B', path.join(root, 'Contents/Frameworks/Fake.framework/Versions/Current'), 'dir')
  symlinkSync('Versions/Current/Fake', path.join(root, 'Contents/Frameworks/Fake.framework/Fake'), 'file')
  return root
}

function fixture() {
  const home = mkdtempSync(path.join(tmpdir(), 'omp-update-test-'))
  symlinkSync(home, `${home}-alias`, 'dir')
  const stateDir = path.join(home, 'Library/Application Support/omp-usage-panel')
  const config = path.join(stateDir, 'config.json'), manifestFile = path.join(stateDir, 'install.json')
  const app = path.join(home, 'Applications/OMP Usage.app'), agent = path.join(home, 'Library/LaunchAgents/com.dhkim.omp-usage-panel.plist')
  const updater = path.join(stateDir, 'updater'), transaction = path.join(updater, 'transaction'), receiptFile = path.join(transaction, 'receipt.json')
  /** @type {string[]} */
  const events = []
  /** @type {{command:string, args:string[]}[]} */
  const spawned = []
  /** @type {{committed:boolean, pending:boolean}[]} */
  const acknowledgments = []
  const live = new Set([HOST, WATCHER, OTHER_HOST, CALLER])
  let loaded = false, foreign = false, bootoutFails = false, jobExited = false, printFails = false, spawnMode = 'register', installer = 'absent', jobPid = 0
  const generations = new Map()
  /** @type {string[]} */
  const removed = []
  const removedJobs = new Set()
  const start = Date.now()
  let clock = start
  /** @type {(()=>void)|null} */
  let hook = null
  const binary = () => readFileSync(path.join(app, 'Contents/MacOS/OMPUsagePanel'), 'utf8')
  /** @param {string} file @param {string[]} args */
  function run(file, args) {
    if (file === process.execPath && args[0] === '--version') return 'v22.18.0'
    if (file === '/bin/launchctl') {
      if (args[0] === 'print') {
        const jobLabel = args[1]?.split('/')[2] ?? ''
        if (/-sparkle-(updater|progress)$/.test(jobLabel)) {
          // Sparkle's host-specific installer jobs: absent, loaded but idle, running, foreign, or not inspectable.
          if (printFails || installer === 'error') throw Object.assign(new Error('launchctl print failed'), { status: 1, stderr: 'Operation not permitted' })
          if (removedJobs.has(args[1] ?? '') || installer === 'absent' || !args[1]?.startsWith('gui/') || (jobLabel.endsWith('progress') && !installer.startsWith('alias') && installer !== 'other-host')) throw Object.assign(new Error('not running'), { status: 113, stderr: 'Could not find service' })
          // The SDK standardizes paths, so its launchd records may spell the same physical app through an alias.
          const spelled = installer.startsWith('alias') ? `${home}-alias/Applications/OMP Usage.app` : app
          if (jobLabel.endsWith('progress')) return `job = {\n\tprogram = ${spelled}/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater\n\tstate = not running\n\targuments = {\n\t\t${spelled}/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater\n\t\t${installer === 'other-host' ? `${home}/Elsewhere.app` : spelled}\n\t\t0\n\t}\n}`
          const tool = installer === 'foreign' ? ['/foreign/tool'] : installer.startsWith('alias') ? [`${spelled}/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate`, 'com.dhkim.omp-usage-panel', home, 'user'] : [`${app}/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate`, 'com.dhkim.omp-usage-panel', home, 'user']
          const running = installer === 'running' || installer === 'imposter'
          return `job = {\n\tprogram = ${tool[0]}\n\tstate = ${running ? 'running' : 'not running'}${running ? '\n\tpid = 4242' : ''}\n\targuments = {\n\t\t${tool.join('\n\t\t')}\n\t}\n}`
        }
        if (printFails) throw Object.assign(new Error('launchctl print failed'), { status: 1, stderr: 'Operation not permitted' })
        if (!loaded) throw Object.assign(new Error('not running'), { status: 113, stderr: 'Could not find service' })
        const program = foreign ? '/foreign/program' : path.join(app, 'Contents/MacOS/OMPUsagePanel')
        return `job = {\n\tpath = ${agent}\n\tstate = ${jobExited ? 'not running' : 'running'}${jobPid ? `\n\tpid = ${jobPid}` : ''}\n\tprogram = ${program}\n\targuments = {\n\t\t${program}\n\t\t--config\n\t\t${config}\n\t}\n}`
      }
      if (args[0] === 'bootout' && /-sparkle-(updater|progress)$/.test(args[1] ?? '')) { removed.push(args[1] ?? ''); removedJobs.add(args[1] ?? ''); return '' }
      if (args[0] === 'bootout') { if (bootoutFails) throw new Error('bootout failed'); events.push('bootout'); loaded = false; return '' }
      if (args[0] === 'bootstrap') { events.push(`bootstrap:${binary()}`); loaded = true; return '' }
    }
    throw new Error(`Unexpected command: ${file} ${args.join(' ')}`)
  }
  /** @param {number} milliseconds */
  function sleep(milliseconds) { clock += milliseconds; if (hook) hook() }
  /** Stands in for the detached watcher process starting: it binds itself to the transaction it was armed for.
   * @param {string} command @param {string[]} args */
  function spawnWatcher(command, args) {
    spawned.push({ command, args })
    if (spawnMode === 'fail') throw new Error('spawn failed')
    if (spawnMode === 'register') registerWatcher({ ...options, pid: WATCHER, ...JSON.parse(args[2] ?? '{}') })
  }
  const options = { home, platform: 'darwin', run, uid: 123, sleep, now: () => clock, readinessMs: 2000, pollMs: 250, replacementGraceMs: 5000, armWaitMs: 1000, pid: CALLER, alive: (/** @type {number} */ pid) => live.has(pid), inspectProcess: (/** @type {number} */ pid) => pid === 4242 ? { uid: process.getuid?.() ?? 0, start: 'Mon Nov 11 10:00:00 2026', args: installer === 'imposter' ? '/bin/other' : `${app}/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate com.dhkim.omp-usage-panel ${home} user` } : null, processStart: (/** @type {number} */ pid) => live.has(pid) ? `start-${pid}-${generations.get(pid) ?? 0}` : null, spawnWatcher }
  const target = { ...options, appPath: app, configPath: config }
  const readJson = (/** @type {string} */ file) => JSON.parse(readFileSync(file, 'utf8'))
  const receipt = () => readJson(receiptFile)
  const manifest = () => readJson(manifestFile)
  /** @param {string} [version] @param {Record<string, unknown>} [extra] */
  function installApp(version = '0.1.0', extra = {}) {
    install({ ...options, node: process.execPath, env: { OMP_BIN: '/bin/sh' }, build({ outputDirectory }) { return makeApp(path.join(outputDirectory, 'built.app'), version) }, ...extra })
    events.length = 0
  }
  /** Build the update Sparkle would extract, without installing it yet. @param {string} version */
  function stageUpdate(version) {
    const staged = path.join(home, `update-${version}.app`)
    makeApp(staged, version)
    return { hash: appTreeHash(staged), replace() { rmSync(app, { recursive: true }); cpSync(staged, app, { recursive: true, verbatimSymlinks: true }) } }
  }
  /** @param {string} hash @param {string} [version] @param {number} [ownerPid] */
  function prepare(hash, version = '0.2.0', ownerPid = HOST) { return prepareUpdate({ ...target, expectedVersion: version, currentVersion: '0.1.0', expectedAppTreeSHA256: hash, ownerPid }) }
  /** Prepare, arm and authorize the final restart handoff, as the native app does right before the SDK may terminate it. @param {{hash:string}} update */
  function authorized(update) {
    const prepared = prepare(update.hash)
    assert.deepEqual(authorizeRestart({ ...target, transactionId: prepared.transactionId }), { authorized: true })
    return prepared
  }
  /** The host quits on the watcher's first poll and the SDK installer replaces the bundle; the new app acknowledges on the watcher's
   * second readiness poll when `acknowledge` names its version. @param {{update?:{replace:()=>void}, acknowledge?:string, onRelaunching?:()=>void, onPoll?:(call:number)=>void}} scenario */
  function hostQuits(scenario) {
    let quit = false, polls = 0, calls = 0
    hook = () => {
      scenario.onPoll?.(++calls)
      if (!quit) { quit = true; live.delete(HOST); scenario.update?.replace(); return }
      if (!existsSync(receiptFile) || receipt().phase !== 'relaunching') return
      polls++
      scenario.onRelaunching?.()
      if (scenario.acknowledge && polls === 2) acknowledgments.push(acknowledgeUpdate({ ...target, version: scenario.acknowledge }))
    }
  }
  return {
    home, stateDir, config, manifestFile, app, agent, updater, transaction, receiptFile, options, target, events, spawned, acknowledgments, removed,
    binary, receipt, manifest, installApp, stageUpdate, prepare, authorized, hostQuits,
    outcome: () => readJson(path.join(updater, 'outcome.json')),
    watch: (/** @type {string} */ transactionId) => runWatcher({ ...options, pid: WATCHER, stateDir, transactionId }),
    elapsed: () => clock - start,
    advance(/** @type {number} */ milliseconds) { clock += milliseconds },
    isLoaded: () => loaded,
    kill(/** @type {number} */ pid) { live.delete(pid) },
    /** The pid now belongs to a different process instance. */
    reuse(/** @type {number} */ pid) { generations.set(pid, (generations.get(pid) ?? 0) + 1) },
    setInstaller(/** @type {string} */ value) { installer = value; removedJobs.clear() },
    setJobPid(/** @type {number} */ value) { jobPid = value },
    revive(/** @type {number} */ pid) { live.add(pid) },
    onSleep(/** @type {(()=>void)|null} */ value) { hook = value },
    setSpawnMode(/** @type {string} */ value) { spawnMode = value },
    setForeignJob(/** @type {boolean} */ value) { foreign = value },
    setBootoutFails(/** @type {boolean} */ value) { bootoutFails = value },
    setJobExited(/** @type {boolean} */ value) { jobExited = value },
    setPrintFails(/** @type {boolean} */ value) { printFails = value },
    cleanup() { rmSync(`${home}-alias`, { force: true }); rmSync(home, { recursive: true, force: true }) },
  }
}

test('status reports an installed app as managed and keeps a verified watcher runtime outside the bundle', () => {
  const f = fixture()
  try {
    f.installApp()
    const status = updateStatus(f.target)
    assert.equal(status.managed, true); assert.equal(status.pending, null); assert.equal(status.outcome, null)
    const runtime = path.join(f.updater, 'watcher/runtime/apps/macos')
    for (const file of trustedRuntimeFiles) assert.equal(readFileSync(path.join(runtime, file), 'utf8'), readFileSync(path.join(f.app, 'Contents/Resources/runtime/apps/macos', file), 'utf8'))
    assert.equal(statSync(f.updater).mode & 0o077, 0)
    writeFileSync(path.join(runtime, 'ownership.mjs'), 'tampered')
    assert.equal(updateStatus(f.target).managed, true)
    assert.equal(readFileSync(path.join(runtime, 'ownership.mjs'), 'utf8'), readFileSync(path.join(f.app, 'Contents/Resources/runtime/apps/macos/ownership.mjs'), 'utf8'))
  } finally { f.cleanup() }
})
test('status refuses installs that are unmanaged, foreign-owned, started with another configuration, foreign or modified', () => {
  const f = fixture()
  try {
    assert.match(String(updateStatus(f.target).reason), /not installed by the OMP Usage installer/)
    f.installApp()
    assert.throws(() => updateStatus({ ...f.target, owner: otherUser }), /not a private real directory/)
    assert.match(String(updateStatus({ ...f.target, configPath: path.join(f.home, 'other-config.json') }).reason), /configuration path/)
    f.setForeignJob(true)
    assert.match(String(updateStatus(f.target).reason), /Foreign or unverified loaded LaunchAgent/)
    f.setForeignJob(false)
    writeFileSync(path.join(f.app, 'user-file'), 'keep')
    const modified = updateStatus(f.target)
    assert.equal(modified.managed, false); assert.match(String(modified.reason), /differs from the installer ownership record/)
    assert.equal(readFileSync(path.join(f.app, 'user-file'), 'utf8'), 'keep'); assert.equal(existsSync(path.join(f.updater, 'watcher')), false)
    rmSync(path.join(f.app, 'user-file'))
    assert.equal(updateStatus(f.target).managed, true)
    writeFileSync(f.agent, 'modified agent')
    const agentStatus = updateStatus(f.target)
    assert.equal(agentStatus.managed, false); assert.match(String(agentStatus.reason), /LaunchAgent differs from the installer ownership record/)
  } finally { f.cleanup() }
})
test('an inspection failure is never mistaken for an absent job: status, install and uninstall refuse before changing anything', () => {
  const f = fixture()
  try {
    f.installApp()
    const before = { hash: appTreeHash(f.app), manifest: readFileSync(f.manifestFile), agent: readFileSync(f.agent) }
    f.setPrintFails(true)
    const status = updateStatus(f.target)
    assert.equal(status.managed, false); assert.match(String(status.reason), /launchctl print failed/)
    assert.throws(() => install({ ...f.options, node: process.execPath, env: { OMP_BIN: '/bin/sh' } }), /launchctl print failed/)
    assert.throws(() => uninstall(f.options), /launchctl print failed/)
    assert.deepEqual(f.events, []); assert.equal(appTreeHash(f.app), before.hash); assert.deepEqual(readFileSync(f.manifestFile), before.manifest); assert.deepEqual(readFileSync(f.agent), before.agent)
  } finally { f.cleanup() }
})
test('prepare leases the update to the live host, keeps a durable verified backup and arms the copied watcher', () => {
  const f = fixture()
  try {
    f.installApp()
    const before = { config: readFileSync(f.config), agent: readFileSync(f.agent), manifest: readFileSync(f.manifestFile), hash: appTreeHash(f.app) }
    const update = f.stageUpdate('0.2.0')
    const prepared = f.prepare(update.hash)
    assert.deepEqual({ armed: prepared.armed }, { armed: true })
    const receipt = f.receipt()
    assert.equal(receipt.id, prepared.transactionId); assert.equal(receipt.phase, 'prepared')
    assert.equal(receipt.hostPid, HOST); assert.equal(receipt.watcherPid, WATCHER); assert.equal(receipt.armToken, null); assert.equal(receipt.restart, false)
    assert.equal(receipt.oldHash, before.hash); assert.equal(receipt.expectedHash, update.hash); assert.equal(receipt.node, process.execPath); assert.equal(receipt.jobLoaded, true)
    assert.equal(appTreeHash(path.join(f.transaction, 'backup/app')), before.hash)
    assert.deepEqual(readFileSync(path.join(f.transaction, 'backup/install.json')), before.manifest)
    assert.equal(statSync(f.transaction).mode & 0o077, 0); assert.equal(statSync(f.receiptFile).mode & 0o077, 0)
    assert.equal(f.spawned.length, 1); assert.equal(f.spawned[0]?.command, process.execPath)
    assert.equal(f.spawned[0]?.args[0], path.join(f.updater, 'watcher/runtime/apps/macos/update-ownership.mjs')); assert.equal(f.spawned[0]?.args[1], 'watch')
    assert.deepEqual(readFileSync(f.config), before.config); assert.deepEqual(readFileSync(f.agent), before.agent); assert.deepEqual(readFileSync(f.manifestFile), before.manifest)
    assert.equal(appTreeHash(f.app), before.hash); assert.deepEqual(f.events, []); assert.equal(f.isLoaded(), true)
    // The same live owner asking again for the same update is idempotent; anything else must resolve the session first.
    assert.equal(f.prepare(update.hash).transactionId, prepared.transactionId); assert.equal(f.spawned.length, 1)
    assert.throws(() => f.prepare(update.hash, '0.2.1'), { code: 'authorization-active' })
    assert.throws(() => f.prepare(update.hash, '0.2.0', OTHER_HOST), { code: 'authorization-active' })
    assert.equal(f.receipt().id, prepared.transactionId)
  } finally { f.cleanup() }
})
test('prepare refuses invalid requests and unmanaged, foreign-owned, modified or symlinked-area installs', () => {
  const f = fixture()
  try {
    const hash = 'a'.repeat(64)
    assert.throws(() => prepareUpdate({ ...f.target, expectedVersion: '0.2.0', currentVersion: '0.1.0', expectedAppTreeSHA256: 'xyz', ownerPid: HOST }), { code: 'invalid-request' })
    assert.throws(() => f.prepare(hash, '../0.2'), { code: 'invalid-request' })
    assert.throws(() => f.prepare(hash, '0.2.0', 0), { code: 'invalid-request' })
    assert.throws(() => f.prepare(hash), { code: 'not-managed' })
    f.installApp()
    assert.throws(() => f.prepare(hash, '0.2.0', 9999), { code: 'invalid-request' })
    assert.throws(() => f.prepare(appTreeHash(f.app)), { code: 'invalid-request' })
    assert.throws(() => prepareUpdate({ ...f.target, owner: otherUser, expectedVersion: '0.2.0', currentVersion: '0.1.0', expectedAppTreeSHA256: hash, ownerPid: HOST }), /not a private real directory/)
    const elsewhere = path.join(f.home, 'elsewhere'); mkdirSync(elsewhere); symlinkSync(elsewhere, f.updater, 'dir')
    assert.throws(() => f.prepare(hash), { code: 'invalid-transaction' })
    assert.deepEqual(readdirSync(elsewhere), []); rmSync(f.updater)
    writeFileSync(path.join(f.app, 'user-file'), 'keep')
    assert.throws(() => f.prepare(hash), { code: 'ownership-mismatch' })
    assert.equal(existsSync(f.transaction), false); assert.equal(readFileSync(path.join(f.app, 'user-file'), 'utf8'), 'keep'); assert.equal(f.spawned.length, 0)
  } finally { f.cleanup() }
})
test('a watcher that cannot be armed fails closed: prepare errors and leaves no authorization behind', () => {
  const f = fixture()
  try {
    f.installApp()
    const update = f.stageUpdate('0.2.0'), before = appTreeHash(f.app)
    f.setSpawnMode('fail')
    assert.throws(() => f.prepare(update.hash), { code: 'arm-failed' })
    assert.equal(existsSync(f.transaction), false)
    f.setSpawnMode('silent')
    assert.throws(() => f.prepare(update.hash), { code: 'arm-failed' })
    assert.equal(existsSync(f.transaction), false); assert.equal(appTreeHash(f.app), before)
    f.setSpawnMode('register')
    assert.equal(f.prepare(update.hash).armed, true)
  } finally { f.cleanup() }
})
test('a live authorization is never discarded by age or recovery and blocks source install and uninstall until it is aborted', () => {
  const f = fixture()
  try {
    f.installApp()
    const update = f.stageUpdate('0.2.0'), prepared = f.prepare(update.hash)
    f.advance(90 * 24 * 3600 * 1000)
    const status = updateStatus(f.target)
    assert.equal(status.managed, false); assert.equal(status.pending?.armed, true); assert.equal(status.pending?.ownerAlive, true)
    assert.equal(recoverUpdate(f.target).managed, false)
    for (const dryRun of [true, false]) {
      assert.throws(() => install({ ...f.options, dryRun, node: process.execPath, env: { OMP_BIN: '/bin/sh' } }), liveMessage)
      assert.throws(() => uninstall({ ...f.options, dryRun }), liveMessage)
    }
    assert.throws(() => recoverUpdate({ ...f.target, action: 'rollback' }), { code: 'busy' })
    assert.equal(existsSync(f.receiptFile), true); assert.equal(existsSync(path.join(f.transaction, 'backup/app')), true); assert.equal(existsSync(path.join(f.transaction, 'backup/install.json')), true)
    assert.deepEqual(f.events, [])
    assert.deepEqual(abortUpdate({ ...f.target, transactionId: 'unrelated' }).aborted, false)
    // The SDK session is resolved: the abort clears the lease and the running watcher notices and exits without touching anything.
    f.onSleep(() => { f.onSleep(null); assert.deepEqual(abortUpdate({ ...f.target, transactionId: prepared.transactionId }), { aborted: true }) })
    assert.equal(f.watch(prepared.transactionId).outcome, 'cancelled')
    assert.equal(existsSync(f.transaction), false)
    uninstall({ ...f.options, dryRun: true })
  } finally { f.cleanup() }
})
test('abort revokes the restart at once but keeps the transaction until launchd proves the installer gone', () => {
  const f = fixture()
  try {
    f.installApp()
    const before = appTreeHash(f.app), update = f.stageUpdate('0.2.0'), prepared = f.authorized(update)
    assert.equal(f.receipt().restart, true)
    f.setInstaller('running')
    const live = abortUpdate({ ...f.target, transactionId: prepared.transactionId })
    assert.equal(live.aborted, false); assert.equal(live.code, 'installer-live')
    assert.equal(f.receipt().restart, false); assert.equal(f.receipt().revoked, true)
    assert.equal(existsSync(path.join(f.transaction, 'backup/app')), true); assert.equal(appTreeHash(path.join(f.transaction, 'backup/app')), before)
    assert.equal(authorizeRestart({ ...f.target, transactionId: prepared.transactionId }).authorized, false)
    assert.throws(() => uninstall({ ...f.options, dryRun: true }), liveMessage)
    assert.throws(() => f.prepare(update.hash), { code: 'authorization-active' })
    // An installer that cannot be inspected is not gone either.
    f.setInstaller('error')
    assert.throws(() => abortUpdate({ ...f.target, transactionId: prepared.transactionId }), { code: 'inspection-failed' })
    assert.equal(existsSync(f.receiptFile), true)
    assert.throws(() => abortUpdate({ ...f.target, transactionId: prepared.transactionId, installerLabel: 'com.example.other' }), { code: 'invalid-request' })
    // A registered job that is not exactly Sparkle's, or a running process that is not the expected executable, is unknown, never gone.
    for (const mode of ['foreign', 'imposter']) {
      f.setInstaller(mode)
      assert.throws(() => abortUpdate({ ...f.target, transactionId: prepared.transactionId }), { code: 'inspection-failed' }, mode)
    }
    assert.equal(existsSync(f.receiptFile), true); assert.deepEqual(f.removed, [])
    // Loaded but idle (no pid, not running) is re-launchable on demand: it is removed and verified gone before anything is deleted.
    f.setInstaller('idle')
    assert.deepEqual(abortUpdate({ ...f.target, transactionId: prepared.transactionId }), { aborted: true })
    assert.deepEqual(f.removed, ['gui/123/com.dhkim.omp-usage-panel-sparkle-updater'])
    assert.equal(existsSync(f.transaction), false)
  } finally { f.cleanup() }
})
test('installer jobs are identified by physical path: an aliased spelling is the same app, another host app is unknown, never gone', () => {
  const f = fixture()
  try {
    f.installApp()
    const prepared = f.authorized(f.stageUpdate('0.2.0'))
    // Both Sparkle jobs spell the very same app through an alias (as the SDK's standardized paths do): identified, idle, removed, gone.
    f.setInstaller('alias')
    assert.deepEqual(abortUpdate({ ...f.target, transactionId: prepared.transactionId }), { aborted: true })
    assert.deepEqual(f.removed.sort(), ['gui/123/com.dhkim.omp-usage-panel-sparkle-progress', 'gui/123/com.dhkim.omp-usage-panel-sparkle-updater'])
    const second = f.authorized(f.stageUpdate('0.3.0'))
    // A progress job whose host argument is a different app is not this app's installer: unknown, nothing removed, evidence kept.
    f.removed.length = 0
    f.setInstaller('other-host')
    assert.throws(() => abortUpdate({ ...f.target, transactionId: second.transactionId }), { code: 'inspection-failed' })
    assert.deepEqual(f.removed, []); assert.equal(existsSync(f.receiptFile), true)
  } finally { f.cleanup() }
})
test('a revoked update survives the host quitting: no restart, no time-based discard, then the watcher discards once the installer is gone', () => {
  const f = fixture()
  try {
    f.installApp()
    const before = appTreeHash(f.app), prepared = f.authorized(f.stageUpdate('0.2.0'))
    f.setInstaller('running')
    assert.equal(abortUpdate({ ...f.target, transactionId: prepared.transactionId }).code, 'installer-live')
    let polls = 0
    f.onSleep(() => { polls++; if (polls === 1) f.kill(HOST); if (polls === 60) f.setInstaller('absent') })
    const result = f.watch(prepared.transactionId)
    assert.equal(result.outcome, 'cancelled')
    assert.ok(f.elapsed() > 5000 * 2, `waited ${f.elapsed()}ms past the grace period while the installer was live`)
    assert.deepEqual(f.events, []); assert.equal(appTreeHash(f.app), before); assert.equal(existsSync(f.transaction), false)
  } finally { f.cleanup() }
})
test('an installer that wins the race against a revocation replaces the app without any restart and the next launch commits', () => {
  const f = fixture()
  try {
    f.installApp()
    const update = f.stageUpdate('0.2.0'), prepared = f.authorized(update)
    f.setInstaller('running')
    assert.equal(abortUpdate({ ...f.target, transactionId: prepared.transactionId }).code, 'installer-live')
    f.hostQuits({ update })
    assert.equal(f.watch(prepared.transactionId).outcome, 'deferred')
    assert.deepEqual(f.events, [])
    assert.equal(abortUpdate({ ...f.target, transactionId: prepared.transactionId }).code, 'replaced')
    f.kill(WATCHER)
    // The installer that won the race is still running: the acknowledgment is retained, not committed.
    assert.deepEqual(acknowledgeUpdate({ ...f.target, version: '0.2.0' }), { committed: false, pending: true, reason: 'installer-quiescing' })
    assert.equal(f.receipt().acknowledged, true); assert.equal(existsSync(path.join(f.transaction, 'backup/app')), true)
    f.setInstaller('absent')
    assert.deepEqual(acknowledgeUpdate({ ...f.target, version: '0.2.0' }), { committed: true, pending: false })
    assert.equal(existsSync(f.transaction), false)
  } finally { f.cleanup() }
})
test('a lapse needs launchd to confirm the installer is gone, not just elapsed time, and removes an idle leftover job', () => {
  const f = fixture()
  try {
    f.installApp()
    const prepared = f.authorized(f.stageUpdate('0.2.0'))
    f.setInstaller('running')
    let polls = 0
    f.onSleep(() => { if (!polls++) f.kill(HOST); if (polls === 100) f.setInstaller('idle') })
    assert.equal(f.watch(prepared.transactionId).outcome, 'lapsed')
    assert.ok(polls >= 100); assert.ok(f.elapsed() > 5000 * 4)
    assert.deepEqual(f.removed, ['gui/123/com.dhkim.omp-usage-panel-sparkle-updater'])
    f.kill(WATCHER)
    f.setInstaller('running')
    assert.throws(() => uninstall({ ...f.options, dryRun: true }), liveMessage)
    f.setInstaller('absent')
    assert.equal(updateStatus(f.target).managed, true)
  } finally { f.cleanup() }
})
test('revoke withdraws the restart authorization durably without deleting the transaction or backup', () => {
  const f = fixture()
  try {
    f.installApp()
    const update = f.stageUpdate('0.2.0'), prepared = f.authorized(update)
    assert.deepEqual(revokeUpdate({ ...f.target, transactionId: 'unrelated' }).code, 'unknown-transaction')
    assert.deepEqual(revokeUpdate({ ...f.target, transactionId: prepared.transactionId }), { revoked: true })
    assert.equal(f.receipt().restart, false); assert.equal(f.receipt().revoked, true); assert.equal(existsSync(path.join(f.transaction, 'backup/app')), true)
    assert.equal(authorizeRestart({ ...f.target, transactionId: prepared.transactionId }).authorized, false)
    f.setInstaller('running')
    f.hostQuits({ update })
    assert.equal(f.watch(prepared.transactionId).outcome, 'deferred'); assert.deepEqual(f.events, [])
    assert.equal(revokeUpdate({ ...f.target, transactionId: prepared.transactionId }).code, 'replaced')
  } finally { f.cleanup() }
})
test('a pid reused by another process is not the lease owner, the watcher or the worker', () => {
  const f = fixture()
  try {
    f.installApp()
    const prepared = f.authorized(f.stageUpdate('0.2.0'))
    f.reuse(HOST)
    assert.equal(updateStatus(f.target).pending?.ownerAlive, false)
    assert.equal(authorizeRestart({ ...f.target, transactionId: prepared.transactionId }).authorized, false)
    assert.throws(() => uninstall({ ...f.options, dryRun: true }), liveMessage)
    f.reuse(WATCHER)
    assert.equal(updateStatus(f.target).managed, true); assert.equal(existsSync(f.transaction), false)
    f.setJobPid(OTHER_HOST)
    assert.throws(() => f.prepare(f.stageUpdate('0.3.0').hash), { code: 'ownership-mismatch' })
    f.setJobPid(HOST)
    assert.equal(f.prepare(f.stageUpdate('0.4.0').hash).armed, true)
  } finally { f.cleanup() }
})
test('abandonment is established before a prepared update is discarded: owner and watcher must both be gone', () => {
  const f = fixture()
  try {
    f.installApp()
    const update = f.stageUpdate('0.2.0')
    f.prepare(update.hash)
    f.kill(HOST)
    // The owner died, but the watcher is still waiting for a replacement that may be in flight.
    assert.throws(() => uninstall({ ...f.options, dryRun: true }), liveMessage)
    assert.equal(updateStatus(f.target).managed, false); assert.equal(existsSync(f.receiptFile), true)
    f.kill(WATCHER)
    assert.equal(updateStatus(f.target).managed, true); assert.equal(existsSync(f.transaction), false)
    f.revive(HOST); f.revive(WATCHER)
    f.prepare(update.hash); f.kill(HOST); f.kill(WATCHER)
    f.installApp('9.9.9')
    assert.equal(f.binary(), 'binary-9.9.9'); assert.equal(existsSync(f.transaction), false)
  } finally { f.cleanup() }
})
test('the watcher does nothing while the host lives, then restarts the app after an authorized quit and commit follows acknowledgment', () => {
  const f = fixture()
  try {
    f.installApp()
    const before = { config: readFileSync(f.config), agent: readFileSync(f.agent), oldHash: appTreeHash(f.app), agentHash: f.manifest().agentHash }
    const update = f.stageUpdate('0.2.0'), prepared = f.authorized(update)
    const manifestsBeforeAcknowledgment = /** @type {string[]} */ ([])
    let hostPolls = 0
    // A long download: the host is alive for 200 polls and nothing may happen to the app, the job or the receipt.
    f.onSleep(() => {
      if (hostPolls < 200) { hostPolls++; assert.deepEqual(f.events, []); assert.equal(appTreeHash(f.app), before.oldHash); assert.equal(f.receipt().phase, 'prepared'); return }
      f.hostQuits({ update, acknowledge: '0.2.0', onRelaunching: () => manifestsBeforeAcknowledgment.push(f.manifest().appHash) })
    })
    const result = f.watch(prepared.transactionId)
    assert.equal(result.outcome, 'updated')
    assert.equal(hostPolls, 200)
    assert.deepEqual(manifestsBeforeAcknowledgment, [before.oldHash, before.oldHash])
    assert.deepEqual(f.acknowledgments, [{ committed: true, pending: false }])
    assert.deepEqual(f.manifest(), { version: 2, appPath: f.app, agentPath: f.agent, appHash: update.hash, agentHash: before.agentHash })
    assert.deepEqual(readFileSync(f.config), before.config); assert.deepEqual(readFileSync(f.agent), before.agent)
    assert.equal(existsSync(f.transaction), false); assert.equal(f.outcome().status, 'updated'); assert.equal(f.outcome().toVersion, '0.2.0')
    assert.deepEqual(f.events, ['bootout', 'bootstrap:binary-0.2.0']); assert.equal(f.isLoaded(), true)
    assert.equal(updateStatus(f.target).managed, true)
    uninstall(f.options)
    assert.equal(existsSync(f.app), false); assert.equal(existsSync(f.updater), false); assert.deepEqual(readFileSync(f.config), before.config)
  } finally { f.cleanup() }
})
test('a plain Quit is never followed by a restart even if the SDK still replaces the app; the next real launch commits', () => {
  const f = fixture()
  try {
    f.installApp()
    const before = appTreeHash(f.app), update = f.stageUpdate('0.2.0'), prepared = f.prepare(update.hash)
    f.hostQuits({ update })
    const result = f.watch(prepared.transactionId)
    assert.equal(result.outcome, 'deferred')
    assert.deepEqual(f.events, []); assert.equal(f.isLoaded(), true); assert.equal(f.manifest().appHash, before)
    f.kill(WATCHER)
    const waiting = updateStatus(f.target)
    assert.equal(waiting.managed, false); assert.equal(waiting.pending?.phase, 'prepared'); assert.match(String(waiting.reason), /waiting for the new version to confirm startup/)
    assert.throws(() => acknowledgeUpdate({ ...f.target, version: '0.1.5' }), { code: 'ownership-mismatch' })
    assert.equal(f.manifest().appHash, before); assert.equal(existsSync(f.receiptFile), true)
    assert.deepEqual(acknowledgeUpdate({ ...f.target, version: '0.2.0' }), { committed: true, pending: false })
    assert.equal(f.manifest().appHash, update.hash); assert.equal(existsSync(f.transaction), false); assert.equal(f.outcome().status, 'updated')
    assert.deepEqual(acknowledgeUpdate({ ...f.target, version: '0.2.0' }), { committed: false, pending: false })
    assert.equal(updateStatus(f.target).managed, true)
  } finally { f.cleanup() }
})
test('the restart authorization needs a live owner and watcher and is refused once the app was replaced', () => {
  const f = fixture()
  try {
    f.installApp()
    const update = f.stageUpdate('0.2.0'), prepared = f.prepare(update.hash)
    assert.equal(authorizeRestart({ ...f.target, transactionId: 'unrelated' }).authorized, false)
    assert.equal(authorizeRestart({ ...f.target, transactionId: prepared.transactionId }).authorized, true)
    assert.equal(f.receipt().restart, true)
    update.replace()
    assert.equal(authorizeRestart({ ...f.target, transactionId: prepared.transactionId }).authorized, false)
    assert.equal(abortUpdate({ ...f.target, transactionId: prepared.transactionId }).aborted, false); assert.equal(existsSync(f.receiptFile), true)
    f.kill(HOST)
    const second = fixture()
    try {
      second.installApp(); const prepared2 = second.prepare(second.stageUpdate('0.2.0').hash); second.kill(HOST)
      assert.equal(authorizeRestart({ ...second.target, transactionId: prepared2.transactionId }).authorized, false)
    } finally { second.cleanup() }
  } finally { f.cleanup() }
})
test('a host that exits without any installation lapses the watcher and leaves the old app and its receipt for recovery', () => {
  const f = fixture()
  try {
    f.installApp()
    const before = appTreeHash(f.app), prepared = f.authorized(f.stageUpdate('0.2.0'))
    f.hostQuits({})
    const result = f.watch(prepared.transactionId)
    assert.equal(result.outcome, 'lapsed'); assert.ok(f.elapsed() >= 5000)
    assert.deepEqual(f.events, []); assert.equal(appTreeHash(f.app), before); assert.equal(existsSync(f.receiptFile), true)
    f.kill(WATCHER)
    assert.equal(updateStatus(f.target).managed, true); assert.equal(existsSync(f.transaction), false)
  } finally { f.cleanup() }
})
test('without startup acknowledgment the replacement is stopped, the previous app restored and the previous job restarted', () => {
  const f = fixture()
  try {
    f.installApp()
    const before = { config: readFileSync(f.config), agent: readFileSync(f.agent), manifest: readFileSync(f.manifestFile), hash: appTreeHash(f.app) }
    const update = f.stageUpdate('0.2.0'), prepared = f.authorized(update)
    f.hostQuits({ update })
    const result = f.watch(prepared.transactionId)
    assert.equal(result.outcome, 'rolled-back'); assert.match(result.message, /did not confirm startup/)
    assert.deepEqual(f.events, ['bootout', 'bootstrap:binary-0.2.0', 'bootout', 'bootstrap:binary-0.1.0'])
    assert.equal(appTreeHash(f.app), before.hash); assert.deepEqual(readFileSync(f.manifestFile), before.manifest)
    assert.deepEqual(readFileSync(f.config), before.config); assert.deepEqual(readFileSync(f.agent), before.agent)
    assert.equal(f.binary(), 'binary-0.1.0'); assert.equal(f.isLoaded(), true)
    assert.equal(existsSync(f.transaction), false); assert.equal(f.outcome().status, 'rolled-back')
    assert.deepEqual(readdirSync(path.dirname(f.app)), ['OMP Usage.app'])
    assert.equal(updateStatus(f.target).managed, true)
  } finally { f.cleanup() }
})
test('a replacement that exits before acknowledging is rolled back long before the readiness deadline', () => {
  const f = fixture()
  try {
    f.installApp()
    const update = f.stageUpdate('0.2.0'), prepared = f.authorized(update)
    f.hostQuits({ update, onRelaunching: () => f.setJobExited(true) })
    const result = runWatcherWithDeadline(f, prepared.transactionId, 45_000)
    assert.equal(result.outcome, 'rolled-back'); assert.match(result.message, /exited before confirming startup/)
    assert.ok(f.elapsed() < 10_000, `elapsed ${f.elapsed()}ms`)
    assert.equal(f.binary(), 'binary-0.1.0')
  } finally { f.cleanup() }
})
/** @param {ReturnType<typeof fixture>} f @param {string} transactionId @param {number} readinessMs */
function runWatcherWithDeadline(f, transactionId, readinessMs) { return runWatcher({ ...f.options, pid: WATCHER, readinessMs, stateDir: f.stateDir, transactionId }) }
test('an app that is not the authenticated update is never started and the previous app is restored', () => {
  const f = fixture()
  try {
    f.installApp()
    const before = appTreeHash(f.app), update = f.stageUpdate('0.2.0'), prepared = f.authorized({ hash: 'b'.repeat(64) })
    f.hostQuits({ update })
    const result = f.watch(prepared.transactionId)
    assert.equal(result.outcome, 'rolled-back'); assert.match(result.message, /did not match the authenticated update/)
    assert.equal(f.events.includes('bootstrap:binary-0.2.0'), false)
    assert.deepEqual(f.events, ['bootout', 'bootstrap:binary-0.1.0'])
    assert.equal(appTreeHash(f.app), before)
    assert.ok(f.elapsed() < 5000, `rollback waited ${f.elapsed()}ms although the installer was already gone`)
  } finally { f.cleanup() }
})
test('a wrong authenticated hash is restored as soon as the installer is gone, never earlier and without waiting out the grace period', () => {
  const f = fixture()
  try {
    f.installApp()
    const before = appTreeHash(f.app), update = f.stageUpdate('0.2.0'), prepared = f.authorized({ hash: 'c'.repeat(64) })
    f.setInstaller('running')
    /** @type {number[]} */
    const checks = []
    f.hostQuits({ update, onPoll: call => {
      if (call === 6) f.setInstaller('idle')
      // While the installer may still write, the unverified tree is neither started nor overwritten.
      if (call > 1 && call < 6) { checks.push(call); assert.deepEqual(f.events, []); assert.equal(appTreeHash(f.app), update.hash) }
    } })
    const result = f.watch(prepared.transactionId)
    assert.equal(result.outcome, 'rolled-back'); assert.match(result.message, /did not match the authenticated update/)
    assert.ok(checks.length > 0)
    // The unverified replacement was never started, only the previous app was, and only after the installer was gone.
    assert.deepEqual(f.events, ['bootout', 'bootstrap:binary-0.1.0']); assert.deepEqual(f.removed, ['gui/123/com.dhkim.omp-usage-panel-sparkle-updater'])
    assert.equal(appTreeHash(f.app), before); assert.equal(f.binary(), 'binary-0.1.0'); assert.equal(f.isLoaded(), true)
    assert.ok(f.elapsed() < 5000, `rollback waited ${f.elapsed()}ms`)
  } finally { f.cleanup() }
})
test('a replacement job that cannot be stopped or inspected is never overwritten and recovery completes the rollback later', () => {
  for (const failure of /** @type {const} */ (['stop', 'inspect'])) {
    const f = fixture()
    try {
      f.installApp()
      const before = appTreeHash(f.app), update = f.stageUpdate('0.2.0'), prepared = f.authorized(update)
      f.hostQuits({ update, onRelaunching: () => { if (failure === 'stop') f.setBootoutFails(true); else f.setPrintFails(true) } })
      const result = f.watch(prepared.transactionId)
      assert.equal(result.outcome, 'failed'); assert.match(result.message, /rollback incomplete/)
      assert.equal(appTreeHash(f.app), update.hash, failure)
      assert.equal(f.receipt().phase, 'rolling-back'); assert.equal(f.outcome().status, 'failed')
      assert.deepEqual(readdirSync(path.dirname(f.app)), ['OMP Usage.app'])
      f.kill(WATCHER)
      assert.equal(updateStatus(f.target).managed, false); assert.equal(appTreeHash(f.app), update.hash)
      f.setBootoutFails(false); f.setPrintFails(false)
      const recovered = recoverUpdate(f.target)
      assert.equal(recovered.managed, true); assert.equal(recovered.pending, null)
      assert.equal(appTreeHash(f.app), before); assert.equal(existsSync(f.transaction), false)
      assert.equal(f.outcome().status, 'rolled-back'); assert.equal(f.binary(), 'binary-0.1.0'); assert.equal(f.isLoaded(), true)
    } finally { f.cleanup() }
  }
})
test('an interrupted relaunch worker is recovered once it is gone, and left alone while it is alive', () => {
  const f = fixture()
  try {
    f.installApp()
    const before = appTreeHash(f.app), update = f.stageUpdate('0.2.0'), prepared = f.authorized(update)
    f.hostQuits({ update, onRelaunching: () => { throw new Error('simulated crash') } })
    assert.throws(() => f.watch(prepared.transactionId), /simulated crash/)
    f.onSleep(null)
    const busy = updateStatus(f.target)
    assert.equal(busy.managed, false); assert.equal(busy.pending?.phase, 'relaunching'); assert.match(String(busy.reason), /being installed/)
    assert.equal(appTreeHash(f.app), update.hash)
    assert.throws(() => install({ ...f.options, node: process.execPath, env: { OMP_BIN: '/bin/sh' } }), liveMessage)
    f.kill(WATCHER)
    const recovered = updateStatus(f.target)
    assert.equal(recovered.managed, true); assert.equal(recovered.outcome?.status, 'rolled-back')
    assert.equal(appTreeHash(f.app), before); assert.equal(f.binary(), 'binary-0.1.0'); assert.equal(existsSync(f.transaction), false)
  } finally { f.cleanup() }
})
test('a first commit from a legacy v1 record preserves the original record byte-for-byte', () => {
  const f = fixture()
  try {
    f.installApp()
    const legacy = JSON.stringify({ ...f.manifest(), version: 1, snapshots: [], opaque: { retained: ['provider', 'metadata'] } }, null, 4) + '\n'
    writeFileSync(f.manifestFile, legacy)
    const update = f.stageUpdate('0.2.0'), prepared = f.authorized(update)
    f.hostQuits({ update, acknowledge: '0.2.0' })
    assert.equal(f.watch(prepared.transactionId).outcome, 'updated')
    assert.equal(readFileSync(path.join(f.stateDir, 'install-v1.json'), 'utf8'), legacy)
    assert.equal(f.manifest().version, 2); assert.equal(f.manifest().appHash, update.hash); assert.equal('snapshots' in f.manifest(), false)
  } finally { f.cleanup() }
})
test('source uninstall and install treat an updated app awaiting acknowledgment as owned and supersede its transaction', () => {
  const f = fixture()
  try {
    f.installApp()
    const config = readFileSync(f.config), update = f.stageUpdate('0.2.0')
    f.prepare(update.hash); f.kill(HOST); f.kill(WATCHER); update.replace()
    uninstall(f.options)
    assert.equal(existsSync(f.app), false); assert.equal(existsSync(f.agent), false); assert.equal(existsSync(f.updater), false)
    assert.deepEqual(readFileSync(f.config), config); assert.deepEqual(f.events, ['bootout'])
    const g = fixture()
    try {
      g.installApp()
      const next = g.stageUpdate('0.2.0')
      g.prepare(next.hash); g.kill(HOST); g.kill(WATCHER); next.replace()
      g.installApp('9.9.9')
      assert.equal(g.binary(), 'binary-9.9.9'); assert.equal(g.manifest().appHash, appTreeHash(g.app)); assert.equal(existsSync(g.transaction), false)
      assert.equal(updateStatus(g.target).managed, true)
    } finally { g.cleanup() }
  } finally { f.cleanup() }
})
test('an app matching neither the old nor the authenticated tree is foreign to source operations until an explicit rollback', () => {
  const f = fixture()
  try {
    f.installApp()
    f.prepare(f.stageUpdate('0.2.0').hash); f.kill(HOST); f.kill(WATCHER)
    writeFileSync(path.join(f.app, 'user-file'), 'keep')
    assert.throws(() => install({ ...f.options, node: process.execPath, env: { OMP_BIN: '/bin/sh' } }), /Foreign or modified app/)
    assert.throws(() => uninstall(f.options), /Foreign or modified app/)
    const status = updateStatus(f.target)
    assert.equal(status.managed, false); assert.match(String(status.reason), /does not match the pending update/)
    assert.equal(readFileSync(path.join(f.app, 'user-file'), 'utf8'), 'keep'); assert.equal(existsSync(f.receiptFile), true)
    const rolledBack = recoverUpdate({ ...f.target, action: 'rollback' })
    assert.equal(rolledBack.managed, true); assert.equal(existsSync(path.join(f.app, 'user-file')), false); assert.equal(existsSync(f.transaction), false)
  } finally { f.cleanup() }
})

test('rollback and source operations wait for positive installer quiescence after an authenticated replacement', () => {
  const f = fixture()
  try {
    f.installApp()
    const before = appTreeHash(f.app), update = f.stageUpdate('0.2.0')
    f.prepare(update.hash); f.kill(HOST); f.kill(WATCHER); update.replace()
    f.setInstaller('running')
    for (const dryRun of [true, false]) assert.throws(() => uninstall({ ...f.options, dryRun }), liveMessage)
    const busy = updateStatus(f.target)
    assert.equal(busy.managed, false); assert.match(String(busy.reason), /being installed/)
    // An explicit rollback is blocked while the installer can still write; nothing is restarted, restored or deleted.
    recoverUpdate({ ...f.target, action: 'rollback' })
    assert.equal(appTreeHash(f.app), update.hash); assert.equal(existsSync(path.join(f.transaction, 'backup/app')), true); assert.deepEqual(f.events, [])
    assert.equal(f.outcome().status, 'failed'); assert.match(f.outcome().message, /installer may still be running/)
    assert.throws(() => uninstall(f.options), /could not be rolled back/)
    f.setInstaller('absent')
    const recovered = recoverUpdate(f.target)
    assert.equal(recovered.managed, true); assert.equal(appTreeHash(f.app), before); assert.equal(f.outcome().status, 'rolled-back')
  } finally { f.cleanup() }
})
test('an unexpected tree is not rolled back, and a running installer blocks explicit recovery until it is gone', () => {
  const f = fixture()
  try {
    f.installApp()
    f.prepare(f.stageUpdate('0.2.0').hash); f.kill(HOST); f.kill(WATCHER)
    writeFileSync(path.join(f.app, 'user-file'), 'keep')
    f.setInstaller('running')
    assert.match(String(updateStatus(f.target).reason), /being installed/)
    recoverUpdate({ ...f.target, action: 'rollback' })
    assert.equal(readFileSync(path.join(f.app, 'user-file'), 'utf8'), 'keep'); assert.deepEqual(f.events, [])
    f.setInstaller('absent')
    assert.equal(recoverUpdate({ ...f.target, action: 'rollback' }).managed, true)
    assert.equal(existsSync(path.join(f.app, 'user-file')), false)
  } finally { f.cleanup() }
})
test('the authorized restart waits until the replacement is complete and the installer is gone, removing its idle leftover', () => {
  const f = fixture()
  try {
    f.installApp()
    const update = f.stageUpdate('0.2.0'), prepared = f.authorized(update)
    f.setInstaller('running')
    f.hostQuits({ update, acknowledge: '0.2.0', onPoll: call => { if (call < 40) assert.deepEqual(f.events, []); if (call === 40) f.setInstaller('idle') } })
    assert.equal(f.watch(prepared.transactionId).outcome, 'updated')
    assert.deepEqual(f.events, ['bootout', 'bootstrap:binary-0.2.0']); assert.deepEqual(f.removed, ['gui/123/com.dhkim.omp-usage-panel-sparkle-updater'])
  } finally { f.cleanup() }
})
test('an acknowledgment is retained, never rolled back, and commits only once the installer is gone', () => {
  const f = fixture()
  try {
    f.installApp()
    const before = appTreeHash(f.app), update = f.stageUpdate('0.2.0')
    f.prepare(update.hash); f.kill(HOST); f.kill(WATCHER); update.replace()
    f.setInstaller('running')
    assert.deepEqual(acknowledgeUpdate({ ...f.target, version: '0.2.0' }), { committed: false, pending: true, reason: 'installer-quiescing' })
    assert.equal(f.receipt().acknowledged, true); assert.equal(f.manifest().appHash, before); assert.equal(existsSync(path.join(f.transaction, 'backup/app')), true)
    assert.throws(() => uninstall({ ...f.options, dryRun: true }), liveMessage)
    f.setInstaller('absent')
    assert.equal(updateStatus(f.target).managed, true)
    assert.equal(f.manifest().appHash, update.hash); assert.equal(existsSync(f.transaction), false); assert.equal(f.outcome().status, 'updated')
    // The watcher variant: the acknowledgment arrives while a lingering installer job runs, past the readiness deadline.
    const g = fixture()
    try {
      g.installApp()
      const next = g.stageUpdate('0.2.0'), prepared = g.authorized(next)
      let relaunching = 0
      g.hostQuits({ update: next, acknowledge: '0.2.0', onRelaunching: () => { relaunching++; if (relaunching === 1) g.setInstaller('running'); if (relaunching === 20) g.setInstaller('absent') } })
      assert.equal(g.watch(prepared.transactionId).outcome, 'updated')
      assert.deepEqual(g.acknowledgments, [{ committed: false, pending: true, reason: 'installer-quiescing' }])
      assert.ok(g.elapsed() > 2000); assert.equal(g.manifest().appHash, next.hash); assert.equal(g.binary(), 'binary-0.2.0')
    } finally { g.cleanup() }
  } finally { f.cleanup() }
})
test('every recovery entry point refuses a destination that differs from the recorded paths and changes nothing', () => {
  const f = fixture()
  try {
    f.installApp()
    const update = f.stageUpdate('0.2.0'), prepared = f.prepare(update.hash)
    f.kill(HOST); f.kill(WATCHER); update.replace()
    const unrelated = path.join(f.home, 'Documents/Unrelated.app'); mkdirSync(unrelated, { recursive: true }); writeFileSync(path.join(unrelated, 'keep'), 'precious')
    const other = { ...f.target, appPath: unrelated }
    assert.throws(() => recoverUpdate({ ...other, action: 'rollback' }), { code: 'ownership-mismatch' })
    assert.throws(() => abortUpdate({ ...other, transactionId: prepared.transactionId }), { code: 'ownership-mismatch' })
    assert.throws(() => revokeUpdate({ ...other, transactionId: prepared.transactionId }), { code: 'ownership-mismatch' })
    assert.throws(() => authorizeRestart({ ...other, transactionId: prepared.transactionId }), { code: 'ownership-mismatch' })
    assert.throws(() => acknowledgeUpdate({ ...other, version: '0.2.0' }), { code: 'ownership-mismatch' })
    assert.throws(() => uninstall({ ...f.options, appPath: unrelated }), { code: 'ownership-mismatch' })
    const status = updateStatus(other)
    assert.equal(status.managed, false); assert.match(String(status.reason), /different installation location/)
    assert.equal(readFileSync(path.join(unrelated, 'keep'), 'utf8'), 'precious'); assert.equal(appTreeHash(f.app), update.hash)
    assert.equal(existsSync(f.receiptFile), true); assert.equal(existsSync(path.join(f.transaction, 'backup/app')), true); assert.deepEqual(f.events, [])
  } finally { f.cleanup() }
})

test('an explicit rollback withdraws an earlier acknowledgment, which can then never be committed over it', () => {
  const f = fixture()
  try {
    f.installApp()
    const before = appTreeHash(f.app), update = f.stageUpdate('0.2.0')
    f.prepare(update.hash); f.kill(HOST); f.kill(WATCHER); update.replace()
    f.setInstaller('running')
    assert.equal(acknowledgeUpdate({ ...f.target, version: '0.2.0' }).reason, 'installer-quiescing')
    recoverUpdate({ ...f.target, action: 'rollback' })
    assert.equal(f.receipt().phase, 'rolling-back'); assert.equal(f.receipt().acknowledged, false)
    f.setInstaller('absent')
    const recovered = updateStatus(f.target)
    assert.equal(recovered.managed, true); assert.equal(appTreeHash(f.app), before); assert.equal(f.manifest().appHash, before)
    assert.equal(f.outcome().status, 'rolled-back')
  } finally { f.cleanup() }
})
test('an acknowledged update whose worker died is retained, not rolled back, until it commits', () => {
  const f = fixture()
  try {
    f.installApp()
    const update = f.stageUpdate('0.2.0'), prepared = f.authorized(update)
    f.hostQuits({ update, onRelaunching: () => { throw new Error('simulated crash') } })
    assert.throws(() => f.watch(prepared.transactionId), /simulated crash/)
    f.onSleep(null); f.setInstaller('running'); f.kill(WATCHER)
    assert.deepEqual(acknowledgeUpdate({ ...f.target, version: '0.2.0' }), { committed: false, pending: true, reason: 'installer-quiescing' })
    assert.equal(updateStatus(f.target).managed, false); assert.equal(f.receipt().acknowledged, true); assert.equal(appTreeHash(f.app), update.hash)
    f.setInstaller('absent')
    assert.equal(updateStatus(f.target).managed, true); assert.equal(f.manifest().appHash, update.hash)
  } finally { f.cleanup() }
})
test('source operations see the update that recovery just committed instead of reporting it foreign', () => {
  const f = fixture()
  try {
    f.installApp()
    const update = f.stageUpdate('0.2.0')
    f.prepare(update.hash); f.kill(HOST); f.kill(WATCHER); update.replace()
    f.setInstaller('running')
    assert.equal(acknowledgeUpdate({ ...f.target, version: '0.2.0' }).pending, true)
    f.setInstaller('absent')
    // The first source operation itself settles and commits the acknowledged update, then verifies against the new record.
    f.installApp('9.9.9')
    assert.equal(f.binary(), 'binary-9.9.9'); assert.equal(f.manifest().appHash, appTreeHash(f.app)); assert.equal(f.outcome().status, 'updated')
    const g = fixture()
    try {
      g.installApp()
      const next = g.stageUpdate('0.2.0')
      g.prepare(next.hash); g.kill(HOST); g.kill(WATCHER); next.replace()
      g.setInstaller('running'); acknowledgeUpdate({ ...g.target, version: '0.2.0' }); g.setInstaller('absent')
      uninstall(g.options)
      assert.equal(existsSync(g.app), false)
    } finally { g.cleanup() }
  } finally { f.cleanup() }
})

/** Copy exactly the trusted runtime files the watcher runs, so the CLI is exercised the way the copied watcher runs. @param {string} home */
function copiedCli(home) {
  const runtime = path.join(home, 'runtime/apps/macos'); mkdirSync(runtime, { recursive: true })
  for (const file of trustedRuntimeFiles) copyFileSync(path.join(sourceDirectory, file), path.join(runtime, file))
  const script = path.join(runtime, 'update-ownership.mjs')
  /** @param {string[]} args @param {string} input */
  const invoke = (args, input) => {
    const run = spawnSync(process.execPath, [script, ...args], { input, encoding: 'utf8', env: { ...process.env, HOME: home } })
    return { status: run.status, payload: JSON.parse(run.stdout), stderr: run.stderr }
  }
  return invoke
}
test('the update CLI answers JSON, rejects malformed requests and runs from the copied trusted runtime alone', t => {
  if (process.platform !== 'darwin') { t.skip('requires macOS'); return }
  const home = mkdtempSync(path.join(tmpdir(), 'omp-update-cli-'))
  try {
    const cli = copiedCli(home), request = { appPath: path.join(home, 'Applications/OMP Usage.app'), configPath: path.join(home, 'config.json') }
    const status = cli(['status'], JSON.stringify(request))
    assert.equal(status.status, 0); assert.equal(status.payload.ok, true); assert.equal(status.payload.command, 'status')
    assert.equal(status.payload.managed, false); assert.match(status.payload.reason, /not installed by the OMP Usage installer/)
    for (const [command, input] of /** @type {[string,string][]} */ ([
      ['status', '{not json'], ['status', '[]'], ['status', JSON.stringify({ ...request, extra: 1 })], ['status', JSON.stringify({ ...request, appPath: 'relative.app' })], ['status', '{}'],
      ['prepare', JSON.stringify(request)], ['prepare', JSON.stringify({ ...request, expectedVersion: '0.2.0', expectedAppTreeSHA256: 'a'.repeat(64), currentVersion: '0.1.0', ownerPid: 'x' })], ['prepare', JSON.stringify({ ...request, expectedVersion: '0.2.0', expectedAppTreeSHA256: 'a'.repeat(64), currentVersion: '0.1.0', ownerPid: 99999 })],
      ['revoke', JSON.stringify(request)],
      ['authorize', JSON.stringify(request)], ['abort', JSON.stringify(request)], ['acknowledge', JSON.stringify(request)], ['relaunch', JSON.stringify(request)], ['bogus', JSON.stringify(request)],
    ])) {
      const failed = cli([command], input)
      assert.equal(failed.status, 1, `${command} ${input}`); assert.equal(failed.payload.ok, false); assert.equal(failed.payload.error.code, 'invalid-request')
    }
    const watch = cli(['watch', JSON.stringify({ stateDir: path.join(home, 'state'), transactionId: 'x', armToken: 'y', extra: true })], '')
    assert.equal(watch.status, 1); assert.equal(watch.payload.error.code, 'invalid-request')
    const unarmed = cli(['watch', JSON.stringify({ stateDir: path.join(home, 'state'), transactionId: 'x', armToken: 'y' })], '')
    assert.equal(unarmed.status, 1); assert.equal(unarmed.payload.error.code, 'no-transaction')
    const acknowledged = cli(['acknowledge'], JSON.stringify({ ...request, version: '0.2.0' }))
    assert.equal(acknowledged.status, 0); assert.deepEqual({ committed: acknowledged.payload.committed, pending: acknowledged.payload.pending }, { committed: false, pending: false })
  } finally { rmSync(home, { recursive: true, force: true }) }
})
