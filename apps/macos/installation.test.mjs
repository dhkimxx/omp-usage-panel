import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync, existsSync, readdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { install, uninstall } from './installation.mjs'
import { sourceRoot } from './build.mjs'
import { appTreeHash } from './ownership.mjs'

function fixture() {
  const home = mkdtempSync(path.join(tmpdir(), 'omp-panel-test-'))
  const stateDir = path.join(home, 'Library/Application Support/omp-usage-panel')
  const config = path.join(stateDir, 'config.json'), stateFile = path.join(stateDir, 'install.json')
  const app = path.join(home, 'Applications/OMP Usage.app'), agent = path.join(home, 'Library/LaunchAgents/com.dhkim.omp-usage-panel.plist')
  let running = false, failStart = false, foreignJob = false, stops = 0, delayRemoval = 0, removalRemaining = 0, builds = 0, failDrainOnBootout = 0, drainFailures = 0
  /** @type {{file:string,args:string[]}[]} */
  const commands = []
  /** @param {string} file @param {string[]} args */
  function run(file, args) {
    commands.push({ file, args })
    if (file === '/bin/launchctl') {
      if (args[0] === 'print') {
        if (drainFailures) { drainFailures--; throw new Error('launchd drain failed') }
        if (!running && removalRemaining === 0) throw Object.assign(new Error('not running'), { status: 113, stderr: 'Could not find service' })
        if (!running) removalRemaining--
        const program = foreignJob ? '/foreign/program' : path.join(app, 'Contents/MacOS/OMPUsagePanel')
        return `job = {\n\tpath = ${agent}\n\tprogram = ${program}\n\targuments = {\n\t\t${program}\n\t\t--config\n\t\t${config}\n\t}\n}`
      }
      if (args[0] === 'bootout') { stops++; running = false; removalRemaining = delayRemoval; drainFailures = failDrainOnBootout; failDrainOnBootout = 0; return '' }
      if (args[0] === 'bootstrap') { if (removalRemaining) throw new Error('job removal in progress'); if (failStart) { failStart = false; throw new Error('bootstrap failed') }; running = true; return '' }
    }
    // No omp plugin command is permitted by this UI-only fixture.
    throw new Error(`Unexpected command: ${file} ${args.join(' ')}`)
  }
  const options = { home, platform: 'darwin', node: process.execPath, env: { OMP_BIN: '/bin/sh' }, run, uid: 123, sleep() {},
    /** @param {{outputDirectory:string}} options */
    build({ outputDirectory }) { builds++; const built = path.join(outputDirectory, 'fake.app'); mkdirSync(path.join(built, 'Contents/MacOS'), { recursive: true }); writeFileSync(path.join(built, 'Contents/MacOS/OMPUsagePanel'), `binary-${builds}`, { mode: 0o755 }); return built } }
  return { home, stateDir, stateFile, options, config, app, agent, commands, failNextStart() { failStart = true }, setForeignJob() { foreignJob = true; running = true }, stopCount() { return stops }, delayRemoval(polls = 3) { delayRemoval = polls }, failDrainAfterBootout(persistent = false) { failDrainOnBootout = persistent ? Infinity : 1 }, isRunning() { return running }, cleanup() { rmSync(home, { recursive: true, force: true }) } }
}

/** @param {ReturnType<typeof fixture>} f */
function legacyState(f) {
  const release = path.join(f.stateDir, 'releases/11111111-2222-4333-8444-555555555555')
  mkdirSync(release, { recursive: true }); writeFileSync(path.join(release, 'keep'), 'legacy providers')
  const state = { ...JSON.parse(readFileSync(f.stateFile, 'utf8')), version: 1, snapshots: [release], opaque: { retained: ['original', 'provider', 'metadata'] } }
  const content = JSON.stringify(state, null, 4) + '\n'
  writeFileSync(f.stateFile, content)
  return { content, release, backup: path.join(f.stateDir, 'install-v1.json') }
}

test('dry run leaves the home untouched and invokes no provider tooling', () => {
  const f = fixture()
  try {
    install({ ...f.options, dryRun: true })
    assert.deepEqual(readdirSync(f.home), [])
  } finally { f.cleanup() }
})
test('installation without personal providers writes only a v2 UI manifest', () => {
  const f = fixture()
  try {
    install(f.options)
    const state = JSON.parse(readFileSync(f.stateFile, 'utf8'))
    assert.equal(state.version, 2)
    assert.equal(existsSync(path.join(f.stateDir, 'releases')), false)
    assert.equal(f.isRunning(), true)
  } finally { f.cleanup() }
})
test('configuration is retained through uninstall and reinstall', () => {
  const f = fixture()
  try {
    install(f.options)
    const original = readFileSync(f.config, 'utf8')
    uninstall(f.options); assert.equal(existsSync(f.app), false); assert.equal(existsSync(f.agent), false); assert.equal(readFileSync(f.config, 'utf8'), original)
    install(f.options); assert.equal(existsSync(f.app), true); assert.equal(readFileSync(f.config, 'utf8'), original)
  } finally { f.cleanup() }
})
test('uninstall removes the managed Node runtime but keeps configuration, caches and records', () => {
  const f = fixture()
  try {
    install(f.options)
    const runtime = path.join(f.stateDir, 'runtime'), cache = path.join(f.stateDir, 'cache/usage.json')
    mkdirSync(path.join(runtime, 'node-22.23.5-arm64'), { recursive: true }); writeFileSync(path.join(runtime, 'node-22.23.5-arm64/node'), 'binary')
    mkdirSync(path.dirname(cache), { recursive: true }); writeFileSync(cache, 'cached')
    const original = readFileSync(f.config, 'utf8')
    assert.ok(uninstall({ ...f.options, dryRun: true }).some(action => action.includes(runtime))); assert.equal(existsSync(runtime), true)
    uninstall(f.options)
    assert.equal(existsSync(runtime), false); assert.equal(existsSync(f.app), false)
    assert.equal(readFileSync(f.config, 'utf8'), original); assert.equal(readFileSync(cache, 'utf8'), 'cached'); assert.equal(existsSync(f.stateFile), true)
  } finally { f.cleanup() }
})
test('a symlinked managed runtime is refused before anything is removed and its target is never touched', () => {
  const f = fixture()
  try {
    install(f.options)
    const outside = path.join(f.home, 'outside-runtime'), runtime = path.join(f.stateDir, 'runtime')
    mkdirSync(outside); writeFileSync(path.join(outside, 'keep'), 'keep'); symlinkSync(outside, runtime, 'dir')
    assert.throws(() => uninstall(f.options), /Refusing to remove a managed runtime/)
    assert.equal(readlinkSync(runtime), outside); assert.equal(readFileSync(path.join(outside, 'keep'), 'utf8'), 'keep')
    assert.equal(existsSync(f.app), true); assert.equal(existsSync(f.agent), true); assert.equal(f.stopCount(), 0)
  } finally { f.cleanup() }
})
test('an existing configuration whose legacy Node path is gone is neither validated nor rewritten', () => {
  const f = fixture()
  try {
    install(f.options)
    const stale = readFileSync(f.config, 'utf8').replace(JSON.stringify(process.execPath), JSON.stringify(path.join(f.home, 'gone/node')))
    assert.notEqual(stale, readFileSync(f.config, 'utf8')); writeFileSync(f.config, stale)
    install(f.options)
    assert.equal(readFileSync(f.config, 'utf8'), stale)
    assert.equal(f.commands.some(command => command.args[0] === '--version'), false)
  } finally { f.cleanup() }
})
test('existing configuration is preserved when reinstalled with different environment defaults', () => {
  const f = fixture()
  try {
    install(f.options)
    const config = readFileSync(f.config, 'utf8')
    install({ ...f.options, env: {} })
    assert.equal(readFileSync(f.config, 'utf8'), config)
  } finally { f.cleanup() }
})
test('install, failed update and uninstall leave provider links, settings and legacy releases untouched', () => {
  const f = fixture()
  try {
    const provider = path.join(f.home, 'provider-runtime'), modules = path.join(f.home, 'plugins/node_modules/@example'), link = path.join(modules, 'personal-provider')
    const settings = path.join(f.home, 'plugins/settings.json')
    mkdirSync(provider, { recursive: true }); mkdirSync(modules, { recursive: true }); symlinkSync(provider, link, 'dir'); writeFileSync(settings, '{"enabled":["personal-provider"]}\n')
    const originalSettings = readFileSync(settings, 'utf8')
    install(f.options)
    f.failNextStart(); assert.throws(() => install(f.options), /bootstrap failed/)
    uninstall(f.options)
    assert.equal(readlinkSync(link), provider); assert.equal(readFileSync(settings, 'utf8'), originalSettings)
    assert.equal(f.commands.some(command => command.args[0] === 'plugin'), false)
  } finally { f.cleanup() }
})
test('modified app is not overwritten or removed', () => {
  const f = fixture()
  try { install(f.options); writeFileSync(path.join(f.app, 'user-file'), 'keep'); assert.throws(() => install(f.options), /modified app/); assert.throws(() => uninstall(f.options), /modified app/); assert.equal(readFileSync(path.join(f.app, 'user-file'), 'utf8'), 'keep') } finally { f.cleanup() }
})
test('failed activation restores the previous app, LaunchAgent, manifest and running job', () => {
  const f = fixture()
  try {
    install(f.options)
    const executable = path.join(f.app, 'Contents/MacOS/OMPUsagePanel'), binary = readFileSync(executable, 'utf8'), agent = readFileSync(f.agent, 'utf8'), manifest = readFileSync(f.stateFile, 'utf8')
    f.failNextStart(); assert.throws(() => install(f.options), /bootstrap failed/)
    assert.equal(readFileSync(executable, 'utf8'), binary); assert.equal(readFileSync(f.agent, 'utf8'), agent); assert.equal(readFileSync(f.stateFile, 'utf8'), manifest); assert.equal(f.isRunning(), true)
  } finally { f.cleanup() }
})
test('foreign LaunchAgent is preserved', () => {
  const f = fixture()
  try {
    mkdirSync(path.dirname(f.agent), { recursive: true }); writeFileSync(f.agent, 'user agent')
    assert.throws(() => install(f.options), /Foreign or modified LaunchAgent/)
    assert.equal(readFileSync(f.agent, 'utf8'), 'user agent')
  } finally { f.cleanup() }
})
test('modified owned LaunchAgent is neither overwritten nor removed', () => {
  const f = fixture()
  try {
    install(f.options); writeFileSync(f.agent, 'modified')
    assert.throws(() => install(f.options), /Foreign or modified LaunchAgent/)
    assert.throws(() => uninstall(f.options), /Foreign or modified LaunchAgent/)
    assert.equal(readFileSync(f.agent, 'utf8'), 'modified'); assert.equal(f.stopCount(), 0)
  } finally { f.cleanup() }
})
test('failed first activation removes only the newly created UI and config', () => {
  const f = fixture()
  try {
    f.failNextStart(); assert.throws(() => install(f.options), /bootstrap failed/)
    assert.equal(existsSync(f.app), false); assert.equal(existsSync(f.agent), false); assert.equal(existsSync(f.config), false); assert.equal(existsSync(f.stateFile), false)
    assert.equal(f.isRunning(), false)
  } finally { f.cleanup() }
})
test('explicit executable inside node_modules is accepted', () => {
  const f = fixture()
  try {
    const executable = path.join(f.home, 'global/node_modules/omp/bin/omp')
    mkdirSync(path.dirname(executable), { recursive: true }); writeFileSync(executable, '#!/bin/sh\n', { mode: 0o755 })
    install({ ...f.options, env: { OMP_BIN: executable } })
    assert.equal(JSON.parse(readFileSync(f.config, 'utf8')).ompPath, executable)
  } finally { f.cleanup() }
})
test('config path resolving into source checkout is refused', () => {
  const f = fixture()
  try {
    const link = path.join(f.home, 'source-link'); symlinkSync(sourceRoot, link, 'dir')
    assert.throws(() => install({ ...f.options, configPath: path.join(link, 'unused-panel-config.json') }), /outside the source checkout/)
  } finally { f.cleanup() }
})
test('untracked loaded job is not stopped even when no plist exists', () => {
  const f = fixture()
  try {
    f.setForeignJob(); assert.throws(() => install(f.options), /Foreign or unverified loaded LaunchAgent/)
    assert.equal(f.stopCount(), 0); assert.equal(existsSync(f.agent), false)
  } finally { f.cleanup() }
})
test('tracked files do not authorize stopping a different loaded job', () => {
  const f = fixture()
  try {
    install(f.options); f.setForeignJob()
    assert.throws(() => uninstall(f.options), /Foreign or unverified loaded LaunchAgent/)
    assert.throws(() => install(f.options), /Foreign or unverified loaded LaunchAgent/)
    assert.equal(f.stopCount(), 0); assert.equal(existsSync(f.app), true)
  } finally { f.cleanup() }
})
test('update waits until launchd reports the booted-out job absent', () => {
  const f = fixture()
  try {
    install(f.options); f.delayRemoval(); install(f.options)
    assert.equal(f.stopCount(), 1); assert.equal(existsSync(f.app), true)
  } finally { f.cleanup() }
})
test('failed launchd drain after successful bootout restores the previous running UI', () => {
  const f = fixture()
  try {
    install(f.options)
    const executable = path.join(f.app, 'Contents/MacOS/OMPUsagePanel'), binary = readFileSync(executable, 'utf8'), agent = readFileSync(f.agent, 'utf8'), manifest = readFileSync(f.stateFile, 'utf8')
    f.delayRemoval(); f.failDrainAfterBootout()
    assert.throws(() => install(f.options), /launchd drain failed/)
    assert.equal(f.isRunning(), true)
    assert.equal(readFileSync(executable, 'utf8'), binary); assert.equal(readFileSync(f.agent, 'utf8'), agent); assert.equal(readFileSync(f.stateFile, 'utf8'), manifest)
  } finally { f.cleanup() }
})
test('launchd drain timeout still attempts rollback and waits for absence before restarting', () => {
  const f = fixture()
  try {
    install(f.options); f.delayRemoval(101)
    assert.throws(() => install(f.options), /Timed out waiting for LaunchAgent/)
    assert.equal(f.isRunning(), true)
  } finally { f.cleanup() }
})
test('unverifiable rollback drain reports rollback incomplete without registering a second job', () => {
  const f = fixture()
  try {
    install(f.options); f.failDrainAfterBootout(true)
    assert.throws(() => install(f.options), /rollback incomplete/)
    assert.equal(f.isRunning(), false)
    assert.equal(f.commands.filter(command => command.file === '/bin/launchctl' && command.args[0] === 'bootstrap').length, 1)
    assert.equal(existsSync(f.app), true); assert.equal(existsSync(f.agent), true)
  } finally { f.cleanup() }
})
test('v1 migration preserves opaque original bytes and legacy release before writing UI-only v2 state', () => {
  const f = fixture()
  try {
    install(f.options); const legacy = legacyState(f), config = readFileSync(f.config, 'utf8')
    install(f.options)
    assert.equal(readFileSync(legacy.backup, 'utf8'), legacy.content)
    const state = JSON.parse(readFileSync(f.stateFile, 'utf8')); assert.equal(state.version, 2); assert.equal('snapshots' in state, false); assert.equal('opaque' in state, false)
    assert.equal(readFileSync(path.join(legacy.release, 'keep'), 'utf8'), 'legacy providers'); assert.equal(readFileSync(f.config, 'utf8'), config)
    install(f.options); uninstall(f.options)
    assert.equal(readFileSync(legacy.backup, 'utf8'), legacy.content); assert.equal(readFileSync(path.join(legacy.release, 'keep'), 'utf8'), 'legacy providers')
  } finally { f.cleanup() }
})
test('v1 dry run does not create a migration backup or change the original manifest', () => {
  const f = fixture()
  try {
    install(f.options); const legacy = legacyState(f)
    install({ ...f.options, dryRun: true })
    assert.equal(existsSync(legacy.backup), false); assert.equal(readFileSync(f.stateFile, 'utf8'), legacy.content); assert.equal(f.stopCount(), 0)
  } finally { f.cleanup() }
})
test('failed v1 update preserves the original manifest, migration record and running UI', () => {
  const f = fixture()
  try {
    install(f.options); const legacy = legacyState(f)
    f.failNextStart(); assert.throws(() => install(f.options), /bootstrap failed/)
    assert.equal(readFileSync(f.stateFile, 'utf8'), legacy.content); assert.equal(readFileSync(legacy.backup, 'utf8'), legacy.content); assert.equal(f.isRunning(), true)
    install(f.options); assert.equal(JSON.parse(readFileSync(f.stateFile, 'utf8')).version, 2)
  } finally { f.cleanup() }
})
test('unrelated legacy backup is never overwritten or allowed to discard the v1 record', () => {
  const f = fixture()
  try {
    install(f.options); const legacy = legacyState(f)
    writeFileSync(legacy.backup, 'unrelated backup')
    assert.throws(() => install(f.options), /Unrelated legacy migration backup/)
    assert.equal(readFileSync(legacy.backup, 'utf8'), 'unrelated backup'); assert.equal(readFileSync(f.stateFile, 'utf8'), legacy.content); assert.equal(f.stopCount(), 0)
  } finally { f.cleanup() }
})
test('legacy backup symlink is refused even when its bytes match', () => {
  const f = fixture()
  try {
    install(f.options); const legacy = legacyState(f), target = path.join(f.home, 'unrelated-record.json')
    writeFileSync(target, legacy.content); symlinkSync(target, legacy.backup)
    assert.throws(() => install(f.options), /Unrelated legacy migration backup/)
    assert.equal(readlinkSync(legacy.backup), target); assert.equal(readFileSync(f.stateFile, 'utf8'), legacy.content)
  } finally { f.cleanup() }
})
test('legacy uninstall removes only owned UI and retains the provider adoption record', () => {
  const f = fixture()
  try {
    install(f.options); const legacy = legacyState(f)
    uninstall(f.options)
    assert.equal(existsSync(f.app), false); assert.equal(existsSync(f.agent), false)
    assert.equal(readFileSync(f.stateFile, 'utf8'), legacy.content); assert.equal(readFileSync(path.join(legacy.release, 'keep'), 'utf8'), 'legacy providers')
  } finally { f.cleanup() }
})

/** A built app shaped like the Sparkle build: a framework whose entries are relative symlinks. @param {{outputDirectory:string}} options */
function frameworkBuild({ outputDirectory }) {
  const built = path.join(outputDirectory, 'framework.app'), framework = path.join(built, 'Contents/Frameworks/Fake.framework')
  mkdirSync(path.join(built, 'Contents/MacOS'), { recursive: true }); writeFileSync(path.join(built, 'Contents/MacOS/OMPUsagePanel'), 'binary', { mode: 0o755 })
  mkdirSync(path.join(framework, 'Versions/B'), { recursive: true }); writeFileSync(path.join(framework, 'Versions/B/Fake'), 'framework', { mode: 0o755 })
  symlinkSync('B', path.join(framework, 'Versions/Current'), 'dir'); symlinkSync('Versions/Current/Fake', path.join(framework, 'Fake'), 'file')
  return built
}
test('framework symlinks stay relative through install and the shared hash keeps later install and uninstall working', () => {
  const f = fixture()
  try {
    install({ ...f.options, build: frameworkBuild })
    const framework = path.join(f.app, 'Contents/Frameworks/Fake.framework')
    assert.equal(readlinkSync(path.join(framework, 'Versions/Current')), 'B'); assert.equal(readlinkSync(path.join(framework, 'Fake')), 'Versions/Current/Fake')
    assert.equal(JSON.parse(readFileSync(f.stateFile, 'utf8')).appHash, appTreeHash(f.app))
    install({ ...f.options, build: frameworkBuild })
    uninstall(f.options)
    assert.equal(existsSync(f.app), false); assert.equal(existsSync(f.agent), false)
  } finally { f.cleanup() }
})
test('an escaping symlink in the built app is refused before anything is replaced', () => {
  const f = fixture()
  try {
    install(f.options)
    const executable = path.join(f.app, 'Contents/MacOS/OMPUsagePanel'), binary = readFileSync(executable, 'utf8'), manifest = readFileSync(f.stateFile, 'utf8')
    /** @param {{outputDirectory:string}} options */
    const escaping = ({ outputDirectory }) => { const built = frameworkBuild({ outputDirectory }); symlinkSync('../../../outside', path.join(built, 'Contents/escape')); return built }
    assert.throws(() => install({ ...f.options, build: escaping }), /Symlink escapes app/)
    assert.equal(f.stopCount(), 0); assert.equal(f.isRunning(), true)
    assert.equal(readFileSync(executable, 'utf8'), binary); assert.equal(readFileSync(f.stateFile, 'utf8'), manifest)
  } finally { f.cleanup() }
})
test('a modified app in another user\'s ownership is neither updated nor removed', () => {
  const f = fixture()
  try {
    install(f.options)
    assert.throws(() => install({ ...f.options, owner: (process.getuid?.() ?? 0) + 1 }), /not a private real directory/)
    assert.throws(() => uninstall({ ...f.options, owner: (process.getuid?.() ?? 0) + 1 }), /not a private real directory/)
    assert.equal(existsSync(f.app), true); assert.equal(f.stopCount(), 0)
  } finally { f.cleanup() }
})
test('a replacement whose shutdown cannot be verified keeps both apps and the previous agent instead of restoring underneath it', () => {
  const f = fixture()
  try {
    install(f.options)
    const executable = path.join(f.app, 'Contents/MacOS/OMPUsagePanel'), previous = readFileSync(executable, 'utf8')
    let sabotage = false, bootoutFails = false
    /** @param {string} file @param {string[]} args */
    const run = (file, args) => {
      if (bootoutFails && args[0] === 'bootout') throw new Error('bootout failed')
      const result = f.options.run(file, args)
      // The replacement is running; persisting the new ownership record then fails and its job cannot be stopped.
      if (sabotage && args[0] === 'bootstrap') { rmSync(f.stateFile); mkdirSync(f.stateFile); writeFileSync(path.join(f.stateFile, 'keep'), 'x'); bootoutFails = true }
      return result
    }
    sabotage = true
    assert.throws(() => install({ ...f.options, run }), /replacement shutdown could not be verified/)
    assert.notEqual(readFileSync(executable, 'utf8'), previous); assert.equal(f.isRunning(), true)
    const applications = readdirSync(path.dirname(f.app)), backup = applications.find(name => name.startsWith('.omp-backup-'))
    assert.ok(backup, 'previous app preserved'); assert.equal(readFileSync(path.join(path.dirname(f.app), backup, 'Contents/MacOS/OMPUsagePanel'), 'utf8'), previous)
    assert.ok(readdirSync(path.dirname(f.agent)).some(name => name.startsWith('.omp-agent-')), 'previous agent preserved')
  } finally { f.cleanup() }
})
