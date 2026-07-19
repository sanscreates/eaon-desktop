# Releasing the Windows build

Eaon's Windows app is this Tauri project. The macOS app is a **separate**
native SwiftUI project (`../Eaon-desktop`, built with Xcode) and is released
on its own — nothing here touches it.

You do **not** need a Windows PC. The build runs on a `windows-latest` GitHub
Actions runner (`.github/workflows/release.yml`), which is how you produce and
test a real `.exe` from a Mac.

## Cut a release

1. Bump the version in **`src-tauri/tauri.conf.json`** (`"version"`). Follow the
   same scheme as the Mac app — e.g. `2026.2.0`. (Optional: the CI also stamps
   this from the tag, so the tag is the source of truth either way.)
2. Commit.
3. Tag it `v<version>` and push the tag:

   ```bash
   git tag v2026.2.0
   git push origin v2026.2.0
   ```

That tag push triggers the workflow. It builds the installer and creates a
**draft** GitHub Release named `Eaon v2026.2.0 (Windows)` with the `.exe`
(NSIS) and `.msi` attached. Review it in the repo's Releases tab, then press
**Publish**. Nothing is public until you do.

> The whole `eaon-tauri/` folder is currently untracked in git — commit it (and
> keep `node_modules/`, `build/`, `src-tauri/target/` ignored, as `.gitignore`
> already does) before pushing a tag, or CI will have nothing to build.

## Test the build without releasing

From the repo's **Actions** tab → **Release (Windows)** → **Run workflow**.
That path builds the installer and uploads it as a run artifact
(`eaon-windows-installer`) — no release, no tag needed. Use it to confirm the
Windows build is green before cutting a real tag.

## Installing an unsigned build (what to tell users)

This build isn't code-signed yet, so Windows **SmartScreen** shows a blue
"Windows protected your PC" dialog on first run. That is expected for any
unsigned app — it is not a virus warning about Eaon specifically. To install:

1. Double-click the `.exe`.
2. On the SmartScreen dialog, click **More info**.
3. Click **Run anyway**.

Some browsers (Edge/Chrome) also flag the download as "not commonly
downloaded" — choose **Keep** / **Keep anyway**.

**Removing the warning for good** requires an Authenticode code-signing
certificate (an OV cert is ~$100–300/yr; SmartScreen reputation still takes a
little time to build unless you buy an EV cert). Once you have one, Tauri signs
during bundling — set `bundle.windows.certificateThumbprint` (plus
`digestAlgorithm`/`timestampUrl`) in `tauri.conf.json`, or pass the cert to
`tauri-action` via secrets. No app code changes are involved.

## Why no cross-platform code changes were needed

The app was already written to be OS-agnostic, so "make it work on Windows"
needed **zero** path or structural rewrites:

- All disk paths come from Tauri's per-OS path APIs, not hardcoded strings:
  `app_data_dir()` (→ `%APPDATA%\dev.eaon.desktop\` on Windows) for
  `state.json`, and `home_dir()` for the `~/.claude/skills` scan (→
  `C:\Users\<you>\.claude\skills`). Paths are composed with `PathBuf::join`,
  which uses the right separator per OS.
- TLS is `rustls` (see `src-tauri/Cargo.toml`), not the system OpenSSL — so the
  Windows build needs no C toolchain or OpenSSL install.
- WebView2 (the Windows web runtime) is handled by the NSIS bundler
  automatically: it ships a bootstrapper that installs WebView2 if the machine
  doesn't already have it. Nothing to configure.
- No macOS-only APIs are used anywhere in `src-tauri/`.
