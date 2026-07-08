# How Eaon updates work, and how to ship one

## How it works

- On every launch, the app fetches one small JSON file (the **update
  manifest**) from `UpdateChecker.manifestURL`
  (`Eaon-desktop/Services/UpdateChecker.swift`).
- If the manifest's `latestVersion` is newer than the app's own
  `AppVersion.current`, the "New Version" card appears (bottom-right) with
  **Show Release Notes / Remind Me Later / Update Now**.
- **Update Now** downloads the file at `downloadURL` into the user's
  Downloads folder with live progress, then opens it (a `.dmg` mounts the
  installer — one drag to Applications finishes it).
- **Remind Me Later** snoozes *that version* for 24 hours. A newer version
  published during the snooze still prompts.
- An unreachable server or malformed manifest is a silent no-op — users are
  never shown update errors they didn't ask for. (Settings → General →
  "Check for Updates" is the manual check, and that one does report its
  outcome either way.)

## One-time setup

1. Pick a stable HTTPS URL for the manifest (any static host: your site,
   GitHub releases/raw, S3, …).
2. Put that URL in `UpdateChecker.manifestURL`. Until you do, checks fail
   silently and nobody is ever prompted.

## Shipping a release

1. Build and package the new app, upload the `.dmg` to your host.
2. Edit the hosted manifest JSON (shape in `update-manifest.sample.json`):
   - `latestVersion` — the new version, e.g. `"0.8.3"`
   - `downloadURL` — the uploaded `.dmg`'s URL
   - `releaseNotes` — plain text, `\n` for line breaks (optional)
3. **Last**, bump `AppVersion.current` in `UpdateChecker.swift` for the
   *next* development cycle — the version you just shipped must match what
   its own binary reports, or freshly-updated apps will re-prompt forever.

Every already-installed copy sees the new manifest on its next launch and
shows the card. That's the whole pipeline — no rebuild of anything
server-side, just one JSON edit plus one file upload.

## Known limits (deliberate, for now)

- The updater **downloads and opens** the new release; it does not silently
  replace the running app. Self-replacement is only safe once Eaon
  ships as a signed `.app` bundle — at that point, adopt
  [Sparkle](https://sparkle-project.org) (the standard macOS update
  framework: signed appcasts, atomic install, auto-relaunch) rather than
  extending this hand-rolled version.
- The manifest and download are trusted on the honor system (HTTPS only,
  no signature verification). Fine for a dev/beta loop; not enough for
  wide distribution — Sparkle's EdDSA signing closes that gap too.
