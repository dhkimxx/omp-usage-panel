# Installing OMP Usage

Requires macOS 13+ and an authenticated omp that supports `omp usage --json` (tested with omp 18.18.6).

## One-line installer

```sh
curl -fsSL https://raw.githubusercontent.com/dhkimxx/omp-usage-panel/main/install.sh | sh
```

The script downloads the latest release DMG, checks its size and SHA-256 against the digest GitHub publishes for that asset, mounts it read-only, installs the app and unmounts it again. It needs no admin rights and never uses `sudo`.

Options go after `sh -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/dhkimxx/omp-usage-panel/main/install.sh | sh -s -- --omp /absolute/path/to/omp --profile work
```

`--version X.Y.Z` installs a specific release. Run the command again to reinstall (quit the running app first); later versions arrive through the in-app updater.

The app is copied to `~/Applications/OMP Usage.app`; its configuration and a per-user login LaunchAgent are written, and it starts. Installing does not read, copy or change omp credentials or plugins. An existing valid `config.json` is kept unchanged and its omp path and profile are used; an invalid one is reported, not overwritten.

## Signing and Gatekeeper

No Apple Developer ID is used. The app is ad-hoc/Ed25519-signed and not notarized. macOS marks files that a browser downloads with a quarantine attribute and then blocks the first launch of an unnotarized app; files fetched by `curl` are not marked, so the one-line installer never triggers that prompt. Its trust model is the one you already extend by running it: TLS to GitHub for the script, the release metadata and the DMG, with the DMG checked against the digest in the same API response. Read [`install.sh`](../install.sh) before running it.

## Bundled Node.js

The app ships a pinned official Node.js 22 (about 49 MB for both architectures) and, on first run, extracts the copy for your Mac's architecture to `~/Library/Application Support/omp-usage-panel/runtime/` (about 113 MB, excluded from backups, verified against pinned hashes and Node.js's Developer ID signature). Your own Node.js, whatever its version, is never used to run the app. omp is not bundled or installed for you.

## Manual install (DMG)

1. Download the DMG from the [latest release](https://github.com/dhkimxx/omp-usage-panel/releases/latest) and open it.
2. Open **OMP Usage.app**. A browser-downloaded copy is quarantined, so macOS asks you to allow it in System Settings → Privacy & Security first; this project gives no instructions to bypass quarantine.
3. In the setup window, check the auto-detected omp path (the profile is editable; an existing default config is detected) and click **Install & Open**. This also registers the login LaunchAgent.

There is no `/Applications` shortcut: the app copies itself to `~/Applications` with its quarantine and extended attributes preserved.

## Source install (development)

Requires Xcode Command Line Tools (`swiftc`, `codesign`):

```sh
git clone https://github.com/dhkimxx/omp-usage-panel.git
cd omp-usage-panel
npm ci
npm run macos:install -- --dry-run   # preview
npm run macos:install
```

If omp is not discoverable, set `OMP_BIN=/absolute/path/to/omp`. Reinstalling keeps your existing configuration.

## Uninstall

From a checkout:

```sh
npm run macos:uninstall -- --dry-run
npm run macos:uninstall
```

Without one, run the bundled uninstaller with the extracted Node.js:

```sh
"$HOME/Library/Application Support/omp-usage-panel/runtime/"node-*/node "$HOME/Applications/OMP Usage.app/Contents/Resources/runtime/apps/macos/uninstall.mjs"
```

Only the owned app, the LaunchAgent (`~/Library/LaunchAgents/com.dhkim.omp-usage-panel.plist`) and the extracted Node.js runtime are removed. Configuration, caches, records and provider installations are kept. Modified or foreign files are not deleted.
