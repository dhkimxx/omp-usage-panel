# omp-usage-dashboard

Standalone usage dashboard for [omp](https://github.com/can1357/oh-my-pi): a native macOS AppKit app on a shared Node.js collector. No interactive omp session required.

It shows whichever providers and accounts your installed omp supports. Installing or removing it does not install, retarget, or remove provider plugins.

## Install

Requires macOS 13+, Node.js **22.18+**, and an authenticated omp that supports `omp usage --json`. Building also needs Xcode Command Line Tools (`swiftc`, `codesign`). Tested with omp 18.18.6.

```sh
git clone https://github.com/dhkimxx/omp-usage-dashboard.git
cd omp-usage-dashboard
npm ci
npm run macos:install -- --dry-run   # preview
npm run macos:install
```

If omp is not discoverable, set `OMP_BIN=/absolute/path/to/omp` for the first install. Reinstalling keeps your existing configuration.

The app is installed to `~/Applications/OMP Usage.app` with its own copy of the collector, so the checkout can be moved or deleted. Node and omp must stay at the paths in `config.json`. Source updates require reinstalling. The build is ad-hoc signed for the current Mac architecture and not notarized.

## Use

- On a notched screen the panel sits around the camera. Otherwise it floats below the menu bar.
- Hover to preview, click to pin. **Escape** or an outside click collapses it.
- **Options** (or right-click): refresh, all accounts, open config/data folder, reset position, quit.
- The summary is the highest single observed utilization, not an account total. Unknown values are not zero.

**Quit** does not immediately restart the app. To reopen it or apply config edits:

```sh
launchctl kickstart -k "gui/$(id -u)/com.dhkim.omp-usage-panel"
```

## Configuration

Edit `~/Library/Application Support/omp-usage-panel/config.json` with **Open config**, then restart the app. Do not put API keys in it.

| Field | Default | Meaning |
| --- | --- | --- |
| `refreshSeconds` | `60` | Collector interval |
| `cacheMinutes` | `5` | Usage cache lifetime; `0` queries every time |
| `timeoutSeconds` | `25` | omp subprocess timeout |
| `providers` | `null` | `null` shows all; an array selects and orders them |
| `labels` | `{}` | Provider ID → display name |
| `metrics` | `{}` | Provider ID → limit ID shown as its representative metric |
| `warnPercent` / `criticalPercent` | `70` / `90` | Thresholds |
| `showPace` | `true` | Show the elapsed-period marker |

`nodePath` and `ompPath` must be absolute. `profile` (default `default`) names the omp profile that holds authentication. Metric limit IDs are at `snapshot.accounts[].limits[].id` in collector output. Choosing a metric changes only the display, not omp's account selection.

## Collector

```sh
node packages/usage-core/cli.mjs            # JSON: snapshot, source, optional error
node packages/usage-core/cli.mjs --refresh  # runs `omp usage invalidate` first
```

`source` is `live`, `cache`, `stale`, or `unavailable`. Schema: [types.ts](packages/usage-core/types.ts). A failed refresh keeps the last good snapshot, marked `stale`; zero usage is never invented. Cache files can contain account identifiers, so do not commit them. Cache root: `OMP_USAGE_CACHE_DIR`.

## Uninstall

```sh
npm run macos:uninstall -- --dry-run
npm run macos:uninstall
```

Only the owned app and LaunchAgent (`~/Library/LaunchAgents/com.dhkim.omp-usage-panel.plist`) are removed. Configuration, caches, records and provider installations are kept. Modified or foreign files are not deleted.

Without the checkout:

```sh
node "$HOME/Applications/OMP Usage.app/Contents/Resources/runtime/apps/macos/uninstall.mjs"
```

## Development

```sh
npm ci
npm run verify       # type check and tests; Swift checks run on macOS
npm run macos:build  # writes build/OMP Usage.app
```

## License

[MIT](LICENSE).
