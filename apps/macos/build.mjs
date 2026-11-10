import { randomUUID } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync, readdirSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const sourceRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
export const runtimeFiles = [
  ...['cli.mjs', 'collector.mjs', 'normalize.mjs', 'summary.mjs', 'index.mjs', 'package.json'].map(f => `packages/usage-core/${f}`),
  ...['collect.mjs', 'config.mjs', 'uninstall.mjs', 'installation.mjs', 'build.mjs', 'package.json'].map(f => `apps/macos/${f}`),
]
export function buildApp({ outputDirectory = path.join(sourceRoot, 'build') } = {}) {
  const output = path.resolve(outputDirectory), app = path.join(output, 'OMP Usage.app')
  const sources = readdirSync(path.join(sourceRoot, 'apps/macos/native')).filter(f => f.endsWith('.swift')).sort().map(f => path.join(sourceRoot, 'apps/macos/native', f))
  if (!sources.length) throw new Error('No native Swift sources found')
  mkdirSync(output, { recursive: true })
  if (app === sourceRoot || sourceRoot.startsWith(app + path.sep)) throw new Error('Invalid build output directory')
  if (existsSync(app)) throw new Error(`Build output already exists: ${app}`)
  const stage = path.join(output, `.omp-build-${randomUUID()}`), stagedApp = path.join(stage, 'OMP Usage.app'), contents = path.join(stagedApp, 'Contents')
  try {
    mkdirSync(path.join(contents, 'MacOS'), { recursive: true })
    for (const file of runtimeFiles) {
      const dest = path.join(contents, 'Resources/runtime', file)
      mkdirSync(path.dirname(dest), { recursive: true })
      copyFileSync(path.join(sourceRoot, file), dest)
    }
    copyFileSync(path.join(sourceRoot, 'LICENSE'), path.join(contents, 'Resources/LICENSE'))
    writeFileSync(path.join(contents, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>OMPUsagePanel</string><key>CFBundleIdentifier</key><string>com.dhkim.omp-usage-panel</string><key>CFBundleName</key><string>OMP Usage</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string><key>LSMinimumSystemVersion</key><string>13.0</string><key>LSUIElement</key><true/></dict></plist>\n`)
    execFileSync('/usr/bin/xcrun', ['swiftc', '-swift-version', '5', '-O', '-target', `${process.arch === 'arm64' ? 'arm64' : 'x86_64'}-apple-macosx13.0`, ...sources, '-o', path.join(contents, 'MacOS/OMPUsagePanel')], { stdio: 'inherit' })
    execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', stagedApp], { stdio: 'inherit' })
    renameSync(stagedApp, app)
    return app
  } finally { rmSync(stage, { recursive: true, force: true }) }
}
if (import.meta.main) {
  const args = process.argv.slice(2)
  if (args.length && (args.length !== 2 || args[0] !== '--output')) throw new Error('Usage: node build.mjs [--output directory]')
  console.log(buildApp({ outputDirectory: args[1] }))
}
