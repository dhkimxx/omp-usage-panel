import { execFileSync } from 'node:child_process'
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, rmdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

export const dmgVolumeName = 'OMP Usage'
export const dmgAppName = 'OMP Usage.app'
export const dmgNoteName = 'Install.txt'
/** Short note shipped beside the app. There is deliberately no /Applications shortcut: the app installs itself into ~/Applications. */
export const dmgNote = `OMP Usage

1. Double-click "OMP Usage.app" in this window (or copy it anywhere first).
2. The app opens a one-time setup. Review the detected Node.js and omp paths, then click "Install & Open".
   Clicking Install installs OMP Usage into ~/Applications and registers a per-user login item (LaunchAgent).
   No administrator password is needed.

Requirements: Node.js 22.18 or newer and the omp command-line tool, already installed on this Mac.
OMP Usage never bundles or installs Node.js or omp. Setup never reads, edits or copies your omp credentials or plugins.
Usage collection uses your existing omp installation and its normal authentication.

Trust: this app is ad-hoc signed and its updates are authenticated with an Ed25519 key, but it is not
Apple Developer ID signed or notarized, so macOS may warn the first time you open it. Use the standard
macOS prompt (or System Settings > Privacy & Security > Open Anyway) if you trust this download.
Do not remove quarantine attributes or bypass Gatekeeper.
`
/** Volume metadata that macOS itself may add to a mounted HFS+ image; any other extra entry is rejected. */
const volumeMetadata = new Set(['.fseventsd', '.Spotlight-V100', '.Trashes', '.TemporaryItems', '.DocumentRevisions-V100', '.DS_Store'])

/** Thrown when a mounted image might still be attached or its temporary mount directory might remain. */
export class DmgCleanupError extends Error {
  /** @param {string} message @param {{devices: string[], mountPoint: string}} details @param {unknown} [cause] */
  constructor(message, { devices, mountPoint }, cause) {
    super(message, cause === undefined ? undefined : { cause })
    this.name = 'DmgCleanupError'
    this.devices = devices
    this.mountPoint = mountPoint
  }
}

/** @typedef {(args: string[]) => string} Hdiutil */
/** @type {Hdiutil} */
const systemHdiutil = args => execFileSync('/usr/bin/hdiutil', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })
/** @param {string} plist @returns {any} */
function plistToObject(plist) { return JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '-'], { input: plist, encoding: 'utf8' })) }
/** @param {number} ms */
function sleep(ms) { if (ms > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms) }
/** @param {unknown} error */
function messageOf(error) { return error instanceof Error ? error.message : String(error) }

/**
 * Builds a read-only zlib-compressed HFS+ image (mounts on macOS 13+) holding exactly the app and the install note.
 * @param {{app: string, output: string, hdiutil?: Hdiutil}} options
 * @returns {string} the image path
 */
export function createDmg({ app, output, hdiutil = systemHdiutil }) {
  if (!output.endsWith('.dmg')) throw new Error(`DMG output must end in .dmg: ${output}`)
  if (existsSync(output)) throw new Error(`DMG output already exists: ${output}`)
  if (path.basename(app) !== dmgAppName || !lstatSync(app).isDirectory()) throw new Error(`DMG source must be a real ${dmgAppName} directory: ${app}`)
  const stage = mkdtempSync(path.join(tmpdir(), 'omp-dmg-stage-'))
  try {
    // ditto keeps symlinks, modes, resource forks and xattrs exactly; the staged copy is never mounted, so deleting it is safe.
    execFileSync('/usr/bin/ditto', [app, path.join(stage, dmgAppName)])
    writeFileSync(path.join(stage, dmgNoteName), dmgNote, { mode: 0o644 })
    mkdirSync(path.dirname(output), { recursive: true })
    try {
      hdiutil(['create', '-quiet', '-srcfolder', stage, '-volname', dmgVolumeName, '-fs', 'HFS+', '-format', 'UDZO', '-imagekey', 'zlib-level=9', output])
      const format = plistToObject(hdiutil(['imageinfo', '-plist', output])).Format
      if (format !== 'UDZO') throw new Error(`DMG was created as ${format}, not read-only compressed UDZO`)
    } catch (error) { rmSync(output, { force: true }); throw error }
  } finally { rmSync(stage, { recursive: true, force: true }) }
  return output
}

/**
 * Requires the mounted volume to contain exactly the app bundle and the install note: no Applications link, no second app,
 * no other file. Only macOS volume metadata directories are tolerated.
 * @param {string} mountPoint @returns {string} path of the app inside the volume
 */
export function assertDmgLayout(mountPoint) {
  const unexpected = []
  for (const name of readdirSync(mountPoint)) if (name !== dmgAppName && name !== dmgNoteName && !volumeMetadata.has(name)) unexpected.push(name)
  if (unexpected.length) throw new Error(`DMG must contain exactly ${dmgAppName} and ${dmgNoteName}; unexpected: ${unexpected.sort().join(', ')}`)
  const app = path.join(mountPoint, dmgAppName), note = path.join(mountPoint, dmgNoteName)
  let appStat, noteStat
  try { appStat = lstatSync(app); noteStat = lstatSync(note) } catch { throw new Error(`DMG must contain exactly ${dmgAppName} and ${dmgNoteName}`) }
  if (!appStat.isDirectory()) throw new Error(`${dmgAppName} in the DMG must be a real app directory, not a link or file`)
  if (!noteStat.isFile() || readFileSync(note, 'utf8') !== dmgNote) throw new Error(`${dmgNoteName} in the DMG is not the expected install note`)
  return app
}

/**
 * @param {string} plistText @param {string} mountPoint
 * @returns {{devices: string[], mounted: boolean}} whole-disk devices attached by this call, and whether the volume is mounted at `mountPoint`
 */
function attachedDevices(plistText, mountPoint) {
  /** @type {{ 'dev-entry'?: string, 'mount-point'?: string }[]} */
  const entities = plistToObject(plistText)['system-entities'] ?? []
  const devices = [...new Set(entities.map(entity => entity['dev-entry']).filter(/** @returns {device is string} */ device => typeof device === 'string' && /^\/dev\/disk\d+$/.test(device)))]
  const physical = realpathSync(mountPoint)
  const mounted = entities.some(entity => typeof entity['mount-point'] === 'string' && realpathSync(entity['mount-point']) === physical)
  return { devices, mounted }
}

/**
 * Mounts one DMG read-only at a private mount point, runs `action`, then always detaches the devices this call attached.
 * The mount directory is only ever removed non-recursively and only after the detach succeeded, so mounted content can never be deleted.
 * If detaching or cleanup cannot be confirmed, a DmgCleanupError is thrown (even when `action` succeeded) naming the devices and mount point left behind.
 * @template T
 * @param {string} dmg @param {(mountPoint: string) => T} action
 * @param {{hdiutil?: Hdiutil, detachRetries?: number, detachRetryMs?: number}} [options]
 * @returns {T}
 */
export function withMountedDmg(dmg, action, { hdiutil = systemHdiutil, detachRetries = 4, detachRetryMs = 500 } = {}) {
  const parent = mkdtempSync(path.join(tmpdir(), 'omp-dmg-mount-')), mountPoint = path.join(parent, 'mount')
  mkdirSync(mountPoint, { mode: 0o700 })
  /** @type {string[]} */
  let devices = []
  let attachAttempted = false
  /** @type {{error: unknown} | undefined} */
  let failure
  /** @type {{value: T} | undefined} */
  let result
  try {
    attachAttempted = true
    const plistText = hdiutil(['attach', '-plist', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', mountPoint, dmg])
    let mounted = false
    try { ({ devices, mounted } = attachedDevices(plistText, mountPoint)) } catch (error) { throw new Error(`Could not read hdiutil attach result: ${messageOf(error)}`, { cause: error }) }
    if (!mounted) throw new Error(`The DMG did not mount at the requested private mount point: ${dmg}`)
    result = { value: action(mountPoint) }
  } catch (error) { failure = { error } }

  /** @type {string[]} */
  const problems = []
  // Detach only what hdiutil reported for this attach; when the report was unreadable, the private mount point we created is the owned handle.
  const targets = devices.length ? devices : attachAttempted ? [mountPoint] : []
  for (const target of targets) {
    // A failed attach leaves nothing mounted at the private mount point; there is then nothing to detach.
    if (target === mountPoint && !isMountedPath(mountPoint)) continue
    let detached = false, last = ''
    for (let attempt = 0; attempt <= detachRetries && !detached; attempt++) {
      try { hdiutil(['detach', ...(attempt === detachRetries ? ['-force'] : []), target]); detached = true } catch (error) { last = messageOf(error); sleep(detachRetryMs) }
    }
    if (!detached) problems.push(`could not detach ${target}: ${last.trim()}`)
  }
  if (!problems.length) {
    try { rmdirSync(mountPoint); rmdirSync(parent) } catch (error) { problems.push(`could not remove temporary mount directory ${parent} (left in place): ${messageOf(error)}`) }
  }
  if (problems.length) {
    const hint = devices.length ? ` Detach manually: hdiutil detach ${devices.join(' ')}.` : ''
    const cleanup = new DmgCleanupError(`DMG cleanup uncertain for ${dmg}: ${problems.join('; ')}. Mount point ${mountPoint} was not deleted.${hint}`, { devices, mountPoint }, failure?.error)
    if (failure) cleanup.message += ` Original failure: ${messageOf(failure.error)}`
    throw cleanup
  }
  if (failure) throw failure.error
  return /** @type {{value: T}} */ (result).value
}

/** True when `mountPoint` is on a different filesystem than its parent (a volume is mounted there). @param {string} mountPoint */
function isMountedPath(mountPoint) {
  try { return lstatSync(mountPoint).dev !== lstatSync(path.dirname(mountPoint)).dev } catch { return true }
}

/**
 * Mounts a DMG read-only, enforces the exact payload layout, and runs `action` on the contained app path.
 * @template T
 * @param {string} dmg @param {(app: string) => T} action @param {Parameters<typeof withMountedDmg>[2]} [options]
 * @returns {T}
 */
export function withDmgApp(dmg, action, options) {
  return withMountedDmg(dmg, mountPoint => action(assertDmgLayout(mountPoint)), options)
}
