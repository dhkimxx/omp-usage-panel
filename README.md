# omp-usage-panel

Standalone usage panel for [omp](https://github.com/can1357/oh-my-pi): a native macOS AppKit app on a shared Node.js collector. No interactive omp session required.

It shows whichever providers and accounts your installed omp supports. Installing or removing it does not install, retarget, or remove provider plugins.

## Install

Requires macOS 13+, an existing Node.js **22.18+** and an authenticated omp that supports `omp usage --json` (tested with omp 18.18.6). Node and omp are not bundled or installed for you; no repository checkout or Swift compiler is needed.

1. Download the DMG from the [latest GitHub release](https://github.com/dhkimxx/omp-usage-panel/releases/latest) and open it.
2. Open **OMP Usage.app** from the DMG (or from Downloads).
3. In the setup window, check the auto-detected Node and omp paths (edit or browse if needed; the omp profile is editable; an existing default config is detected automatically) and click **Install & Open**. Clicking Install also registers a per-user login LaunchAgent.

There is no `/Applications` shortcut. The app copies itself, without admin rights, to the existing managed location `~/Applications/OMP Usage.app` (quarantine and extended attributes preserved), writes its configuration and LaunchAgent, then relaunches from there. Setup does not read, copy or change omp credentials or plugins; the dashboard itself calls `omp usage`, which uses omp's own authentication. An existing valid `config.json` is kept unchanged and its paths and profile are used; an invalid one is reported, not overwritten. Node and omp must stay at the paths in `config.json`.

**Signing:** no Apple Developer ID is used. The app is ad-hoc/Ed25519-signed and not notarized, so macOS Gatekeeper may block the first downloaded copy before the app runs; the setup window cannot address that. This project gives no instructions to bypass quarantine.

Later versions arrive through the in-app updater (see [Updates](#updates)). Managed launches (login startup, `--config`) skip setup.

### Source install (advanced / development)

Not needed for normal use. Requires Xcode Command Line Tools (`swiftc`, `codesign`):

```sh
git clone https://github.com/dhkimxx/omp-usage-panel.git
cd omp-usage-panel
npm ci
npm run macos:install -- --dry-run   # preview
npm run macos:install
```

If omp is not discoverable, set `OMP_BIN=/absolute/path/to/omp`. Reinstalling keeps your existing configuration.

## Use

- On a notched screen, compact provider rings sit on either side of the camera, as chosen per provider. Otherwise a single capsule floats below the menu bar.
- Hover anywhere on the compact panel—including provider rings and floating mode—to preview the overview. Click a ring, or a provider card in the overview, for that provider's details. Use the overview header's **Providers** dropdown to choose **All** or one provider; the detail view has the same provider filter at the start of its account row, with **Overview** to go back. **More** opens the overview. **Escape** or an outside click collapses it.
- **All** and the provider list come from the full collected catalog, including providers hidden from the summary cards or currently unavailable. The account picker remains available, and original limits and details are retained; these selections only change what is displayed and never change credentials.
- The **Providers** and **Account** pickers open a custom dark list panel (not a native menu): each row shows the provider mark, title and subtitle, with a check on the current selection and unavailable choices marked. Use the mouse, **↑/↓**, **Home/End**, **Return/Space**; **Escape** or an outside click closes only the list, and clicking the opener again toggles it. The panel stays open-tracking so the compact panel and updates do not collapse or restart underneath it.
- Settings ID fields (**Providers**, **Labels**, **Metrics**) are ordinary editable text fields with the same custom suggestion list, opened from the chevron or **↓**. Any exact ID can still be typed; nothing is completed unasked. The list never interferes with native editing, IME composition, selection, undo or clipboard shortcuts; keys are only intercepted while the list is open for that field and not composing. **Escape** closes the list before Settings, and picking a suggestion updates the staged draft only.
- OS file dialogs and the **Options**/right-click command menus remain native.
- **Options** (or right-click): Settings…, refresh, open data folder, reset position, quit.
- **Option-drag** to move the panel; **Reset position** restores automatic placement on the configured monitor (it does not change the monitor choice).
- The summary is the highest single observed utilization, not an account total. Unknown values are not zero.

**Quit** does not immediately restart the app. To reopen it, or to apply manual edits made to `config.json` outside the app:

```sh
launchctl kickstart -k "gui/$(id -u)/com.dhkim.omp-usage-panel"
```

### Compact view

Open **Settings → Display → Compact view** to choose which providers appear, set each provider's **Left** or **Right** side of the camera, and set one **Maximum slots** total (default `3`). Changes are staged and apply on **Save & Apply**.

- Selection is independent of the slot cap. The maximum is shared across both wings and includes the single aggregate **More** control: five selected providers with three slots show two rings and **+3**. **More** lists every hidden provider, including ones assigned to the other side.
- A provider is never moved to the opposite side to fit. Each wing is also limited by the physical space beside the camera.
- Moving a provider directly between the left and right wings keeps its ring: both wings' old rings are detached before any are re-attached, and an already detached ring is repaired on the next update.
- These choices affect only the compact display, not collection, authentication or the expanded dashboard.
- Preferences are saved per configuration path and omp profile and survive restarts/reinstallation; older single-side settings are migrated. Clearing every provider leaves a **+** button that opens Settings → Display.
- Once a successful usage result no longer reports a provider, its ring and open provider detail disappear. Its saved selection and side are kept for reconnection; later failed or stale refreshes do not undo a confirmed removal.
- Removal follows collection timing: normal polling defaults to 60 seconds and may serve the five-minute usage cache. **Refresh** bypasses that cache. The panel does not watch or edit omp credentials.
- Without a notch (or when the panel is moved), rings form one contiguous capsule below the menu bar, left group then right group, with no camera gap.
- Screen bounds may reduce the effective cap. App/status-menu occupancy is not detected; reduce the count or change sides if menus overlap.

### Panel placement (monitor)

Open **Settings → Display → Panel placement** and use the **Monitor** dropdown:

- **System primary (Default)** keeps the panel on the display macOS marks as primary (the one with the menu bar in System Settings › Displays). It does not follow the pointer, the active window or keyboard focus, so it stays put while you work on other monitors. If you change the primary display in macOS, the panel follows that change.
- A named monitor pins the panel to that physical display, even when it is not the primary one. Monitors are remembered by display UUID; choosing the primary display explicitly is different from the default, because it keeps that monitor if the primary changes. Monitors with the same name are shown with a short ID suffix.
- If the pinned monitor is disconnected, it stays listed as **Disconnected monitor** (unavailable) and your choice is kept. The panel temporarily uses the System primary display and moves back when that monitor reconnects.
- A position you set with **Option-drag** overrides the configured monitor and follows whichever physical display you drag the panel onto. **Reset position** clears only that override and returns the panel to the configured monitor; saving a different monitor in Settings also clears the override.
- The choice is app-wide (not per omp profile), staged until **Save & Apply**; **Cancel** discards it. macOS display settings are never changed.

## Configuration

Open **Options → Settings…** (the single Settings window; configure/**+** in the compact panel opens it directly at **Display**) to edit the configuration in a dark, custom-styled window with sections for **Collection**, **Display**, **Providers**, **Labels**, **Metrics**, **Runtime** and **Updates**. Edits are staged: **Save & Apply** validates everything, writes the file privately and atomically, saves any changed compact-view preferences, then, only when the collector configuration changed, restarts collection in place—no app restart needed. Compact-view or monitor-only changes do not restart collection. **Cancel** or closing the window discards all staged edits, including compact ones. If the config save fails, nothing else is applied and your draft stays open. Changing the profile clears the previous profile's displayed data; compact preferences are scoped per configuration path and omp profile, so each edited profile shows and saves its own. API keys and authentication are not edited here; they stay managed by omp.

The file is `~/Library/Application Support/omp-usage-panel/config.json`; editing it by hand still needs the restart above. Do not put API keys in it.

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

After installation, the app checks GitHub for new versions. Updates are prebuilt universal (arm64 + x86_64) apps downloaded from [GitHub Releases](https://github.com/dhkimxx/omp-usage-panel/releases); no Xcode or source build is needed for them. Node.js 22.18+ and omp are still required.

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
3. Package, either fully locally or from a verified CI candidate:
   - Local (default): `npm run release:package -- --output <dir> --notes-file <file>` (both flags optional) builds a signed universal package from a `git archive` of the pinned clean `HEAD`. A dirty local package cannot be published.
   - CI candidate: the `Package` workflow (`package.yml`) builds and tests a universal DMG on a GitHub-hosted runner for a trusted `vMAJOR.MINOR.PATCH` tag push matching the root version, or a manual run on `main` (`gh workflow run package.yml --ref main`; find the run id with `gh run list --workflow package.yml`). It uploads `macos-release-<sha>-<run>-<attempt>` (`OMP-Usage-<version>.dmg` + `candidate.json`) as a 14-day Actions artifact with a GitHub build-provenance attestation. The artifact is **not** public and **not** update-ready: it is unsigned for updates, and CI holds no update key, publishes nothing and never touches the feed.
     - `npm run release:verify-ci -- --run <ID>` downloads and authenticates the candidate only (`gh attestation verify`, repository/workflow/source-digest binding, then DMG layout, universal codesign, version and tree). It uses no Keychain and writes no release.
     - `npm run release:package -- --ci-run <ID> --notes-file <file>` re-verifies, then signs those same DMG bytes with the local Keychain key. The run's source SHA must equal your current clean `origin/main` `HEAD`, so bump and commit the next version before packaging. A candidate for an already published version (e.g. 1.0.0) can only be verified; it is refused for packaging and never overwrites a published release.
   - See [`gh attestation verify`](https://cli.github.com/manual/gh_attestation_verify) and [artifact attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds).
4. `npm run release:publish -- --notes-file <file> [--dry-run]` requires clean `main` equal to the remote and uploads assets before the feed. `--dry-run` performs preflight and authentication of the existing package without publishing, using only temporary extraction; it is not proof of installation, and does not establish notarization. Signing and publishing stay local and manual; no GitHub secret or self-hosted runner is needed or used.

Automatic CI: `Verify` runs on its existing triggers. `Release audit` (`npm run release:audit` locally) checks the committed signed feed against the real public GitHub release assets and tag commits, with no secrets. It runs on pushes touching the feed, weekly and manually; it is not triggered by `release: published`, because the asset intentionally precedes the feed. It never prunes or deletes anything.

Release flow: `release:package` builds the single DMG and signed feed item; `release:publish` uploads the asset before the feed. Only after a real public SDK upgrade proof, run `npm run release:prune -- --keep-version <version>` to re-sign the feed with only the kept item. Delete older GitHub release objects only after the pruned feed is live; git tags are retained. `release:prune` never deletes GitHub releases itself.

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
