import test from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { appendFileSync, chmodSync, copyFileSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { defaultConfig } from './config.mjs'
import { install, uninstall } from './installation.mjs'
import { runtimeFiles, sourceRoot } from './build.mjs'
import { InstallError, appTreeHash, digest, label, plist } from './ownership.mjs'
import { containingBundle, execute, helperPath, respond } from './setup-install.mjs'

const HOST = 4001, JOB = 4242
const darwin = process.platform === 'darwin'
const identity = `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${label}</string></dict></plist>\n`

/** Setup installs with ditto, codesign and launchd, which only macOS provides. @param {string} name @param {()=>void} body */
function it(name, body) { test(name, { skip: !darwin && 'macOS only' }, body) }
/** @param {string} root @param {string} rel @param {string|Buffer} content @param {number} [mode] */
function put(root, rel, content, mode = 0o644) { const file = path.join(root, rel); mkdirSync(path.dirname(file), { recursive: true }); writeFileSync(file, content); chmodSync(file, mode) }
/** An app shaped like the real bundle: identity, executable, resources and a framework whose entries are relative symlinks.
 * @param {string} root @param {string} [version] */
function makeApp(root, version = '1.0.0') {
  put(root, 'Contents/MacOS/OMPUsagePanel', `binary-${version}`, 0o755)
  put(root, 'Contents/Info.plist', identity)
  put(root, 'Contents/Resources/LICENSE', 'license')
  put(root, 'Contents/Frameworks/Fake.framework/Versions/B/Fake', `framework-${version}`, 0o755)
  symlinkSync('B', path.join(root, 'Contents/Frameworks/Fake.framework/Versions/Current'), 'dir')
  symlinkSync('Versions/Current/Fake', path.join(root, 'Contents/Frameworks/Fake.framework/Fake'), 'file')
  return root
}
/** A bundle with a real Mach-O executable and a real ad-hoc signature, so codesign has something genuine to seal. @param {string} root */
function signedApp(root) {
  put(root, 'Contents/Info.plist', `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>OMPUsagePanel</string><key>CFBundleIdentifier</key><string>${label}</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleName</key><string>OMP Usage</string><key>CFBundleVersion</key><string>1.0.0</string></dict></plist>\n`)
  mkdirSync(path.join(root, 'Contents/MacOS'), { recursive: true })
  const executable = path.join(root, 'Contents/MacOS/OMPUsagePanel')
  copyFileSync('/usr/bin/true', executable); chmodSync(executable, 0o755)
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', root], { stdio: 'ignore' })
  return root
}
/** The packaged app: the bundle plus the exact runtime inventory the build ships, and nothing else (no Swift, Xcode or checkout). @param {string} directory */
function packagedBundle(directory) {
  const bundle = makeApp(path.join(directory, 'OMP Usage.app'))
  for (const file of runtimeFiles) {
    const target = path.join(bundle, 'Contents/Resources/runtime', file)
    mkdirSync(path.dirname(target), { recursive: true }); copyFileSync(path.join(sourceRoot, file), target)
  }
  return bundle
}
/** @param {string} file @param {string} name @returns {string|null} */
function attribute(file, name) {
  const result = spawnSync('/usr/bin/xattr', ['-p', name, file], { encoding: 'utf8' })
  return result.status === 0 ? result.stdout.trim() : null
}
/** @param {()=>unknown} action */
function failure(action) {
  try { action() } catch (error) { if (error instanceof InstallError) return error; throw error }
  return assert.fail('Expected the operation to fail')
}

function fixture() {
  const home = mkdtempSync(path.join(tmpdir(), 'omp-setup-test-'))
  const stateDir = path.join(home, 'Library/Application Support/omp-usage-panel')
  const config = path.join(stateDir, 'config.json'), stateFile = path.join(stateDir, 'install.json')
  const app = path.join(home, 'Applications/OMP Usage.app'), agent = path.join(home, `Library/LaunchAgents/${label}.plist`)
  const download = makeApp(path.join(home, 'Downloads/OMP Usage.app'))
  const tools = path.join(home, 'tools'), node = path.join(tools, 'node'), omp = path.join(tools, 'omp')
  put(tools, 'node', '#!/bin/sh\n', 0o755); put(tools, 'omp', '#!/bin/sh\n', 0o755)
  let loaded = false, pid = 0, foreign = false, failStart = false, signature = true, starts = 0, stops = 0, kicks = 0
  /** @type {(()=>void)|null} */
  let onSignature = null
  /** @type {{file:string, args:string[]}[]} */
  const commands = []
  /** A launchd that models what the helper may touch: loaded/idle/running jobs, never -k, and nothing else. @param {string} file @param {string[]} args */
  function run(file, args) {
    commands.push({ file, args })
    if (file === '/usr/bin/codesign') { onSignature?.(); if (!signature) throw new Error('invalid signature'); return '' }
    if (file === '/bin/launchctl') {
      if (args[0] === 'print') {
        // Only the app's own job exists; Sparkle's host-specific installer jobs are absent unless a test says otherwise.
        if (!loaded || args[1] !== `gui/123/${label}`) throw Object.assign(new Error('not running'), { status: 113, stderr: 'Could not find service' })
        const program = foreign ? '/foreign/program' : path.join(app, 'Contents/MacOS/OMPUsagePanel')
        return `job = {\n\tpath = ${agent}\n\tstate = ${pid ? 'running' : 'not running'}\n${pid ? `\tpid = ${pid}\n` : ''}\tprogram = ${program}\n\targuments = {\n\t\t${program}\n\t\t--config\n\t\t${config}\n\t}\n}`
      }
      if (args[0] === 'bootout') { stops++; loaded = false; pid = 0; return '' }
      if (args[0] === 'bootstrap') { if (failStart) { failStart = false; throw new Error('bootstrap failed') } loaded = true; pid = JOB; starts++; return '' }
      if (args[0] === 'kickstart') { if (!loaded || args.includes('-k')) throw new Error('kickstart refused'); kicks++; if (!pid) pid = JOB; return '' }
    }
    throw new Error(`Unexpected command: ${file} ${args.join(' ')}`)
  }
  const options = { home, platform: 'darwin', run, uid: 123, sleep() {}, bundle: download }
  /** @param {Record<string,unknown>} [extra] */
  const request = (extra = {}) => ({ sourceAppPath: download, hostPid: HOST, ompPath: omp, profile: 'work', ...extra })
  /** @param {Record<string,unknown>} [extra] @param {Partial<import('./setup-install.mjs').SetupOptions>} [more] */
  const setup = (extra, more) => execute('install', request(extra), { ...options, ...more })
  /** The Finder launch of the app at `bundle`, from the process `hostPid`. @param {string} bundle @param {number} [hostPid] */
  const launch = (bundle, hostPid = HOST) => execute('launch', { sourceAppPath: bundle, hostPid }, { ...options, bundle })
  /** launchctl verbs issued since `from` commands had been recorded. @param {number} from */
  const verbs = from => commands.slice(from).filter(command => command.file === '/bin/launchctl').map(command => command.args[0])
  const manifest = () => JSON.parse(readFileSync(stateFile, 'utf8'))
  return {
    home, stateDir, config, stateFile, app, agent, download, node, omp, commands, options, request, setup, launch, verbs, manifest,
    isLoaded: () => loaded, jobPid: () => pid, starts: () => starts, stops: () => stops, kicks: () => kicks,
    quit() { pid = 0 }, unload() { loaded = false; pid = 0 }, foreignJob() { foreign = true; loaded = true; pid = 0 },
    failNextStart() { failStart = true }, breakSignature() { signature = false },
    /** @param {()=>void} hook */
    whenSignatureChecked(hook) { onSignature = hook },
    /** A new release replaces the download. @param {string} version */
    release(version) { rmSync(download, { recursive: true }); makeApp(download, version) },
    /** Everything that is not the install itself: leftovers beside the app. */
    leftovers() { return existsSync(path.dirname(app)) ? readdirSync(path.dirname(app)).filter(name => name !== 'OMP Usage.app') : [] },
    cleanup() { rmSync(home, { recursive: true, force: true }) },
  }
}
/** @param {ReturnType<typeof fixture>} f */
function assertNothingInstalled(f) {
  assert.equal(existsSync(f.app), false); assert.equal(existsSync(f.agent), false); assert.equal(existsSync(f.stateFile), false); assert.equal(f.isLoaded(), false); assert.deepEqual(f.leftovers(), [])
}
/** @param {ReturnType<typeof fixture>} f @param {string} [version] */
function installed(f, version = '1.0.0') {
  f.setup()
  assert.equal(readFileSync(path.join(f.app, 'Contents/MacOS/OMPUsagePanel'), 'utf8'), `binary-${version}`)
}

it('installs the prebuilt app from an uncanonical copy, creates the configuration and starts the registered job', () => {
  const f = fixture()
  try {
    const hash = appTreeHash(f.download)
    assert.deepEqual(f.setup(), { action: 'relaunch', appPath: f.app, configPath: f.config })
    assert.equal(appTreeHash(f.app), hash); assert.equal(appTreeHash(f.download), hash)
    assert.equal(statSync(path.join(f.app, 'Contents/MacOS/OMPUsagePanel')).mode & 0o777, 0o755)
    assert.deepEqual(f.manifest(), { version: 2, appPath: f.app, agentPath: f.agent, appHash: hash, agentHash: digest(readFileSync(f.agent)) })
    assert.deepEqual(JSON.parse(readFileSync(f.config, 'utf8')), defaultConfig({ nodePath: process.execPath, ompPath: f.omp, profile: 'work' }))
    assert.equal(statSync(f.config).mode & 0o777, 0o600)
    assert.equal(f.isLoaded(), true); assert.equal(f.starts(), 1); assert.deepEqual(f.leftovers(), [])
    // The signature that was verified is the installed copy's, never the source's.
    const verified = f.commands.filter(command => command.file === '/usr/bin/codesign')
    assert.equal(verified.length, 1); assert.deepEqual(verified[0]?.args.slice(0, 3), ['--verify', '--deep', '--strict']); assert.notEqual(verified[0]?.args[3], f.download)
    // Nothing but the app, its configuration, the manifest and the LaunchAgent is created; no provider or plugin command ran.
    assert.deepEqual(readdirSync(f.home).sort(), ['Applications', 'Downloads', 'Library', 'tools'])
    assert.equal(f.commands.some(command => command.args[0] === 'plugin'), false)
  } finally { f.cleanup() }
})
it('records the helper\'s own Node in a fresh configuration, and the shared uninstall removes what setup installed', () => {
  const f = fixture()
  try {
    f.setup()
    assert.equal(JSON.parse(readFileSync(f.config, 'utf8')).nodePath, process.execPath)
    const original = readFileSync(f.config, 'utf8')
    uninstall(f.options)
    assert.equal(existsSync(f.app), false); assert.equal(existsSync(f.agent), false); assert.equal(readFileSync(f.config, 'utf8'), original); assert.equal(f.isLoaded(), false)
  } finally { f.cleanup() }
})
it('preserves quarantine and other extended attributes and relative framework symlinks through the copy', () => {
  const f = fixture()
  try {
    const executable = path.join(f.download, 'Contents/MacOS/OMPUsagePanel')
    for (const target of [f.download, executable]) {
      execFileSync('/usr/bin/xattr', ['-w', 'com.omp.test', 'kept', target])
      execFileSync('/usr/bin/xattr', ['-w', 'com.apple.quarantine', '0083;5f3e9a1c;Safari;3F2504E0-4F89-11D3-9A0C-0305E82C3301', target])
    }
    f.setup()
    for (const target of [f.app, path.join(f.app, 'Contents/MacOS/OMPUsagePanel')]) {
      assert.equal(attribute(target, 'com.omp.test'), 'kept')
      assert.notEqual(attribute(target, 'com.apple.quarantine'), null)
    }
    const framework = path.join(f.app, 'Contents/Frameworks/Fake.framework')
    assert.equal(readlinkSync(path.join(framework, 'Versions/Current')), 'B'); assert.equal(readlinkSync(path.join(framework, 'Fake')), 'Versions/Current/Fake')
    assert.equal(f.manifest().appHash, appTreeHash(f.app))
  } finally { f.cleanup() }
})
it('never builds from source: the prebuilt engine path runs without any build', () => {
  const f = fixture()
  try {
    install({ ...f.options, prebuilt: { app: realpathSync(f.download) }, node: f.node, omp: f.omp, profile: 'work', build() { throw new Error('a source build must not run') } })
    assert.equal(appTreeHash(f.app), appTreeHash(f.download))
  } finally { f.cleanup() }
})
it('verifies a real ad-hoc signature on the installed copy and refuses a tampered source', () => {
  const f = fixture(), g = fixture()
  try {
    /** @param {string} file @param {string[]} args */
    const run = (file, args) => file === '/usr/bin/codesign' ? execFileSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }) : f.options.run(file, args)
    rmSync(f.download, { recursive: true }); signedApp(f.download)
    f.setup({}, { run })
    execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', f.app])
    assert.equal(appTreeHash(f.app), appTreeHash(f.download))

    /** @param {string} file @param {string[]} args */
    const runG = (file, args) => file === '/usr/bin/codesign' ? execFileSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }) : g.options.run(file, args)
    rmSync(g.download, { recursive: true }); signedApp(g.download)
    appendFileSync(path.join(g.download, 'Contents/Info.plist'), '<!-- tampered after signing -->\n')
    assert.equal(failure(() => g.setup({}, { run: runG })).code, 'invalid-source')
    assertNothingInstalled(g); assert.equal(existsSync(g.config), false)
  } finally { f.cleanup(); g.cleanup() }
})

it('refuses a copy whose signature does not verify before replacing or creating anything', () => {
  const f = fixture()
  try {
    f.breakSignature()
    assert.equal(failure(() => f.setup()).code, 'invalid-source')
    assertNothingInstalled(f); assert.equal(existsSync(f.config), false)
  } finally { f.cleanup() }
})
it('refuses sources that are not a clean OMP Usage bundle before any copy', () => {
  const f = fixture()
  try {
    symlinkSync('../../../outside', path.join(f.download, 'Contents/escape'))
    assert.equal(failure(() => f.setup()).code, 'invalid-source')
    rmSync(path.join(f.download, 'Contents/escape'))
    put(f.download, 'Contents/Info.plist', '<plist/>')
    assert.equal(failure(() => f.setup()).code, 'invalid-source')
    put(f.download, 'Contents/Info.plist', identity); rmSync(path.join(f.download, 'Contents/MacOS/OMPUsagePanel'))
    assert.equal(failure(() => f.setup()).code, 'invalid-source')
    assert.equal(existsSync(path.dirname(f.app)), false); assert.equal(existsSync(f.stateFile), false); assert.equal(existsSync(f.config), false)
    const payload = makeApp(path.join(f.home, 'Downloads/payload'))
    assert.equal(failure(() => f.setup({ sourceAppPath: payload }, { bundle: payload })).code, 'invalid-source')
  } finally { f.cleanup() }
})

it('adopts a fresh copy launched at the canonical destination in place, without copying or replacing it', () => {
  const f = fixture()
  try {
    mkdirSync(path.dirname(f.app), { recursive: true }); cpSync(f.download, f.app, { recursive: true, verbatimSymlinks: true })
    const inode = lstatSync(f.app).ino, hash = appTreeHash(f.app)
    assert.deepEqual(f.setup({ sourceAppPath: f.app }, { bundle: f.app }), { action: 'relaunch', appPath: f.app, configPath: f.config })
    assert.equal(lstatSync(f.app).ino, inode); assert.equal(appTreeHash(f.app), hash); assert.deepEqual(f.leftovers(), [])
    assert.deepEqual(f.manifest(), { version: 2, appPath: f.app, agentPath: f.agent, appHash: hash, agentHash: digest(readFileSync(f.agent)) })
    assert.equal(f.commands.filter(command => command.file === '/usr/bin/codesign')[0]?.args[3], f.app)
    assert.equal(f.isLoaded(), true); assert.equal(existsSync(f.config), true)
  } finally { f.cleanup() }
})
it('adopts nothing else: foreign agents and jobs, modified tracked apps, links and unrelated apps are refused', () => {
  const f = fixture()
  try {
    mkdirSync(path.dirname(f.app), { recursive: true }); cpSync(f.download, f.app, { recursive: true, verbatimSymlinks: true })
    const self = { sourceAppPath: f.app }, hash = appTreeHash(f.app)
    // A LaunchAgent the installer did not write is never blessed.
    mkdirSync(path.dirname(f.agent), { recursive: true }); writeFileSync(f.agent, 'user agent')
    assert.equal(failure(() => f.setup(self, { bundle: f.app })).code, 'foreign-agent')
    assert.equal(readFileSync(f.agent, 'utf8'), 'user agent'); rmSync(f.agent)
    // Neither is a loaded job that is not this app's.
    f.foreignJob()
    assert.equal(failure(() => f.setup(self, { bundle: f.app })).code, 'foreign-job')
    assert.equal(f.stops(), 0); f.unload()
    assert.equal(appTreeHash(f.app), hash); assert.equal(existsSync(f.stateFile), false); assert.equal(existsSync(f.config), false)
    // A destination that is a link to some other copy is not the app: it is not adopted either.
    rmSync(f.app, { recursive: true }); symlinkSync(f.download, f.app, 'dir')
    assert.equal(failure(() => f.setup({}, { bundle: f.download })).code, 'invalid-source')
    assert.equal(lstatSync(f.app).isSymbolicLink(), true); assert.equal(existsSync(f.agent), false)
    rmSync(f.app)
    // A different, unrelated app at the destination is foreign to a copy that is installed from elsewhere.
    mkdirSync(f.app); writeFileSync(path.join(f.app, 'user-file'), 'keep')
    assert.equal(failure(() => f.setup()).code, 'foreign-app')
    assert.equal(readFileSync(path.join(f.app, 'user-file'), 'utf8'), 'keep'); assert.equal(existsSync(f.agent), false); assert.equal(f.isLoaded(), false)
  } finally { f.cleanup() }
})
it('refuses to adopt a tracked app that was modified', () => {
  const f = fixture()
  try {
    installed(f); f.quit()
    writeFileSync(path.join(f.app, 'user-file'), 'modified')
    assert.equal(failure(() => f.setup({ sourceAppPath: f.app }, { bundle: f.app })).code, 'foreign-app')
    assert.equal(readFileSync(path.join(f.app, 'user-file'), 'utf8'), 'modified'); assert.equal(f.stops(), 0)
  } finally { f.cleanup() }
})
it('repairs a tracked, unmodified app launched in place whose LaunchAgent is gone', () => {
  const f = fixture()
  try {
    installed(f); f.quit(); f.unload(); rmSync(f.agent)
    const hash = appTreeHash(f.app), inode = lstatSync(f.app).ino
    f.setup({ sourceAppPath: f.app }, { bundle: f.app })
    assert.equal(lstatSync(f.app).ino, inode); assert.equal(f.manifest().appHash, hash); assert.equal(existsSync(f.agent), true); assert.equal(f.isLoaded(), true)
  } finally { f.cleanup() }
})

it('refuses an untracked app, a foreign LaunchAgent and a foreign loaded job without touching them', () => {
  const f = fixture()
  try {
    mkdirSync(f.app, { recursive: true }); writeFileSync(path.join(f.app, 'user-file'), 'keep')
    assert.equal(failure(() => f.setup()).code, 'foreign-app')
    assert.equal(readFileSync(path.join(f.app, 'user-file'), 'utf8'), 'keep'); rmSync(f.app, { recursive: true })
    mkdirSync(path.dirname(f.agent), { recursive: true }); writeFileSync(f.agent, 'user agent')
    assert.equal(failure(() => f.setup()).code, 'foreign-agent')
    assert.equal(readFileSync(f.agent, 'utf8'), 'user agent'); rmSync(f.agent)
    f.foreignJob()
    assert.equal(failure(() => f.setup()).code, 'foreign-job')
    assert.equal(f.stops(), 0); assert.equal(f.isLoaded(), true)
    assert.equal(existsSync(f.app), false); assert.equal(existsSync(f.config), false); assert.equal(existsSync(f.stateFile), false); assert.deepEqual(f.leftovers(), [])
  } finally { f.cleanup() }
})
it('refuses a tracked installation whose app or agent was modified, and an unreadable manifest', () => {
  const f = fixture()
  try {
    installed(f); f.quit()
    writeFileSync(path.join(f.app, 'user-file'), 'modified')
    assert.equal(failure(() => f.setup()).code, 'foreign-app')
    rmSync(path.join(f.app, 'user-file')); writeFileSync(f.agent, 'modified')
    assert.equal(failure(() => f.setup()).code, 'foreign-agent')
    assert.equal(readFileSync(f.agent, 'utf8'), 'modified')
    const manifest = readFileSync(f.stateFile, 'utf8'); writeFileSync(f.stateFile, '{ not json')
    assert.equal(failure(() => f.setup()).code, 'manifest-invalid')
    assert.equal(readFileSync(f.stateFile, 'utf8'), '{ not json'); assert.equal(f.stops(), 0)
    writeFileSync(f.stateFile, manifest)
  } finally { f.cleanup() }
})
it('rolls a failed first installation back completely', () => {
  const f = fixture()
  try {
    f.failNextStart()
    assert.equal(failure(() => f.setup()).code, 'install-failed')
    assertNothingInstalled(f); assert.equal(existsSync(f.config), false)
  } finally { f.cleanup() }
})
it('restores the previous app, agent, record and idle job when replacing an installation fails', () => {
  const f = fixture()
  try {
    installed(f); f.quit()
    const executable = path.join(f.app, 'Contents/MacOS/OMPUsagePanel'), agent = readFileSync(f.agent, 'utf8'), manifest = readFileSync(f.stateFile, 'utf8'), config = readFileSync(f.config, 'utf8')
    f.release('2.0.0'); f.failNextStart()
    assert.equal(failure(() => f.setup()).code, 'install-failed')
    assert.equal(readFileSync(executable, 'utf8'), 'binary-1.0.0'); assert.equal(readFileSync(f.agent, 'utf8'), agent); assert.equal(readFileSync(f.stateFile, 'utf8'), manifest); assert.equal(readFileSync(f.config, 'utf8'), config)
    assert.equal(f.isLoaded(), true); assert.deepEqual(f.leftovers(), [])
  } finally { f.cleanup() }
})
it('never signals a running app: it reports running until the user quits it, then replaces the idle job', () => {
  const f = fixture()
  try {
    installed(f)
    const executable = path.join(f.app, 'Contents/MacOS/OMPUsagePanel'), manifest = readFileSync(f.stateFile, 'utf8')
    f.release('2.0.0')
    const from = f.commands.length
    assert.equal(failure(() => f.setup()).code, 'running')
    assert.equal(f.stops(), 0); assert.equal(f.jobPid(), JOB); assert.deepEqual(f.verbs(from), ['print'])
    assert.equal(readFileSync(executable, 'utf8'), 'binary-1.0.0'); assert.equal(readFileSync(f.stateFile, 'utf8'), manifest); assert.deepEqual(f.leftovers(), [])
    f.quit()
    f.setup()
    assert.equal(readFileSync(executable, 'utf8'), 'binary-2.0.0'); assert.equal(f.stops(), 1); assert.equal(f.isLoaded(), true); assert.equal(f.jobPid(), JOB)
  } finally { f.cleanup() }
})
it('refuses while a Sparkle update transaction is live and changes nothing', () => {
  const f = fixture()
  try {
    installed(f); f.quit()
    const transaction = path.join(f.stateDir, 'updater/transaction'), state = f.manifest()
    mkdirSync(transaction, { recursive: true, mode: 0o700 }); chmodSync(path.join(f.stateDir, 'updater'), 0o700)
    writeFileSync(path.join(transaction, 'receipt.json'), JSON.stringify({ schema: 1, id: randomUUID(), phase: 'prepared', createdAt: Date.now(), fromVersion: '1.0.0', toVersion: '1.1.0', oldHash: state.appHash, expectedHash: 'e'.repeat(64), appPath: f.app, agentPath: f.agent, configPath: f.config, stateDir: f.stateDir, agentHash: state.agentHash, node: f.node, jobLoaded: true, hostPid: process.pid, hostStart: null, restart: false, revoked: false, watcherPid: null, watcherStart: null, armToken: null, workerPid: null, workerStart: null, acknowledged: false, deadline: null, error: null }))
    f.release('2.0.0')
    assert.equal(failure(() => f.setup()).code, 'update-in-progress')
    assert.equal(failure(() => f.launch(f.app)).code, 'update-in-progress')
    assert.equal(readFileSync(path.join(f.app, 'Contents/MacOS/OMPUsagePanel'), 'utf8'), 'binary-1.0.0'); assert.equal(f.stops(), 0)
  } finally { f.cleanup() }
})
it('reports ownership-mismatch, not a generic failure, for a pending update recorded for another location and changes nothing', () => {
  const f = fixture()
  try {
    installed(f); f.quit(); f.unload()
    const state = f.manifest(), updater = path.join(f.stateDir, 'updater'), transaction = path.join(updater, 'transaction'), backup = path.join(transaction, 'backup'), receipt = path.join(transaction, 'receipt.json')
    mkdirSync(backup, { recursive: true, mode: 0o700 }); chmodSync(updater, 0o700)
    cpSync(f.app, path.join(backup, 'app'), { recursive: true, verbatimSymlinks: true }); copyFileSync(f.stateFile, path.join(backup, 'install.json'))
    rmSync(f.app, { recursive: true }); makeApp(f.app, '2.0.0')
    const elsewhere = path.join(f.home, 'Documents/Elsewhere.app')
    writeFileSync(receipt, JSON.stringify({ schema: 1, id: randomUUID(), phase: 'prepared', createdAt: Date.now(), fromVersion: '1.0.0', toVersion: '2.0.0', oldHash: state.appHash, expectedHash: appTreeHash(f.app), appPath: elsewhere, agentPath: f.agent, configPath: f.config, stateDir: f.stateDir, agentHash: state.agentHash, node: f.node, jobLoaded: true, hostPid: 4999, hostStart: null, restart: false, revoked: false, watcherPid: null, watcherStart: null, armToken: null, workerPid: null, workerStart: null, acknowledged: false, deadline: null, error: null }))
    const preserved = () => ({ receipt: readFileSync(receipt, 'utf8'), backupApp: appTreeHash(path.join(backup, 'app')), backupRecord: readFileSync(path.join(backup, 'install.json'), 'utf8'), record: readFileSync(f.stateFile, 'utf8'), config: readFileSync(f.config, 'utf8'), app: appTreeHash(f.app), agent: readFileSync(f.agent, 'utf8') })
    const before = preserved(), gone = { alive: () => false }
    /** @type {[string, () => Record<string, unknown>][]} */
    const attempts = [['install', () => f.setup({}, gone)], ['launch', () => execute('launch', { sourceAppPath: f.app, hostPid: HOST }, { ...f.options, ...gone, bundle: f.app })]]
    for (const [command, run] of attempts) {
      const { exitCode, payload } = respond(command, run), failed = /** @type {{ok:boolean, error?:{code:string}}} */ (payload)
      assert.equal(exitCode, 1); assert.equal(failed.ok, false); assert.equal(failed.error?.code, 'ownership-mismatch')
    }
    assert.deepEqual(preserved(), before); assert.equal(f.stops(), 0); assert.equal(f.isLoaded(), false); assert.deepEqual(f.leftovers(), [])
  } finally { f.cleanup() }
})
it('never supersedes an unacknowledged update replacement: its receipt, backup, record and configuration stay byte for byte', () => {
  const f = fixture()
  try {
    installed(f); f.quit(); f.unload()
    const state = f.manifest(), updater = path.join(f.stateDir, 'updater'), transaction = path.join(updater, 'transaction'), backup = path.join(transaction, 'backup'), receipt = path.join(transaction, 'receipt.json')
    mkdirSync(backup, { recursive: true, mode: 0o700 }); chmodSync(updater, 0o700)
    cpSync(f.app, path.join(backup, 'app'), { recursive: true, verbatimSymlinks: true }); copyFileSync(f.stateFile, path.join(backup, 'install.json'))
    // Sparkle replaced the app and the new version has not confirmed startup; neither its host nor a watcher is alive any more.
    rmSync(f.app, { recursive: true }); makeApp(f.app, '2.0.0')
    writeFileSync(receipt, JSON.stringify({ schema: 1, id: randomUUID(), phase: 'prepared', createdAt: Date.now(), fromVersion: '1.0.0', toVersion: '2.0.0', oldHash: state.appHash, expectedHash: appTreeHash(f.app), appPath: f.app, agentPath: f.agent, configPath: f.config, stateDir: f.stateDir, agentHash: state.agentHash, node: f.node, jobLoaded: true, hostPid: 4999, hostStart: null, restart: false, revoked: false, watcherPid: null, watcherStart: null, armToken: null, workerPid: null, workerStart: null, acknowledged: false, deadline: null, error: null }))
    const preserved = () => ({ receipt: readFileSync(receipt, 'utf8'), backupApp: appTreeHash(path.join(backup, 'app')), backupRecord: readFileSync(path.join(backup, 'install.json'), 'utf8'), record: readFileSync(f.stateFile, 'utf8'), config: readFileSync(f.config, 'utf8'), app: appTreeHash(f.app), agent: readFileSync(f.agent, 'utf8') })
    const before = preserved(), gone = { alive: () => false }
    assert.equal(failure(() => f.setup({}, gone)).code, 'update-in-progress')
    assert.equal(failure(() => f.setup({ sourceAppPath: f.app }, { ...gone, bundle: f.app })).code, 'update-in-progress')
    assert.equal(failure(() => execute('launch', { sourceAppPath: f.app, hostPid: HOST }, { ...f.options, ...gone, bundle: f.app })).code, 'update-in-progress')
    assert.deepEqual(preserved(), before); assert.equal(f.stops(), 0); assert.equal(f.isLoaded(), false); assert.deepEqual(f.leftovers(), [])
  } finally { f.cleanup() }
})

it('keeps a valid existing configuration byte for byte and lets its paths and profile win', () => {
  const f = fixture()
  try {
    const bytes = JSON.stringify({ ...defaultConfig({ nodePath: f.node, ompPath: f.omp, profile: 'existing' }), refreshSeconds: 30 }, null, 4) + '\n'
    mkdirSync(f.stateDir, { recursive: true }); writeFileSync(f.config, bytes)
    // The request's values are never consulted, not even validated against the filesystem, while a valid configuration exists.
    f.setup({ ompPath: '/does/not/exist/omp', profile: 'other' })
    assert.equal(readFileSync(f.config, 'utf8'), bytes)
    // Retained across a later install too, and across uninstall.
    f.quit(); f.setup({}); uninstall(f.options)
    assert.equal(readFileSync(f.config, 'utf8'), bytes)
  } finally { f.cleanup() }
})
it('refuses an invalid or unreadable existing configuration without overwriting it', () => {
  const f = fixture()
  try {
    mkdirSync(f.stateDir, { recursive: true })
    for (const bytes of ['{ not json', '{"version":1}', '[]', '']) {
      writeFileSync(f.config, bytes)
      assert.equal(failure(() => f.setup()).code, 'config-invalid')
      assert.equal(readFileSync(f.config, 'utf8'), bytes); assertNothingInstalled(f)
    }
    rmSync(f.config); mkdirSync(f.config)
    assert.equal(failure(() => f.setup()).code, 'config-invalid'); assert.equal(lstatSync(f.config).isDirectory(), true)
    rmSync(f.config, { recursive: true }); symlinkSync(path.join(f.home, 'missing-config.json'), f.config)
    assert.equal(failure(() => f.setup()).code, 'config-invalid'); assert.equal(readlinkSync(f.config), path.join(f.home, 'missing-config.json'))
    assertNothingInstalled(f)
  } finally { f.cleanup() }
})
it('installs, launches and keeps an existing configuration byte for byte even when its legacy Node path no longer exists', () => {
  const f = fixture()
  try {
    const bytes = JSON.stringify(defaultConfig({ nodePath: path.join(f.home, 'tools/missing-node'), ompPath: f.omp }), null, 2) + '\n'
    mkdirSync(f.stateDir, { recursive: true }); writeFileSync(f.config, bytes)
    f.setup()
    assert.equal(readFileSync(f.config, 'utf8'), bytes)
    assert.equal(existsSync(f.app), true); assert.equal(f.isLoaded(), true)
    f.quit()
    assert.deepEqual(f.launch(f.app), { action: 'relaunch', appPath: f.app, configPath: f.config })
    assert.equal(readFileSync(f.config, 'utf8'), bytes)
    assert.equal(f.commands.some(command => command.args[0] === '--version'), false)
  } finally { f.cleanup() }
})
it('accepts an existing valid configuration whose omp is missing, retaining it byte for byte', () => {
  const f = fixture()
  try {
    const bytes = JSON.stringify(defaultConfig({ nodePath: f.node, ompPath: path.join(f.home, 'tools/missing-omp'), profile: 'existing' }), null, 2) + '\n'
    mkdirSync(f.stateDir, { recursive: true }); writeFileSync(f.config, bytes)
    // Setup needs no omp: the authoritative configuration's omp and profile are neither validated nor rewritten.
    f.setup({ ompPath: undefined, profile: undefined })
    assert.equal(readFileSync(f.config, 'utf8'), bytes)
    assert.equal(existsSync(f.app), true); assert.equal(f.isLoaded(), true); assert.equal(f.manifest().appHash, appTreeHash(f.app))
  } finally { f.cleanup() }
})
it('never overwrites a configuration that appears while the install is running', () => {
  const f = fixture()
  try {
    // The configuration is absent when setup decides to create it and present when it is about to be written.
    f.whenSignatureChecked(() => writeFileSync(f.config, 'created meanwhile'))
    assert.equal(failure(() => f.setup()).code, 'config-changed')
    assert.equal(readFileSync(f.config, 'utf8'), 'created meanwhile'); assertNothingInstalled(f)
  } finally { f.cleanup() }
})

it('validates the omp and profile choices before anything is created', () => {
  const f = fixture()
  try {
    const plain = path.join(f.home, 'tools/data')
    put(f.home, 'tools/data', 'data', 0o644)
    /** @type {[Record<string,unknown>, string][]} */
    const cases = [
      [{ ompPath: 'omp' }, 'omp-unavailable'], [{ ompPath: path.join(f.home, 'tools/missing') }, 'omp-unavailable'], [{ ompPath: path.join(f.home, 'tools') }, 'omp-unavailable'], [{ ompPath: plain }, 'omp-unavailable'],
      [{ profile: '' }, 'invalid-profile'], [{ profile: '   ' }, 'invalid-profile'], [{ profile: 'bad\nname' }, 'invalid-profile'],
    ]
    for (const [extra, code] of cases) { assert.equal(failure(() => f.setup(extra)).code, code, JSON.stringify(extra)); assertNothingInstalled(f); assert.equal(existsSync(f.config), false) }
    // Without an explicit omp the same discovery as macos:install applies, and an environment that offers none is a clear refusal.
    assert.equal(failure(() => f.setup({ ompPath: undefined }, { env: {} })).code, 'omp-unavailable')
    assertNothingInstalled(f)
  } finally { f.cleanup() }
})
it('accepts only the strict request fields and only from the app that contains the helper', () => {
  const f = fixture()
  try {
    const other = makeApp(path.join(f.home, 'Downloads/Other.app'))
    /** @type {[string, unknown, string][]} */
    const cases = [
      ['install', f.request({ extra: 1 }), 'invalid-request'], ['launch', { sourceAppPath: f.app, hostPid: HOST, nodePath: f.node }, 'invalid-request'],
      ['install', f.request({ sourceAppPath: 'relative/OMP Usage.app' }), 'invalid-request'], ['install', f.request({ sourceAppPath: undefined }), 'invalid-request'],
      ['install', f.request({ hostPid: 1 }), 'invalid-request'], ['install', f.request({ hostPid: '4001' }), 'invalid-request'], ['install', f.request({ hostPid: 1.5 }), 'invalid-request'], ['install', f.request({ hostPid: undefined }), 'invalid-request'],
      ['install', f.request({ nodePath: f.node }), 'invalid-request'], ['install', f.request({ nodePath: process.execPath }), 'invalid-request'], ['install', f.request({ profile: null }), 'invalid-request'],
      ['install', [], 'invalid-request'], ['install', null, 'invalid-request'], ['upgrade', f.request(), 'invalid-request'],
      ['install', f.request({ sourceAppPath: other }), 'source-mismatch'], ['install', f.request({ sourceAppPath: path.join(f.home, 'Downloads/Missing.app') }), 'source-mismatch'],
      ['install', f.request({ sourceAppPath: path.dirname(f.download) }), 'source-mismatch'],
    ]
    for (const [command, value, code] of cases) assert.equal(failure(() => execute(command, value, f.options)).code, code, `${command} ${JSON.stringify(value)}`)
    assert.deepEqual(f.commands, []); assertNothingInstalled(f)
  } finally { f.cleanup() }
})

it('hands a Finder launch of the managed app to its job: activate a running one, continue as the job, kickstart an idle one, bootstrap an unloaded one', () => {
  const f = fixture()
  try {
    installed(f)
    /** @param {number} from @param {string[]} expected */
    const issued = (from, expected) => assert.deepEqual(f.verbs(from), expected)
    let from = f.commands.length
    assert.deepEqual(f.launch(f.app), { action: 'activate', appPath: f.app, configPath: f.config, pid: JOB })
    issued(from, ['print'])
    from = f.commands.length
    assert.deepEqual(f.launch(f.app, JOB), { action: 'continue', appPath: f.app, configPath: f.config })
    issued(from, ['print'])
    f.quit(); from = f.commands.length
    assert.deepEqual(f.launch(f.app), { action: 'relaunch', appPath: f.app, configPath: f.config })
    issued(from, ['print', 'kickstart'])
    assert.deepEqual(f.commands.filter(command => command.args[0] === 'kickstart').map(command => command.args), [['kickstart', `gui/123/${label}`]])
    assert.equal(f.jobPid(), JOB); assert.equal(f.stops(), 0)
    f.unload(); from = f.commands.length
    assert.deepEqual(f.launch(f.app), { action: 'relaunch', appPath: f.app, configPath: f.config })
    issued(from, ['print', 'bootstrap']); assert.equal(f.starts(), 2); assert.equal(f.stops(), 0)
  } finally { f.cleanup() }
})
it('refuses a Finder launch it cannot verify and starts nothing', () => {
  const f = fixture()
  try {
    // Nothing recorded: an unmanaged app, even at the canonical path, is not handed off.
    mkdirSync(path.dirname(f.app), { recursive: true }); cpSync(f.download, f.app, { recursive: true, verbatimSymlinks: true })
    assert.equal(failure(() => f.launch(f.app)).code, 'not-managed')
    rmSync(f.app, { recursive: true })
    installed(f); f.quit()
    /** @param {string} code */
    const refused = code => { const from = f.commands.length; assert.equal(failure(() => f.launch(f.app)).code, code); assert.deepEqual(f.verbs(from).filter(verb => verb !== 'print'), []) }
    // A copy that is not at the managed location.
    { const from = f.commands.length; assert.equal(failure(() => f.launch(f.download, HOST)).code, 'not-managed'); assert.deepEqual(f.verbs(from), []) }
    const agent = readFileSync(f.agent, 'utf8'), manifest = f.manifest()
    // Modified app, modified agent, an agent that records a different configuration, missing or invalid configuration, a foreign job.
    writeFileSync(path.join(f.app, 'user-file'), 'modified'); refused('foreign-app'); rmSync(path.join(f.app, 'user-file'))
    writeFileSync(f.agent, 'modified'); refused('foreign-agent')
    const other = plist(f.app, path.join(f.home, 'other.json'), f.home)
    writeFileSync(f.agent, other); writeFileSync(f.stateFile, JSON.stringify({ ...manifest, agentHash: digest(other) })); refused('foreign-agent')
    writeFileSync(f.agent, agent); writeFileSync(f.stateFile, JSON.stringify(manifest))
    const config = readFileSync(f.config, 'utf8')
    writeFileSync(f.config, '{'); refused('config-invalid'); assert.equal(readFileSync(f.config, 'utf8'), '{')
    rmSync(f.config); refused('config-invalid'); assert.equal(existsSync(f.config), false); writeFileSync(f.config, config)
    f.foreignJob(); refused('foreign-job')
    f.unload()
    assert.equal(f.kicks(), 0); assert.equal(f.stops(), 0); assert.equal(f.starts(), 1)
  } finally { f.cleanup() }
})
it('hands off through a LaunchAgent written by an earlier generation, leaving its bytes untouched', () => {
  const f = fixture()
  try {
    installed(f); f.quit()
    // Exactly what installers wrote before the account home was pinned in the LaunchAgent.
    const previous = `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>Label</key><string>${label}</string><key>ProgramArguments</key><array><string>${path.join(f.app, 'Contents/MacOS/OMPUsagePanel')}</string><string>--config</string><string>${f.config}</string></array><key>RunAtLoad</key><true/></dict></plist>\n`
    writeFileSync(f.agent, previous); writeFileSync(f.stateFile, JSON.stringify({ ...f.manifest(), agentHash: digest(previous) }))
    assert.equal(f.launch(f.app).action, 'relaunch')
    assert.equal(readFileSync(f.agent, 'utf8'), previous); assert.equal(f.kicks(), 1)
  } finally { f.cleanup() }
})

it('runs out of the repository from the packaged runtime alone and refuses everything it must refuse before launchd', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'omp-setup-packaged-'))
  try {
    const home = path.join(root, 'home'), bundle = packagedBundle(path.join(root, 'Downloads')), helper = path.join(bundle, helperPath)
    mkdirSync(home)
    /** @param {string} file @param {string} command @param {unknown} input */
    const helperRun = (file, command, input) => {
      const result = spawnSync(process.execPath, [file, command], { input: typeof input === 'string' ? input : JSON.stringify(input), encoding: 'utf8', cwd: tmpdir(), env: { ...process.env, HOME: home, NODE_PATH: '' } })
      return { status: result.status, payload: JSON.parse(result.stdout) }
    }
    const request = { sourceAppPath: bundle, hostPid: process.pid, ompPath: '/bin/sh', profile: 'default' }
    assert.equal(containingBundle(helper), realpathSync(bundle))
    // A foreign app at the destination: refused by the shared installer, with the packaged modules alone loaded.
    const destination = path.join(home, 'Applications/OMP Usage.app')
    mkdirSync(destination, { recursive: true }); writeFileSync(path.join(destination, 'user-file'), 'keep')
    const refused = helperRun(helper, 'install', request)
    assert.equal(refused.status, 1); assert.equal(refused.payload.ok, false); assert.equal(refused.payload.command, 'install'); assert.equal(refused.payload.error.code, 'foreign-app')
    assert.equal(readFileSync(path.join(destination, 'user-file'), 'utf8'), 'keep')
    assert.equal(helperRun(helper, 'install', { ...request, sourceAppPath: path.join(root, 'Elsewhere.app') }).payload.error.code, 'source-mismatch')
    assert.equal(helperRun(helper, 'install', '{ not json').payload.error.code, 'invalid-request')
    assert.equal(helperRun(helper, 'install', { ...request, unexpected: true }).payload.error.code, 'invalid-request')
    assert.equal(helperRun(helper, 'frobnicate', request).payload.error.code, 'invalid-request')
    // The helper of a source checkout belongs to no app bundle, so it has nothing to install.
    const checkout = helperRun(path.join(sourceRoot, 'apps/macos/setup-install.mjs'), 'install', request)
    assert.equal(checkout.status, 1); assert.equal(checkout.payload.error.code, 'source-mismatch')
    assert.throws(() => containingBundle(path.join(sourceRoot, 'apps/macos/setup-install.mjs')), { code: 'source-mismatch' })
    assert.equal(existsSync(path.join(home, 'Library/LaunchAgents')), false)
  } finally { rmSync(root, { recursive: true, force: true }) }
})
