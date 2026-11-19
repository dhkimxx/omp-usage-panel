import { uninstall } from './installation.mjs'

if (import.meta.main) {
  const args = process.argv.slice(2)
  if (args.includes('--help')) {
    console.log('Usage: node uninstall.mjs [--dry-run]\nRemoves only the owned app, LaunchAgent and managed Node runtime; retains configuration and legacy migration records.')
  } else if (args.some(arg => arg !== '--dry-run') || args.filter(arg => arg === '--dry-run').length > 1) {
    console.error('Usage: node uninstall.mjs [--dry-run]')
    process.exitCode = 1
  } else {
    try { console.log(uninstall({ dryRun: args.includes('--dry-run') }).join('\n')) }
    catch (error) { console.error(`Uninstall failed: ${error instanceof Error ? error.message : String(error)}`); process.exitCode = 1 }
  }
}
