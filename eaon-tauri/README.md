# Eaon — cross-platform (Tauri)

This is the **cross-platform rebuild of Eaon** — Windows, Linux, and macOS from
one codebase. The original app (`../Eaon-desktop`) is native macOS SwiftUI and
can only ever run on the Mac; SwiftUI does not exist on Windows. Rather than
port it (impossible — the UI layer is 100% SwiftUI), this is a ground-up
rebuild on **Tauri** (a Rust core + a web UI), which is exactly the approach
Jan.ai — the app Eaon is chasing — uses to be cross-platform.

Tauri was chosen over Electron on purpose: it uses the OS's built-in webview
(WebView2 on Windows) instead of bundling a whole Chromium, so binaries are a
few MB instead of ~100+ MB, and memory use is a fraction of Electron's. That is
what "optimized for Windows" actually means here.

## Status — full 1:1 UI rebuild

The frontend is a faithful component-for-component port of the macOS app's
views (each Svelte component names the Swift view it ports): floating sidebar
card with pinned chats, projects, and date-bucketed history; the chat surface
with model attribution, markdown + syntax-highlighted code (TS ports of the
Mac app's own MarkdownLineParser/SyntaxHighlighter), Thinking disclosures,
and hover actions; the radius-26 composer with mode switcher; the ⌘/Ctrl+K
search palette; the full Settings modal (General, Custom Instructions,
Appearance with Light/Dark/System + accent colors + font size, Shortcuts,
Privacy, Statistics, Hardware, Aqua API keys, BYOK custom providers, Ollama
management); the Models library driven by the same CuratedOllamaModels.json
the Mac app bundles, with live pull progress and verified deletion; Projects;
and the confirmation/rename dialogs. Exact ThemeColors palettes (both
themes), bundled IBM Plex fonts, frameless window with custom controls.

Fully working: chat streaming (Ollama + Aqua + BYOK, one OpenAI-compatible
path), real stop/cancellation, per-conversation background generation,
persistence to disk (state.json), model pulls/deletes, both themes.

**Agent mode (coding agent) — now wired cross-platform.** The full tool set
(write_file, edit_file, read_file, search_code, find_files, run_shell,
list_directory, create_folder, move_item) is implemented in the Rust core
(`src-tauri/src/tools.rs`) with the same safety model as macOS: writes
confined to the home folder / temp dir, protected system paths refused,
`sudo`/`runas` blocked, symlink-escape closed, output/timeout caps. The
frontend runs the same multi-step agent loop and `eaon:computer tool="…"`
tool-call fences as the Mac app (`src/lib/agent.ts`), including
codebase-search ("work on an existing repo like Cursor") and the
Sandboxed/Auto confirmation dialog. The Rust tool layer has unit tests
(`cargo test`, 5 passing) covering path-escape refusal, system-path refusal,
the write/read/edit round-trip, unique-edit enforcement, search + noise-dir
skipping, and the sudo block.

**Local API Server — now wired cross-platform.** A loopback,
OpenAI-compatible endpoint (`server.rs`) any tool can point at (GET
/v1/models, POST /v1/chat/completions), transparently proxying to whichever
provider serves the requested model. It carries the SAME security hardening
as the macOS server, verified end-to-end over real sockets (`cargo test`):
loopback-only bind, Host-header + browser-Origin anti-DNS-rebinding gates,
constant-time Bearer auth, no wildcard CORS. Settings → Local API Server
turns it on and shows the base URL + key.

**Memory — now wired cross-platform.** Eaon silently learns durable facts
about the user from each chat (a background, non-streaming model call —
`chat_complete` in Rust, `memory.ts` on the frontend, same extraction prompt
and "what qualifies" rules as macOS), dedupes them, stores them locally, and
injects them into future chats. Settings → Memory has the auto-learn toggle,
a manual add, and a delete/clear list. The extraction-parse logic (fenced /
prose-wrapped / malformed model output, dedup) is unit-verified.

**Skills management UI** — the full library page (enable/disable/remove,
install from a GitHub URL, import from ~/.claude/skills, write one by hand),
on top of the /name invocation that already worked.

**Attachments** — photos & files from the composer's + menu, plus pasted
screenshots. Images are canvas-normalized (PNG, 1568px long edge — the same
provider-agnostic cap as macOS), stored under the app data dir, sent as real
OpenAI `image_url` content parts to vision-capable models, and as an
"[Attached: …]" note otherwise — the exact macOS split. Path-traversal-safe
storage is unit-tested in Rust.

**Image generation** — the `eaon:image` tool fence in any chat, resolved
against whichever backend exists: a BYOK image provider (OpenAI-style or a
local Automatic1111/SD server), a local Ollama diffusion model (detected via
Ollama's real `capabilities` field), or Aqua's hosted image models — all
four wire shapes in one Rust command, results attached to the reply.
Settings → Image Providers manages connections and the on/off toggle.

**Web search** — the `eaon:search` fence against the same keyless search API
as macOS, with the same teaching block (device clock first), looped
tool-results rounds in plain chat, and numbered, citable results. Verified
live against the real endpoint.

**Model parameters** — Settings → Model Parameters: temperature / top-p /
max tokens / penalties, each opt-in (off = not sent at all), merged into
requests in Rust, with the macOS retry-without-parameters fallback when a
model rejects them (matcher unit-tested against real provider error shapes).

**MCP plugins** — Settings → Plugins: remote Streamable-HTTP servers (the
same individually-verified preset catalog as macOS: GitHub, Linear,
Supabase, Stripe, Sentry, …, paste-a-token auth including the nonstandard
schemes) AND local stdio servers (`npx …` — a transport macOS doesn't have
yet). Tools are taught via the same `eaon:mcp` fence, worked example, and
water-filled 6000-char catalog budget as macOS; calls run in both chat and
Agent loops behind the Sandboxed confirmation. The protocol layer
(JSON-or-SSE responses, session ids, pagination, newline-delimited stdio) is
unit-tested including a REAL end-to-end round-trip against a fake stdio MCP
server.

**Eaon Claw (device control)** — folded into Agent mode behind Settings →
Eaon Claw, exactly like macOS: trash (recoverable, never rm), open/quit
apps, open URLs (http/https only), open paths — cross-platform in Rust with
name/URL/path gates unit-tested. The Agent also gained `ask_user` — a real
question dialog with option buttons + free text the loop pauses on.

**Smaller parity features** — read-aloud on every reply (OS voices via
SpeechSynthesis), first-run onboarding, a Check-for-Updates card reading the
same release manifest as macOS, and an outbound HTTP(S) proxy setting
applied to ALL Rust-side traffic (chat, search, images, MCP).

Still macOS-only, deliberately: AppleScript app-driving (no Windows/Linux
equivalent — the Claw page says so instead of half-working).

### Verified

- Whole Rust app compiles + links (`cargo build`, ~400 crates).
- Frontend builds (`npm run build`).
- App boots and runs (verified on macOS — Tauri runs on all three desktop OSes).
- The exact streaming loop works end-to-end against live Ollama:
  `cargo run --example stream_smoke` → `SMOKE PASS`.

### Not yet verified

- **The Windows `.exe`/`.msi` build itself.** The code is cross-platform by
  construction (Rust core uses rustls, not OpenSSL; no macOS-only APIs; Tauri
  handles WebView2 automatically), but producing and smoke-testing the actual
  Windows binary must happen **on a Windows machine or in CI** — it can't be
  cross-compiled-and-run from a Mac. That's the immediate next real step.

## Run it (development)

Requires [Rust](https://rustup.rs) and Node 18+.

```bash
npm install
npm run tauri dev
```

## Build a Windows installer

Run this **on a Windows PC** (or a Windows CI runner) with Rust + Node
installed:

```bash
npm install
npm run tauri build
```

Output lands in `src-tauri/target/release/bundle/` — an `.msi` (WiX) and/or
`.exe` (NSIS) installer. GitHub Actions with a `windows-latest` runner is the
standard way to produce these without owning a Windows box.

## Architecture

```
src/routes/+page.svelte   The chat UI (Svelte 5 runes). No network here.
src-tauri/src/lib.rs       Rust core: chat_stream + list_ollama_models commands.
                           All HTTP/streaming lives here (tighter webview CSP).
src-tauri/examples/        stream_smoke.rs — live end-to-end streaming test.
```

## Roadmap to parity with the macOS app

Rough order, each an independent chunk:

1. **Windows build in CI** — a GitHub Actions workflow producing `.msi`/`.exe`
   artifacts, so "does it run on Windows" stops being unverified.
2. Provider settings — Ollama URL, the hosted API key, BYOK endpoints (the Rust
   path already handles all three; this is UI + persisted settings).
3. Conversation history + persistence (the Mac app keeps these in a JSON blob;
   here it'd be a small local store).
4. Markdown + syntax-highlighted code rendering in replies.
5. Model download/management UI (Ollama pull, progress).
6. llama.cpp support (runs on Windows; MLX does not — it's Apple-only and is
   simply dropped on non-Mac platforms).
