# omp-usage-dashboard

Standalone usage dashboard for [omp](https://github.com/can1357/oh-my-pi). Native macOS AppKit app and a shared Node.js collector; no SwiftBar, Orca, or interactive omp session required.

```mermaid
flowchart LR
    A[Usage fetchers registered in omp] --> B[omp usage --json]
    B --> C[usage-core: normalize and cache]
    C --> D[macOS AppKit dashboard]
```

Provider API/authentication patches live separately in [my-omp-patch](https://github.com/dhkimxx/my-omp-patch). They are optional: this dashboard reads whichever providers and accounts your installed omp supports. Installing or removing the dashboard does not install, retarget, or remove provider plugins.

## Platforms

| Platform | Status |
| --- | --- |
| macOS 13+ | Implemented: native notch-aware / floating dashboard, source installer and login startup |
| Ubuntu | **TODO:** desktop frontend and installation/startup integration |
| Windows | **TODO:** native frontend and installation/startup integration |

The common collector and JSON schema are independent of AppKit. There are no placeholder Ubuntu or Windows apps.

## Install on macOS

Requires Node.js **22.18+**, an installed and authenticated omp supporting `omp usage --json`, and Xcode Command Line Tools (`swiftc`, `codesign`) to build. The installed app needs Node and omp, not development dependencies or Bun. Locally exercised with omp **18.18.6**.

```sh
git clone https://github.com/dhkimxx/omp-usage-dashboard.git
cd omp-usage-dashboard
npm ci
npm run macos:install -- --dry-run
npm run macos:install
```

If omp is not discoverable, set `OMP_BIN=/absolute/path/to/omp` for the initial installation. Existing configuration is preserved; environment defaults do not overwrite it on reinstall.

| Installed resource | Location |
| --- | --- |
| App and bundled collector | `~/Applications/OMP Usage.app` |
| Configuration and ownership records | `~/Library/Application Support/omp-usage-panel/` |
| Login LaunchAgent | `~/Library/LaunchAgents/com.dhkim.omp-usage-panel.plist` |
| Usage cache | `~/Library/Caches/omp-usage/` |

**The checkout may be moved or deleted after installation.** Node and omp must remain executable at the absolute paths recorded in `config.json`. Source updates require reinstalling the app.

This release is **source-install distribution**, not a self-contained/notarized binary. It builds for the current Mac architecture and uses ad-hoc signing. To build without installing: `npm run macos:build` → `build/OMP Usage.app`.

### Migration from my-omp-patch

The existing app identifier, LaunchAgent, configuration/cache paths and saved window position are retained, so there is no second app or startup job. The installer verifies ownership before replacement and restores the previous app/job if activation fails. Modified or foreign installations are refused rather than overwritten.

Old installation records are retained as `install-v1.json` when migrating to the dashboard-only ownership record. Historical provider releases are left untouched. Use the provider repository's `plugins:install` separately to adopt those links into its own managed runtime.

Existing `config.json` wins. On a first installation only, compatible historical SwiftBar usage settings are imported; the SwiftBar application itself is not removed.

## Display and controls

- **Notched screen:** the compact black silhouette follows the camera footprint, with thin provider usage lines immediately below it. Hover expands one pure-black board attached directly to the screen top; the camera sits inside an empty header region, with no connecting neck. The expanded board temporarily covers the central menu-bar area and app content.
- **No notch or manual position:** a floating dashboard stays below the menu bar. Hold **Option** when starting a drag to detach and save its position. **Reset position** returns to automatic placement.
- Click a provider line/card for every account and limit belonging to it. **Accounts** opens all connected accounts; **Refresh** bypasses the cache. Details, menus and dragging keep the board open; outside click or **Escape** closes details.
- **Options** / right-click: refresh, all accounts, open config/data folder, reset position, quit. Re-entering during collapse reverses the animation; Reduce Motion disables it.
- Gray tracks show the unused portion; colored fills show usage. The contrasting `|` marks elapsed time where a valid period exists. Mistral calendar-month estimates are explicitly labeled **Estimated**, never used to alter account-selection/exhaustion behavior.
- Unknown values are not zero. Missing limits, partial errors, stale data and over-100% usage remain distinguishable. Cards use consistent 12pt internal padding; additional providers scroll horizontally rather than disappear.

A summary is the **maximum single observed utilization**, not an account total or an assertion that the displayed account is active/exhausted. Details retain all account/limit IDs, balances, resets and notes. A configured metric is matched by exact account/limit identity; another limit's reset is never borrowed.

**Quit** does not immediately restart the app. To reopen it or apply configuration edits:

```sh
launchctl kickstart -k "gui/$(id -u)/com.dhkim.omp-usage-panel"
```

### Configuration

Use **Open config** to edit `config.json`, then restart the app. Do not put API keys in it.

| Field | Default | Meaning |
| --- | --- | --- |
| `nodePath` | Installed Node | Absolute executable path outside the checkout |
| `ompPath` | Discovered omp | Absolute executable path outside the checkout |
| `profile` | `default` | omp profile holding authentication |
| `refreshSeconds` | `60` | Collector invocation interval |
| `cacheMinutes` | `5` | Actual usage-query cache lifetime; `0` queries each time |
| `timeoutSeconds` | `25` | omp subprocess deadline |
| `providers` | `null` | All available providers; an array selects display/order |
| `labels` | `{}` | Provider ID → display name |
| `metrics` | `{}` | Provider ID → exact representative limit ID |
| `warnPercent` | `70` | Warning threshold |
| `criticalPercent` | `90` | Critical threshold |
| `showPace` | `true` | Show elapsed-period marker and percentage |

Find limit IDs in `snapshot.accounts[].limits[].id` from the JSON collector below. Mistral API and Vibe budgets are distinct pools; choosing the displayed metric does not change omp's account selection.

## Collector / integrations

```sh
node packages/usage-core/cli.mjs
node packages/usage-core/cli.mjs --refresh
```

Output contains `snapshot` and `source` (`live`, `cache`, `stale`, `unavailable`). See [the schema](packages/usage-core/types.ts). `npm run usage:collect` is the interactive equivalent; call Node directly when another program needs JSON without npm banners.

Collection uses Node built-ins and the local omp credential store. Cache identity includes the executable, profile and authentication-store path. Failed refreshes retain the last successful snapshot with stale/error information rather than inventing zero usage. Cache files can contain account identifiers: do not commit them.

Manual Refresh also runs the supported `omp usage invalidate` command before the JSON query so omp's own usage cache cannot mask the refresh. It does not change credentials or provider-plugin installation.

Linux cache: `$XDG_CACHE_HOME/omp-usage/` or `~/.cache/omp-usage/`. Override the cache root with `OMP_USAGE_CACHE_DIR`.

## Uninstall

```sh
npm run macos:uninstall -- --dry-run
npm run macos:uninstall
```

Only the owned app and LaunchAgent are removed. Configuration, caches, historical records and provider installations are preserved. Modified/foreign files are not deleted.

Without the checkout, use the installed management code:

```sh
node "$HOME/Applications/OMP Usage.app/Contents/Resources/runtime/apps/macos/uninstall.mjs" --dry-run
node "$HOME/Applications/OMP Usage.app/Contents/Resources/runtime/apps/macos/uninstall.mjs"
```

## Development

```sh
npm ci
npm run verify
npm run macos:build
```

`verify` runs checked JavaScript/TypeScript and Node behavioral tests. On macOS it also compiles/runs Swift model, layout, identity-matching and transition checks. CI verifies on macOS and Ubuntu and compiles the complete AppKit app on macOS. No live credentials or provider requests are needed by the tests.

## OS roadmap

- [ ] **Ubuntu:** select a GNOME/Wayland/X11-compatible desktop surface; implement provider summaries/all-account details, safe multi-monitor placement and user-session startup/install/removal using the existing collector/schema.
- [ ] **Windows:** implement a native dashboard/tray surface with DPI/multi-monitor handling, all-account details and user-session startup/install/removal using the same collector/schema.

## License

[MIT](LICENSE), copyright © 2026 dhkimxx. Extracted from the dashboard/collector previously maintained in `my-omp-patch`.
