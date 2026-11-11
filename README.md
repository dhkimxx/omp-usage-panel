# omp-usage-panel

Standalone usage panel for [omp](https://github.com/can1357/oh-my-pi): a native macOS AppKit app on a shared Node.js collector. No interactive omp session required.

It shows whichever providers and accounts your installed omp supports. Installing or removing it does not install, retarget, or remove provider plugins.

## Install

Requires macOS 13+, Node.js **22.18+**, and an authenticated omp that supports `omp usage --json`. Building also needs Xcode Command Line Tools (`swiftc`, `codesign`). Tested with omp 18.18.6.

```sh
git clone https://github.com/dhkimxx/omp-usage-panel.git
cd omp-usage-panel
npm ci
npm run macos:install -- --dry-run   # preview
npm run macos:install
```

If omp is not discoverable, set `OMP_BIN=/absolute/path/to/omp` for the first install. Reinstalling keeps your existing configuration.

The app is installed to `~/Applications/OMP Usage.app` with its own copy of the collector, so the checkout can be moved or deleted. Node and omp must stay at the paths in `config.json`. The source install is a one-time bootstrap; later versions arrive through the in-app updater (see [Updates](#updates)), not by reinstalling from source. The installed app is ad-hoc signed and not notarized.

## Use

- On a notched screen, compact provider rings sit beside the camera. Otherwise the panel floats below the menu bar.
- Hover anywhere on the compact panel—including provider rings and floating mode—to preview the overview. Click a ring, or a provider card in the overview, for that provider's details. Use the overview header's **Providers** dropdown to choose **All** or one provider; the detail view has the same provider filter at the start of its account row, with **Overview** to go back. **More** opens the overview. **Escape** or an outside click collapses it.
- **All** and the provider list come from the full collected catalog, including providers hidden from the summary cards or currently unavailable. The account picker remains available, and original limits and details are retained; these selections only change what is displayed and never change credentials.
- **Options** (or right-click): Settings…, compact settings, refresh, open data folder, reset position, quit.
- **Option-drag** to move the panel; **Reset position** restores automatic placement.
- The summary is the highest single observed utilization, not an account total. Unknown values are not zero.

**Quit** does not immediately restart the app. To reopen it, or to apply manual edits made to `config.json` outside the app:

```sh
launchctl kickstart -k "gui/$(id -u)/com.dhkim.omp-usage-panel"
```

### Compact display

Open **Options → Compact settings…** to choose providers, the left/right camera side and **Maximum slots** (default `3`).

- Selection is independent of the slot cap. **More uses the last slot**: five selected providers with three slots show two rings and **+3**.
- These choices affect only the compact display, not collection, authentication or the expanded dashboard.
- Changes save automatically per configuration path and omp profile, and survive restarts/reinstallation. Clearing every provider leaves a **+** settings button.
- Screen bounds may reduce the effective cap. App/status-menu occupancy is not detected; reduce the count or switch sides if menus overlap.

## Configuration

Open **Options → Settings…** to edit the configuration in a native window with tabs for **Collection**, **Display**, **Providers**, **Labels**, **Metrics** and **Runtime**. **Save & Apply** validates and writes the file privately and atomically, then restarts collection in place—no app restart needed. **Cancel** or closing the window discards your edits. A profile change clears the previous profile's displayed data and uses that profile's compact preferences. API keys and authentication are not edited here; they stay managed by omp.

**Compact settings…** is separate and still saves automatically. The file is `~/Library/Application Support/omp-usage-panel/config.json`; editing it by hand still needs the restart above. Do not put API keys in it.

| Field | Default | Meaning |
| --- | --- | --- |
| `refreshSeconds` | `60` | Collector interval |
| `cacheMinutes` | `5` | Usage cache lifetime; `0` queries every time |
| `timeoutSeconds` | `25` | omp subprocess timeout |
| `providers` | `null` | `null` shows all; an array selects and orders the summary cards only. Hidden providers stay reachable through **Providers → All**/provider |
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

## Updates

After the one-time source install above, the app checks GitHub for new versions. Updates are prebuilt universal (arm64 + x86_64) apps downloaded from [GitHub Releases](https://github.com/dhkimxx/omp-usage-panel/releases); no Xcode or source build is needed for them. Node.js 22.18+ and omp are still required. No prebuilt update has been published in the signed feed yet (the feed is currently empty).

- **Defaults:** daily checks on, notifications on, automatic installation **off**.
- **Settings → Updates** (app-wide, not per omp profile) holds these controls and uses the same **Save & Apply** / **Cancel** as the rest of Settings. **Check for Updates…** in the menu runs a manual check, which ignores Skip and turned-off notifications.
- **Popup:** a new version shows a native prompt with **Update Now** (this version only), **Skip This Version** (that exact version), **Later** (asks again after 24 hours) and **Turn Off Notifications**. Installing automatically is a separate, optional consent that you can grant in the popup or Settings; notifications, Skip and Later never grant it, and Skip/Later also hold automatic installs.
- **When it installs:** automatic installation only restarts the app while it is idle: no Settings window, menu, modal, drag or expanded board.
- **Verification:** the update feed and archive are Ed25519-signed and verified by Sparkle before installation. After Sparkle replaces the app, the watcher checks the installed file tree against the authenticated hash, before the new app starts or the update is committed; a wrong hash rolls back. The updater keeps a copy of its watcher and a backup outside the app bundle, restarts the original LaunchAgent, waits for the new app's startup acknowledgment, and rolls back if it does not report healthy. Your config, auth and provider plugins are preserved. This protects the update path, not against every threat or power loss at any instant.
- **Gatekeeper:** no Apple Developer ID identity is used. The app is ad-hoc signed and not notarized, and the Ed25519 update signature is not Apple code signing or notarization. The updater verifies updates itself, but macOS may still apply its own checks to a copy downloaded manually from GitHub.

## Releasing (maintainers)

The public update key and feed (`updates/appcast.xml`) are already configured and committed; contributors and users need no setup. The private signing key lives only in the maintainer's local Keychain (account `dhkimxx.omp-usage-panel`) and is never stored in the repo, CI or an export.

1. Choose the next version with `npm version <next-version> --no-git-tag-version` (the root `package.json` is the single version source; this keeps the lockfile in sync), then commit and push it to a clean `main`.
2. Publishing needs the existing local Keychain key that matches the committed public key. `release:setup` only establishes a brand-new update channel and is not part of this flow; running it elsewhere would create a key that does not match the pinned public key. If that key is unavailable, signed updates cannot be published until the original key is restored through an OS-supported secure migration.
3. `npm run release:package -- --output <dir> --notes-file <file>` (both flags optional) builds a signed universal package from a `git archive` of the pinned clean `HEAD`. A dirty local package cannot be published.
4. `npm run release:publish -- --notes-file <file> [--dry-run]` requires clean `main` equal to the remote and uploads assets before the feed. `--dry-run` verifies everything without publishing, using only temporary extraction.

Sparkle 2.10.1 (pinned) is bundled for updates; see its license terms.

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
