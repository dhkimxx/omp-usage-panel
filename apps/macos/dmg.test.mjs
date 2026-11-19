import test from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
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
/** @param {string} file */
function canonicalImagePath(file) { try { return realpathSync(file) } catch { return path.resolve(file) } }
/** @param {string} dmg */
const isAttached = dmg => { const expected = canonicalImagePath(dmg); return attachedImages().some(image => image !== '' && canonicalImagePath(image) === expected) }

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
    assert.throws(() => writeFileSync(path.join(path.dirname(mounted), 'probe'), 'x'), error => error instanceof Error && 'code' in error && error.code === 'EROFS')
    return appTreeHash(mounted)
  })
  assert.equal(hash, appTreeHash(app), 'modes, files and relative symlinks survive the image byte-for-byte as far as the ownership hash sees them')
  assert.equal(isAttached(dmg), false, 'the image is detached after use')
  const other = createDmg({ app, output: path.join(directory, 'other', path.basename(dmg)) })
  withMountedDmg(other, () => {
    assert.equal(isAttached(other), true)
    assert.equal(isAttached(dmg), false, 'another attached image with the same filename is not this image')
  })
  assert.equal(isAttached(other), false)
  assert.throws(() => createDmg({ app, output: dmg }))
  assert.throws(() => createDmg({ app, output: path.join(directory, 'x.zip') }))
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
    let actionRan = false
    assert.throws(() => withDmgApp(dmg, () => { actionRan = true }), label)
    assert.equal(actionRan, false)
    assert.equal(isAttached(dmg), false, `${label}: detached after the rejection`)
  }
  assert.throws(() => assertDmgLayout(directory))
}))

test('the install note says Node.js is bundled and mentions the one-line installer, and an image carrying any other note is refused', darwin, () => inTemp(directory => {
  assert.match(dmgNote, /Node\.js is bundled/)
  assert.match(dmgNote, /one-line installer/)
  assert.match(dmgNote, /ad-hoc signed/)
  const other = customDmg(directory, stage => { fixtureApp(stage); writeFileSync(path.join(stage, dmgNoteName), dmgNote.replace('Node.js is bundled', 'Node.js is required')) })
  assert.throws(() => withDmgApp(other, () => 'never'), /not the expected install note/)
  assert.equal(isAttached(other), false)
}))

test('an action failure propagates and a non-image never leaves anything attached', darwin, () => inTemp(directory => {
  const dmg = createDmg({ app: fixtureApp(directory), output: path.join(directory, 'propagate.dmg') })
  const failure = new Error('original action failure')
  assert.throws(() => withMountedDmg(dmg, () => { throw failure }), error => error === failure)
  assert.equal(isAttached(dmg), false)
  const bogus = path.join(directory, 'bogus.dmg'); writeFileSync(bogus, 'not a disk image')
  let actionRan = false
  assert.throws(() => withMountedDmg(bogus, () => { actionRan = true }))
  assert.equal(actionRan, false)
  assert.equal(isAttached(bogus), false)
}))

test('a transient detach failure is retried and cleanup still removes only the empty mount directory', darwin, () => inTemp(directory => {
  const dmg = createDmg({ app: fixtureApp(directory), output: path.join(directory, 'retry.dmg') })
  let failures = 1, mountPoint = ''
  withMountedDmg(dmg, mounted => { mountPoint = mounted }, {
    detachRetryMs: 1,
    hdiutil: args => { if (args[0] === 'detach' && failures-- > 0) throw new Error('resource busy'); return hdiutil(args) },
  })
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
    assert.equal(error.devices.length > 0 && error.devices.every(device => /^\/dev\/disk\d+$/.test(device)), true)
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
  const failure = new Error('original rejected action')
  try {
    withMountedDmg(dmg, () => { throw failure }, {
      detachRetries: 0, detachRetryMs: 1,
      hdiutil: args => { if (args[0] === 'detach') throw new Error('resource busy'); return hdiutil(args) },
    })
  } catch (caught) { error = caught }
  const cleanup = /** @type {DmgCleanupError} */ (error)
  try {
    assert.ok(cleanup instanceof DmgCleanupError)
    assert.equal(cleanup.cause, failure)
  } finally { for (const device of cleanup.devices) hdiutil(['detach', '-force', device]) }
  assert.equal(isAttached(dmg), false)
  rmSync(path.dirname(cleanup.mountPoint), { recursive: true, force: true })
}))
