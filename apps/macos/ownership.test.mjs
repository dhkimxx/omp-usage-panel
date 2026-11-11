import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { chmodSync, cpSync, existsSync, lchmodSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from 'node:fs'
import { execFileSync, spawn, spawnSync } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { tmpdir } from 'node:os'
import path from 'node:path'
const ownershipUrl = pathToFileURL(path.join(path.dirname(fileURLToPath(import.meta.url)), 'ownership.mjs')).href
import { appTreeHash, context, sameEntries, scanTree, syncTree, withLock } from './ownership.mjs'

/** The pre-Sparkle ownership algorithm, frozen here so symlink support can never change hashes already recorded for symlink-free apps.
 * @param {string} root */
function legacyTreeHash(root) {
  const hash = createHash('sha256')
  /** @param {string} file @param {string} rel */
  function visit(file, rel) {
    const stat = lstatSync(file)
    if (stat.isSymbolicLink()) throw new Error('legacy hashing rejects symlinks')
    if (stat.isDirectory()) { hash.update(`d\0${rel}\0`); for (const name of readdirSync(file).sort()) visit(path.join(file, name), path.join(rel, name)); return }
    const data = readFileSync(file); hash.update(`f\0${rel}\0${stat.mode & 0o777}\0${data.length}\0`).update(data)
  }
  visit(root, ''); return hash.digest('hex')
}
/** @param {string} file @param {string} content @param {number} [mode] */
function put(file, content, mode = 0o644) { mkdirSync(path.dirname(file), { recursive: true }); writeFileSync(file, content, { mode }); chmodSync(file, mode) }
/** A bundle shaped like a real framework: Versions/Current -> B plus file and directory links that resolve through another link. @param {string} root */
function frameworkApp(root) {
  put(path.join(root, 'Contents/MacOS/App'), 'app binary', 0o755)
  put(path.join(root, 'Contents/Info.plist'), '<plist/>')
  const framework = path.join(root, 'Contents/Frameworks/Fake.framework')
  put(path.join(framework, 'Versions/B/Fake'), 'framework binary', 0o755)
  put(path.join(framework, 'Versions/B/Resources/Info.plist'), '<plist/>')
  symlinkSync('B', path.join(framework, 'Versions/Current'), 'dir')
  symlinkSync('Versions/Current/Fake', path.join(framework, 'Fake'), 'file')
  symlinkSync('Versions/Current/Resources', path.join(framework, 'Resources'), 'dir')
  return root
}
function workspace() {
  const directory = mkdtempSync(path.join(tmpdir(), 'omp-ownership-'))
  return { directory, app: path.join(directory, 'OMP Usage.app'), cleanup() { rmSync(directory, { recursive: true, force: true }) } }
}

test('symlink-free apps keep exactly the hash the original algorithm recorded', () => {
  const w = workspace()
  try {
    put(path.join(w.app, 'Contents/MacOS/OMPUsagePanel'), 'binary', 0o755); put(path.join(w.app, 'Contents/Resources/LICENSE'), 'license'); mkdirSync(path.join(w.app, 'Contents/Empty'))
    assert.equal(appTreeHash(w.app), legacyTreeHash(w.app))
    assert.equal(appTreeHash(w.app, { uid: process.getuid?.() ?? 0 }), legacyTreeHash(w.app))
  } finally { w.cleanup() }
})
test('framework-internal relative symlinks hash by target and type, are copied verbatim and detect changes', () => {
  const w = workspace()
  try {
    frameworkApp(w.app)
    const hash = appTreeHash(w.app)
    const copy = path.join(w.directory, 'copy.app')
    cpSync(w.app, copy, { recursive: true, verbatimSymlinks: true })
    assert.equal(appTreeHash(copy), hash)
    const entries = scanTree(w.app).entries
    assert.deepEqual(entries.get('Contents/Frameworks/Fake.framework/Versions/Current'), { kind: 'l', type: 'd', target: 'B' })
    assert.deepEqual(entries.get('Contents/Frameworks/Fake.framework/Fake'), { kind: 'l', type: 'f', target: 'Versions/Current/Fake' })
    // A link is one record: nothing is hashed beneath it, so the files it resolves to are never hashed a second time.
    assert.equal([...entries.keys()].filter(key => key.startsWith('Contents/Frameworks/Fake.framework/Versions/Current/')).length, 0)
    rmSync(path.join(copy, 'Contents/Frameworks/Fake.framework/Fake')); symlinkSync('Versions/B/Fake', path.join(copy, 'Contents/Frameworks/Fake.framework/Fake'), 'file')
    assert.notEqual(appTreeHash(copy), hash)
    assert.equal(sameEntries(scanTree(w.app).entries, scanTree(w.app).entries), true)
    assert.equal(sameEntries(scanTree(w.app).entries, scanTree(copy).entries), false)
  } finally { w.cleanup() }
})
test('symlink permission bits, which follow the extracting user\'s umask, do not change the hash', t => {
  const w = workspace()
  try {
    frameworkApp(w.app)
    const hash = appTreeHash(w.app)
    try { lchmodSync(path.join(w.app, 'Contents/Frameworks/Fake.framework/Fake'), 0o700) } catch { t.skip('lchmod is unavailable'); return }
    assert.equal(appTreeHash(w.app), hash)
  } finally { w.cleanup() }
})
test('symlinks that escape, are absolute, dangle, loop or point at the app root are rejected', () => {
  const w = workspace()
  try {
    frameworkApp(w.app)
    const link = path.join(w.app, 'Contents/extra')
    /** @type {[string, RegExp][]} */
    const cases = [['../../outside', /escapes/], ['/etc/hosts', /relative/], ['missing', /Unresolvable/], ['../', /escapes/], ['Frameworks/../../..', /escapes/]]
    for (const [target, message] of cases) {
      symlinkSync(target, link)
      try { assert.throws(() => appTreeHash(w.app), message, target) } finally { rmSync(link) }
    }
    symlinkSync('loop-b', path.join(w.app, 'Contents/loop-a')); symlinkSync('loop-a', path.join(w.app, 'Contents/loop-b'))
    assert.throws(() => appTreeHash(w.app), /Unresolvable/)
  } finally { w.cleanup() }
})
test('a symlinked app root, special files and entries owned by another user are rejected', () => {
  const w = workspace()
  try {
    frameworkApp(w.app)
    const root = path.join(w.directory, 'root-link.app'); symlinkSync(w.app, root, 'dir')
    assert.throws(() => appTreeHash(root), /Unexpected symlink/)
    assert.throws(() => appTreeHash(w.app, { uid: (process.getuid?.() ?? 0) + 1 }), /owned by another user/)
    if (process.platform === 'darwin') {
      execFileSync('/usr/bin/mkfifo', [path.join(w.app, 'Contents/pipe')])
      assert.throws(() => appTreeHash(w.app), /Unexpected app entry/)
    }
  } finally { w.cleanup() }
})
test('syncing a tree with framework symlinks flushes files and directories without following links', () => {
  const w = workspace()
  try {
    frameworkApp(w.app)
    symlinkSync(path.join(w.directory, 'missing-target'), path.join(w.app, 'Contents/dangling'))
    assert.doesNotThrow(() => syncTree(w.app))
  } finally { w.cleanup() }
})

/** Run a Node child that executes `body` with `withLock`/`context` imported from ownership.mjs. @param {string} body @param {string[]} args */
function child(body, args) {
  const script = `import { context, withLock } from ${JSON.stringify(ownershipUrl)}\nimport { appendFileSync, existsSync, writeFileSync } from 'node:fs'\nconst pause = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)\n${body}`
  const process_ = spawn(process.execPath, ['--input-type=module', '-e', script, ...args], { stdio: 'ignore' })
  const exited = new Promise(resolve => process_.once('exit', (code, signal) => resolve({ code, signal })))
  return { process: process_, exited: /** @type {Promise<{code:number|null, signal:string|null}>} */ (exited) }
}
/** A child that holds the critical section until `release` exists. @param {string} stateDir @param {string} ready @param {string} release */
function holder(stateDir, ready, release) {
  return child(`const [stateDir, ready, release] = process.argv.slice(1)\nwithLock(context({ stateDir, home: stateDir, platform: 'darwin' }), () => { writeFileSync(ready, 'held'); while (!existsSync(release)) pause(20) })`, [stateDir, ready, release])
}
/** @param {string} file */
function waitFor(file) { for (let waited = 0; !existsSync(file); waited += 20) { if (waited > 15_000) throw new Error(`Timed out waiting for ${file}`); Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20) } }

test('an active owner in another process excludes every other critical section until it releases', async () => {
  const w = workspace()
  try {
    const ready = path.join(w.directory, 'ready'), release = path.join(w.directory, 'release'), sleeps = /** @type {number[]} */ ([])
    const c = context({ home: w.directory, stateDir: w.directory, platform: 'darwin', sleep: milliseconds => { sleeps.push(milliseconds) } })
    const owner = holder(w.directory, ready, release)
    waitFor(ready)
    assert.throws(() => withLock(c, () => 'never'), /Installer lock exists/)
    assert.throws(() => withLock(c, () => 'never', 300), /Installer lock exists/)
    assert.equal(sleeps.length, 3)
    writeFileSync(release, 'go')
    assert.equal((await owner.exited).code, 0)
    assert.equal(withLock(c, () => 'ran'), 'ran')
    assert.equal(existsSync(path.join(w.directory, 'lock')), false)
  } finally { w.cleanup() }
})
test('an owner that dies abruptly releases the lock at once, and concurrent recoveries never overlap', async () => {
  const w = workspace()
  try {
    const ready = path.join(w.directory, 'ready'), release = path.join(w.directory, 'release'), log = path.join(w.directory, 'sections.log')
    const owner = holder(w.directory, ready, release)
    waitFor(ready)
    owner.process.kill('SIGKILL')
    assert.equal((await owner.exited).signal, 'SIGKILL')
    const c = context({ home: w.directory, stateDir: w.directory, platform: 'darwin' })
    // The killed owner's legacy directory marker is reclaimed because its recorded process is provably gone.
    const contenders = ['a', 'b', 'c', 'd'].map(name => child(`const [stateDir, log, name] = process.argv.slice(1)\nwithLock(context({ stateDir, home: stateDir, platform: 'darwin' }), () => { appendFileSync(log, 'start ' + name + '\\n'); pause(80); appendFileSync(log, 'end ' + name + '\\n') }, 20000)`, [w.directory, log, name]))
    for (const contender of contenders) assert.equal((await contender.exited).code, 0)
    const lines = readFileSync(log, 'utf8').trim().split('\n')
    assert.equal(lines.length, 8)
    for (let index = 0; index < lines.length; index += 2) assert.equal(lines[index]?.replace('start', 'end'), lines[index + 1], `sections overlapped: ${lines.join(', ')}`)
    assert.equal(withLock(c, () => 'ran'), 'ran')
  } finally { w.cleanup() }
})
test('a legacy lock directory is respected unless its recorded owner process is provably gone', () => {
  const w = workspace()
  try {
    const lock = path.join(w.directory, 'lock'), owner = path.join(lock, 'owner')
    const c = context({ home: w.directory, stateDir: w.directory, platform: 'darwin', sleep() {} })
    mkdirSync(lock); writeFileSync(owner, JSON.stringify({ pid: process.pid }))
    assert.throws(() => withLock(c, () => 'never'), /Installer lock exists/)
    // An ownerless legacy lock cannot be shown abandoned, however old it is.
    rmSync(lock, { recursive: true }); mkdirSync(lock)
    const old = new Date(Date.now() - 30 * 24 * 3600 * 1000); utimesSync(lock, old, old)
    assert.throws(() => withLock(c, () => 'never'), /Installer lock exists/)
    assert.equal(existsSync(lock), true)
    const finished = spawnSync(process.execPath, ['-e', ''])
    rmSync(lock, { recursive: true }); mkdirSync(lock); writeFileSync(owner, JSON.stringify({ pid: finished.pid }))
    assert.equal(withLock(c, () => existsSync(lock)), true)
    assert.equal(existsSync(lock), false)
    // A pid reused by another process (different kernel start time) is not the recorded owner.
    mkdirSync(lock); writeFileSync(owner, JSON.stringify({ pid: process.pid, start: 'Mon Nov 11 10:00:00 2026' }))
    const same = context({ home: w.directory, stateDir: w.directory, platform: 'darwin', sleep() {}, processStart: () => 'Mon Nov 11 10:00:00 2026' })
    assert.throws(() => withLock(same, () => 'never'), /Installer lock exists/)
    const reused = context({ home: w.directory, stateDir: w.directory, platform: 'darwin', sleep() {}, processStart: () => 'Tue Nov 12 09:00:00 2026' })
    assert.equal(withLock(reused, () => 'ran'), 'ran')
  } finally { w.cleanup() }
})
test('the mutex database is a stable private file: kept across runs, never replaced, and refused when it is not private or not ours', () => {
  const w = workspace()
  try {
    const file = path.join(w.directory, 'lock.sqlite'), c = context({ home: w.directory, stateDir: w.directory, platform: 'darwin' })
    withLock(c, () => 'first')
    const inode = statSync(file).ino
    assert.equal(statSync(file).mode & 0o077, 0)
    withLock(c, () => 'second')
    assert.equal(statSync(file).ino, inode)
    assert.throws(() => withLock(context({ home: w.directory, stateDir: w.directory, platform: 'darwin', owner: (process.getuid?.() ?? 0) + 1 }), () => 'never'), /not a private/)
    chmodSync(file, 0o644)
    assert.throws(() => withLock(c, () => 'never'), /not a private/)
    assert.equal(statSync(file).ino, inode)
    rmSync(file)
    const target = path.join(w.directory, 'elsewhere'); writeFileSync(target, 'unrelated')
    symlinkSync(target, file)
    assert.throws(() => withLock(c, () => 'never'), /not a private/)
    assert.equal(lstatSync(file).isSymbolicLink(), true); assert.equal(readFileSync(target, 'utf8'), 'unrelated')
  } finally { w.cleanup() }
})
/** @param {string} stateDir */
function stateContext(stateDir) { return context({ home: path.dirname(stateDir), stateDir, platform: 'darwin' }) }

test('a state root that others could write, a symlinked root, or a writable parent is refused before the mutex database is opened', () => {
  const w = workspace()
  try {
    const state = path.join(w.directory, 'state'); mkdirSync(state, { mode: 0o700 })
    const c = stateContext(state)
    chmodSync(state, 0o770)
    assert.throws(() => withLock(c, () => 'never'), /not a private real directory/)
    assert.equal(existsSync(path.join(state, 'lock.sqlite')), false)
    chmodSync(state, 0o700)
    const real = path.join(w.directory, 'real'); mkdirSync(real, { mode: 0o700 })
    const link = path.join(w.directory, 'link'); symlinkSync(real, link, 'dir')
    assert.throws(() => withLock(stateContext(link), () => 'never'), /not a private real directory/)
    assert.equal(existsSync(path.join(real, 'lock.sqlite')), false)
    chmodSync(w.directory, 0o777)
    assert.throws(() => withLock(c, () => 'never'), /not a private real directory/)
    chmodSync(w.directory, 0o700)
    assert.equal(withLock(c, () => 'ran'), 'ran')
  } finally { chmodSync(w.directory, 0o700); w.cleanup() }
})
test('a link on the route to the state root is refused when the directory holding it could be rewritten', () => {
  const w = workspace(), holder = workspace()
  try {
    mkdirSync(path.join(holder.directory, 'state'), { mode: 0o700 })
    const hop = path.join(w.directory, 'hop'); symlinkSync(holder.directory, hop, 'dir')
    const routed = stateContext(path.join(hop, 'state'))
    assert.equal(withLock(routed, () => 'ran'), 'ran')
    chmodSync(w.directory, 0o777)
    assert.throws(() => withLock(routed, () => 'never'), /not a private real directory/)
  } finally { chmodSync(w.directory, 0o700); holder.cleanup(); w.cleanup() }
})
test('a link reached through another link\'s target is part of the route as well', () => {
  const trustedArea = workspace(), exposedArea = workspace(), target = workspace()
  try {
    mkdirSync(path.join(target.directory, 'state'), { mode: 0o700 })
    const exposed = path.join(exposedArea.directory, 'exposed-hop'); symlinkSync(target.directory, exposed, 'dir')
    const trusted = path.join(trustedArea.directory, 'trusted-hop'); symlinkSync(exposed, trusted, 'dir')
    const chained = stateContext(path.join(trusted, 'state'))
    assert.equal(withLock(chained, () => 'ran'), 'ran')
    chmodSync(exposedArea.directory, 0o777)
    assert.throws(() => withLock(chained, () => 'never'), /not a private real directory/)
  } finally { chmodSync(exposedArea.directory, 0o700); trustedArea.cleanup(); exposedArea.cleanup(); target.cleanup() }
})
test('links are followed as the kernel does: `..` applies to the directory a link actually reached, not to its lexical text', () => {
  const safeArea = workspace(), exposedArea = workspace(), trustedArea = workspace()
  try {
    mkdirSync(path.join(safeArea.directory, 'target/state'), { recursive: true, mode: 0o700 })
    mkdirSync(path.join(exposedArea.directory, 'inner')); mkdirSync(path.join(exposedArea.directory, 'target/state'), { recursive: true, mode: 0o700 })
    symlinkSync(path.join(exposedArea.directory, 'inner'), path.join(safeArea.directory, 'pivot'), 'dir')
    symlinkSync(`${safeArea.directory}/pivot/../target`, path.join(trustedArea.directory, 'trusted-hop'), 'dir')
    const pivoted = stateContext(path.join(trustedArea.directory, 'trusted-hop', 'state'))
    assert.equal(withLock(pivoted, () => 'ran'), 'ran')
    chmodSync(exposedArea.directory, 0o777)
    assert.throws(() => withLock(pivoted, () => 'never'), /not a private real directory/)
  } finally { chmodSync(exposedArea.directory, 0o700); safeArea.cleanup(); exposedArea.cleanup(); trustedArea.cleanup() }
})
