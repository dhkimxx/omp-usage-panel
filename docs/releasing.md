# Releasing (maintainers)

The public update key and feed (`updates/appcast.xml`) are committed; contributors and users need no setup. The private signing key lives only in the maintainer's local Keychain (account `dhkimxx.omp-usage-panel`) and is never stored in the repo, CI or an export.

1. Choose the next version with `npm version <next-version> --no-git-tag-version` (the root `package.json` is the single version source; this keeps the lockfile in sync), then commit and push it to a clean `main`.
2. Publishing needs the existing local Keychain key that matches the committed public key. `release:setup` only establishes a brand-new update channel and is not part of this flow; running it elsewhere would create a key that does not match the pinned public key.
3. Package from a verified CI candidate (or fully locally):
   - **CI candidate:** the `Package` workflow builds and tests a universal DMG on a GitHub-hosted runner for a trusted `vMAJOR.MINOR.PATCH` tag push matching the root version, or a manual run on `main` (`gh workflow run package.yml --ref main`; find the run id with `gh run list --workflow package.yml`). It uploads `macos-release-<sha>-<run>-<attempt>` (`OMP-Usage-<version>.dmg` + `candidate.json`) as a 14-day Actions artifact with a GitHub build-provenance attestation. The artifact is not public and not update-ready: CI holds no update key, publishes nothing and never touches the feed.
     - `npm run release:verify-ci -- --run <ID>` downloads and authenticates the candidate only (`gh attestation verify`, repository/workflow/source-digest binding, then DMG layout, universal codesign, version and tree). It uses no Keychain and writes no release.
     - `npm run release:package -- --ci-run <ID> --notes-file <file>` re-verifies, then signs those same DMG bytes with the local Keychain key. The run's source SHA must equal your current clean `origin/main` `HEAD`. A candidate for an already published version can only be verified, never repackaged.
   - **Local:** `npm run release:package -- --output <dir> --notes-file <file>` builds a signed universal package from a `git archive` of the pinned clean `HEAD`. A dirty local package cannot be published.
4. `npm run release:publish -- --notes-file <file> [--dry-run]` requires clean `main` equal to the remote and uploads the asset before the signed feed. `--dry-run` runs the preflight and authentication without publishing. Signing and publishing stay local and manual; no GitHub secret or self-hosted runner is used.

## CI

- `Verify` runs the type check, all tests and a full macOS build.
- `Release audit` (`npm run release:audit` locally) checks the committed signed feed against the real public release assets and tag commits, with no secrets. It runs on pushes touching the feed or release code, weekly and manually. It never prunes or deletes anything.

## Feed maintenance

`npm run release:prune -- --keep-version <version>` re-signs the feed with only the kept item, after the kept release's public asset and the live feed verify. It never deletes GitHub releases or tags.

## Bundled components

- **Sparkle 2.10.1** (pinned in `apps/macos/sparkle.mjs`) provides updates; see its license terms.
- **Node.js** (MIT, official Developer ID-signed build) is bundled as `node-<arch>.tar.xz` under `Contents/Resources/node/`, built from the pinned tarballs in `apps/macos/node-runtime.json` (URL, size, SHA-256 of each official tarball and of its `bin/node`, plus the Node.js Foundation team ID). Builds download, verify and repack them into a cache (`OMP_USAGE_NODE_CACHE`, default `~/Library/Caches/omp-usage-panel/node/<version>`). To move to another Node.js 22 release, replace the pinned values from the official `SHASUMS256.txt` and the extracted binary's hash, then release a new app version; the app extracts the new runtime on its next start. Each archive carries Node.js's `LICENSE`.
