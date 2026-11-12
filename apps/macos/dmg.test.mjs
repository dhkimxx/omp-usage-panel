import test from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { DmgCleanupError, assertDmgLayout, createDmg, dmgAppName, dmgNote, dmgNoteName, withDmgApp, withMountedDmg } from './dmg.mjs'
import { appTreeHash } from './ownership.mjs'

// These tests drive the real macOS hdiutil (compressed image creation, read-only attach/detach); they need a host that may attach disk images.
const darwin = { skip: process.platform !== 'darwin' }
/** @param {string[]} args */
const hdiutil = args => execFileSync('/usr/bin/hdiutil', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
/** @param {string} plist */
const toObject = plist => JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '-'], { input: plist, encoding: 'utf8' }))
/** Image paths currently attached on this host. @returns {string[]} */
function attachedImages() { return (toObject(hdiutil(['info', '-plist'])).images ?? []).map((/** @type {{'image-path'?: string}} */ image) => image['image-path'] ?? '') }
/** @param {string} dmg */
const isAttached = dmg => attachedImages().some(image => image.endsWith(`/${path.basename(dmg)}`) || image === dmg)

/** @param {string} directory @param {string} [name] */
function fixtureApp(directory, name = dmgAppName) {
  const app = path.join(directory, name)
  mkdirSync(path.join(app, 'Contents/MacOS'), { recursive: true })
  mkdirSync(path.join(app, 'Contents/Frameworks/Lib.framework/Versions/A'), { recursive: true })
  writeFileSync(path.join(app, 'Contents/Info.plist'), '<plist/>')
  writeFileSync(path.join(app, 'Contents/MacOS/OMPUsagePanel'), '#!/bin/sh\nexit 0\n')
  chmodSync(path.join(app, 'Contents/MacOS/OMPUsagePanel'), 0o755)
  writeFileSync(path.join(app, 'Contents/Frameworks/Lib.framework/Versions/A/Lib'), 'framework payload')
  symlinkSync('A', path.join(app, 'Contents/Frameworks/Lib.framework/Versions/Current'))
  symlinkSync('Versions/Current/Lib', path.join(app, 'Contents/Frameworks/Lib.framework/Lib'))
  return app
}
/** Builds a hand-made image from `populate` so layout violations are tested against real mounted volumes. @param {string} directory @param {(stage: string) => void} populate */
function customDmg(directory, populate) {
  const stage = mkdtempSync(path.join(directory, 'stage-')), dmg = path.join(directory, `${path.basename(stage)}.dmg`)
  populate(stage)
  hdiutil(['create', '-quiet', '-srcfolder', stage, '-volname', 'OMP Usage', '-fs', 'HFS+', '-format', 'UDZO', dmg])
  return dmg
}
/** @param {(directory: string) => void} body */
function inTemp(body) {
  const directory = mkdtempSync(path.join(tmpdir(), 'omp-dmg-test-'))
  try { body(directory) } finally { rmSync(directory, { recursive: true, force: true }) }
}

test('createDmg builds a compressed read-only image holding exactly the app and install note', darwin, () => inTemp(directory => {
  const app = fixtureApp(directory), dmg = createDmg({ app, output: path.join(directory, 'OMP-Usage-1.0.0.dmg') })
  const hash = withDmgApp(dmg, mounted => {
    assert.equal(lstatSync(path.join(mounted, '..', dmgNoteName)).isFile(), true)
    assert.deepEqual(readdirSync(path.dirname(mounted)).filter(name => !name.startsWith('.')).sort(), [dmgAppName, dmgNoteName].sort())
    assert.equal(readFileSync(path.join(path.dirname(mounted), dmgNoteName), 'utf8'), dmgNote)
    assert.throws(() => writeFileSync(path.join(path.dirname(mounted), 'probe'), 'x'), /EROFS|read-only/i, 'the image is mounted read-only')
    return appTreeHash(mounted)
  })
  assert.equal(hash, appTreeHash(app), 'modes, files and relative symlinks survive the image byte-for-byte as far as the ownership hash sees them')
  assert.equal(isAttached(dmg), false, 'the image is detached after use')
  assert.throws(() => createDmg({ app, output: dmg }), /already exists/)
  assert.throws(() => createDmg({ app, output: path.join(directory, 'x.zip') }), /\.dmg/)
}))

test('layout validation refuses extra apps, an Applications link and extra files, and still detaches', darwin, () => inTemp(directory => {
  /** @type {Record<string, (stage: string) => void>} */
  const bad = {
    'a second app': stage => { fixtureApp(stage, 'Other.app') },
    'an Applications link': stage => { symlinkSync('/Applications', path.join(stage, 'Applications')) },
    'an extra file': stage => { writeFileSync(path.join(stage, 'README.rtf'), 'x') },
    'a missing install note': stage => { rmSync(path.join(stage, dmgNoteName)) },
    'a different note': stage => { writeFileSync(path.join(stage, dmgNoteName), 'Drag to Applications') },
    'a linked app': stage => { rmSync(path.join(stage, dmgAppName), { recursive: true }); mkdirSync(path.join(stage, 'real')); fixtureApp(path.join(stage, 'real')); symlinkSync('real/OMP Usage.app', path.join(stage, dmgAppName)) },
  }
  for (const [label, mutate] of Object.entries(bad)) {
    const dmg = customDmg(directory, stage => { fixtureApp(stage); writeFileSync(path.join(stage, dmgNoteName), dmgNote); mutate(stage) })
    assert.throws(() => withDmgApp(dmg, () => assert.fail('action must not run')), /DMG must contain exactly|not the expected|must be a real app/, label)
    assert.equal(isAttached(dmg), false, `${label}: detached after the rejection`)
  }
  const good = customDmg(directory, stage => { fixtureApp(stage); writeFileSync(path.join(stage, dmgNoteName), dmgNote) })
  assert.equal(withDmgApp(good, app => path.basename(app)), dmgAppName)
  assert.throws(() => assertDmgLayout(directory), /DMG must contain exactly/)
}))

test('an action failure propagates and a non-image never leaves anything attached', darwin, () => inTemp(directory => {
  const dmg = createDmg({ app: fixtureApp(directory), output: path.join(directory, 'propagate.dmg') })
  assert.throws(() => withMountedDmg(dmg, () => { throw new Error('boom') }), /boom/)
  assert.equal(isAttached(dmg), false)
  const bogus = path.join(directory, 'bogus.dmg'); writeFileSync(bogus, 'not a disk image')
  assert.throws(() => withMountedDmg(bogus, () => assert.fail('must not mount')), /hdiutil|attach|Command failed/i)
  assert.equal(isAttached(bogus), false)
}))

test('a transient detach failure is retried and cleanup still removes only the empty mount directory', darwin, () => inTemp(directory => {
  const dmg = createDmg({ app: fixtureApp(directory), output: path.join(directory, 'retry.dmg') })
  let failures = 1, mountPoint = ''
  const result = withMountedDmg(dmg, mounted => { mountPoint = mounted; return 'ok' }, {
    detachRetryMs: 1,
    hdiutil: args => { if (args[0] === 'detach' && failures-- > 0) throw new Error('resource busy'); return hdiutil(args) },
  })
  assert.equal(result, 'ok')
  assert.equal(isAttached(dmg), false)
  assert.equal(existsSync(mountPoint), false)
}))

test('an unconfirmed detach fails loudly, names the device and never deletes the mounted path', darwin, () => inTemp(directory => {
  const dmg = createDmg({ app: fixtureApp(directory), output: path.join(directory, 'uncertain.dmg') })
  let mountPoint = ''
  /** @type {unknown} */
  let error
  try {
    withMountedDmg(dmg, mounted => { mountPoint = mounted; return 'action succeeded' }, {
      detachRetries: 1, detachRetryMs: 1,
      hdiutil: args => { if (args[0] === 'detach') throw new Error('resource busy'); return hdiutil(args) },
    })
  } catch (caught) { error = caught }
  try {
    assert.ok(error instanceof DmgCleanupError, 'a successful action does not hide uncertain cleanup')
    assert.match(error.message, /cleanup uncertain/)
    assert.equal(error.devices.length > 0 && error.devices.every(device => /^\/dev\/disk\d+$/.test(device)), true)
    for (const device of error.devices) assert.ok(error.message.includes(device), 'the device to detach by hand is reported')
    assert.equal(error.mountPoint, mountPoint)
    assert.equal(isAttached(dmg), true, 'the image really is still attached')
    assert.equal(existsSync(path.join(mountPoint, dmgAppName, 'Contents/MacOS/OMPUsagePanel')), true, 'mounted content was not deleted')
    assert.equal(existsSync(mountPoint), true, 'the mount directory was left in place')
  } finally {
    for (const device of /** @type {DmgCleanupError} */ (error)?.devices ?? []) hdiutil(['detach', '-force', device])
  }
  assert.equal(isAttached(dmg), false)
  rmSync(path.dirname(mountPoint), { recursive: true, force: true })
}))

test('a failed action and failed cleanup are reported together', darwin, () => inTemp(directory => {
  const dmg = createDmg({ app: fixtureApp(directory), output: path.join(directory, 'both.dmg') })
  /** @type {unknown} */
  let error
  try {
    withMountedDmg(dmg, () => { throw new Error('layout rejected') }, {
      detachRetries: 0, detachRetryMs: 1,
      hdiutil: args => { if (args[0] === 'detach') throw new Error('resource busy'); return hdiutil(args) },
    })
  } catch (caught) { error = caught }
  const cleanup = /** @type {DmgCleanupError} */ (error)
  try {
    assert.ok(cleanup instanceof DmgCleanupError)
    assert.match(cleanup.message, /layout rejected/)
    assert.equal(/** @type {Error} */ (cleanup.cause).message, 'layout rejected')
  } finally { for (const device of cleanup.devices) hdiutil(['detach', '-force', device]) }
  assert.equal(isAttached(dmg), false)
  rmSync(path.dirname(cleanup.mountPoint), { recursive: true, force: true })
}))
