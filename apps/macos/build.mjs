import { randomUUID } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync, readdirSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { ensureSparkleSdk, readChannel, rootVersion, sourceRoot } from './sparkle.mjs'

export { sourceRoot }
export const runtimeFiles = [
  ...['cli.mjs', 'collector.mjs', 'normalize.mjs', 'summary.mjs', 'index.mjs', 'package.json'].map(f => `packages/usage-core/${f}`),
  ...['collect.mjs', 'config.mjs', 'uninstall.mjs', 'installation.mjs', 'build.mjs', 'ownership.mjs', 'update-transaction.mjs', 'update-ownership.mjs', 'setup-install.mjs', 'sparkle.mjs', 'update-channel.json', 'package.json'].map(f => `apps/macos/${f}`),
  'package.json',
]
const deploymentTarget = '13.0'
const arches = ['arm64', 'x86_64']

/** @param {string} value */
function xml(value) { return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;') }
/** @param {string|number|boolean} value */
function plistValue(value) {
  if (typeof value === 'boolean') return value ? '<true/>' : '<false/>'
  if (typeof value === 'number') return `<integer>${value}</integer>`
  return `<string>${xml(value)}</string>`
}
/** @param {Record<string,string|number|boolean>} entries */
function plist(entries) {
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>${Object.entries(entries).map(([k, v]) => `<key>${xml(k)}</key>${plistValue(v)}`).join('')}</dict></plist>\n`
}

/**
 * Compile one binary per architecture, merging with lipo when more than one is requested.
 * @param {{sources: string[], output: string, targets: string[], extraArgs?: string[]}} options
 */
function compile({ sources, output, targets, extraArgs = [] }) {
  const outputs = targets.map(arch => targets.length === 1 ? output : `${output}.${arch}`)
  targets.forEach((arch, index) => execFileSync('/usr/bin/xcrun', ['swiftc', '-swift-version', '5', '-O', '-target', `${arch}-apple-macosx${deploymentTarget}`, ...extraArgs, ...sources, '-o', outputs[index]], { stdio: 'inherit' }))
  if (targets.length > 1) {
    execFileSync('/usr/bin/lipo', ['-create', ...outputs, '-output', output], { stdio: 'inherit' })
    for (const file of outputs) rmSync(file)
  }
}

/** @param {{outputDirectory?: string, universal?: boolean}} [options] */
export function buildApp({ outputDirectory = path.join(sourceRoot, 'build'), universal = false } = {}) {
  const output = path.resolve(outputDirectory), app = path.join(output, 'OMP Usage.app')
  const nativeDirectory = path.join(sourceRoot, 'apps/macos/native')
  const sources = readdirSync(nativeDirectory).filter(f => f.endsWith('.swift')).sort().map(f => path.join(nativeDirectory, f))
  if (!sources.length) throw new Error('No native Swift sources found')
  if (app === sourceRoot || sourceRoot.startsWith(app + path.sep)) throw new Error('Invalid build output directory')
  if (existsSync(app)) throw new Error(`Build output already exists: ${app}`)
  const version = rootVersion(), channel = readChannel(), sdk = ensureSparkleSdk()
  const targets = universal ? arches : [process.arch === 'arm64' ? 'arm64' : 'x86_64']
  mkdirSync(output, { recursive: true })
  const stage = path.join(output, `.omp-build-${randomUUID()}`), stagedApp = path.join(stage, 'OMP Usage.app'), contents = path.join(stagedApp, 'Contents')
  try {
    mkdirSync(path.join(contents, 'MacOS'), { recursive: true })
    mkdirSync(path.join(contents, 'Frameworks'), { recursive: true })
    for (const file of runtimeFiles) {
      const dest = path.join(contents, 'Resources/runtime', file)
      mkdirSync(path.dirname(dest), { recursive: true })
      copyFileSync(path.join(sourceRoot, file), dest)
    }
    copyFileSync(path.join(sourceRoot, 'LICENSE'), path.join(contents, 'Resources/LICENSE'))
    copyFileSync(sdk.license, path.join(contents, 'Resources/Sparkle-LICENSE'))
    // ditto keeps Sparkle's relative framework symlinks and the vendor's code signatures intact.
    execFileSync('/usr/bin/ditto', [sdk.framework, path.join(contents, 'Frameworks/Sparkle.framework')], { stdio: 'inherit' })
    writeFileSync(path.join(contents, 'Info.plist'), plist({
      CFBundleExecutable: 'OMPUsagePanel', CFBundleIdentifier: 'com.dhkim.omp-usage-panel', CFBundleName: 'OMP Usage', CFBundlePackageType: 'APPL',
      CFBundleVersion: version, CFBundleShortVersionString: version, LSMinimumSystemVersion: deploymentTarget, LSUIElement: true,
      SUFeedURL: channel.feedURL, SUPublicEDKey: channel.publicEDKey, SURequireSignedFeed: true, SUVerifyUpdateBeforeExtraction: true,
      SUSignedFeedFailureExpirationInterval: 0, SUEnableAutomaticChecks: true, SUAutomaticallyUpdate: false, SUAllowsAutomaticUpdates: false, SUScheduledCheckInterval: 86400, SUSendProfileInfo: false, SUEnableJavaScript: false,
    }))
    compile({ sources, output: path.join(contents, 'MacOS/OMPUsagePanel'), targets, extraArgs: ['-F', sdk.root, '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks'] })
    execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', stagedApp], { stdio: 'inherit' })
    execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', stagedApp], { stdio: 'inherit' })
    renameSync(stagedApp, app)
    return app
  } finally { rmSync(stage, { recursive: true, force: true }) }
}
if (import.meta.main) {
  const args = process.argv.slice(2), universal = args.includes('--universal'), rest = args.filter(a => a !== '--universal')
  if (rest.length && (rest.length !== 2 || rest[0] !== '--output')) throw new Error('Usage: node build.mjs [--universal] [--output directory]')
  console.log(buildApp({ outputDirectory: rest[1], universal }))
}
