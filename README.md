# OMP Usage

A native macOS menu-bar panel that shows your [omp](https://github.com/can1357/oh-my-pi) provider usage at a glance: compact rings beside the notch (or a floating capsule), a full dashboard on hover, and signed in-app updates. Node.js is bundled; you don't install it.

## Install

Requires macOS 13+ and an authenticated omp that supports `omp usage --json`.

```sh
curl -fsSL https://raw.githubusercontent.com/dhkimxx/omp-usage-panel/main/install.sh | sh
```

It installs `OMP Usage.app` to `~/Applications` and registers a login item. No admin rights are needed. Options go after `sh -s --`: `--omp /path/to/omp`, `--profile NAME`, `--version X.Y.Z`.

The app is ad-hoc signed and **not notarized**. The one-line installer avoids macOS's first-launch prompt, so read [`install.sh`](install.sh) before running it. Prefer a DMG? Grab it from [Releases](https://github.com/dhkimxx/omp-usage-panel/releases/latest). Details: [docs/install.md](docs/install.md).

## Usage

- Hover the panel for an overview; click a ring or card for provider details.
- **Options** (or right-click): Settings, refresh, quit. **Option-drag** moves the panel.
- Settings choose providers, left/right placement and monitor.

More: [usage](docs/usage.md) · [configuration](docs/configuration.md).

## Updates

The app checks GitHub daily and offers Ed25519-signed updates; automatic installation is off by default (Settings → Updates).

## Uninstall

```sh
"$HOME/Library/Application Support/omp-usage-panel/runtime/"node-*/node "$HOME/Applications/OMP Usage.app/Contents/Resources/runtime/apps/macos/uninstall.mjs"
```

This removes the app, its login item and the unpacked Node.js. Your configuration, caches and omp are kept.

## Development

```sh
npm ci
npm run verify       # type check and tests
npm run macos:build  # writes build/OMP Usage.app
```

Maintainers: [docs/releasing.md](docs/releasing.md).

## License

[MIT](LICENSE).
