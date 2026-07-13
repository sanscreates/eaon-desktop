# Changelog

All notable changes to Eaon are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/) — newest release on top.

## [2026.1.9] — 2026-07-13

### Added
- Eaon Claw — a one-click, on-device agent mode that controls this actual
  Mac (files, shell, apps, and the browser) to carry out real multi-step
  tasks, off until explicitly enabled with full disclosure of what it can
  do and its guardrails (asks first, Trash not delete, no sudo, no
  passwords/purchases).
- A 4-mode sidebar: Chat, Agent (sandboxed coding), Eaon Claw (on-device
  control), and Image Studio — each its own capability context, picked
  before a conversation starts via a segmented control you can tap or
  smoothly drag between modes, sitting right on the composer.
- Several new local models (Qwen3.6, Gemma4 26B, Llama4 Maverick, and
  more), plus a "NEW" badge in the model library so recently-added models
  stand out.

### Fixed
- Eaon Claw denying access to device/browser control on some local models
  (e.g. Nemotron) — it now leads with a clear statement of what it can do
  instead of a buried, easily-ignored instruction.
- Local models (Ollama/llama.cpp) sometimes showing Meta's logo instead
  of their real provider's — a matching bug caused by the internal
  `ollama:`/`llamacpp:` id prefixes both containing the substring "llama".
- Added a real Cerebras logo (was a generic fallback icon before).

## [2026.1.8] — 2026-07-12

### Added
- Image generation — use an image model over the API (Aqua's hosted
  models, or a BYOK cloud key) or a local one running on this Mac
  (Automatic1111-compatible servers like DrawThings/ComfyUI, or an
  Ollama-served diffusion model), with zero extra setup. Settings →
  Image Providers.
- A model attribution header (name + logo) on every reply, so it's always
  clear which model actually answered.
- Multi-step agent replies (a tool call followed by more text) now render
  as one continuous message instead of restarting the header and typing
  indicator for every step, with a live "what's happening right now"
  indicator between steps — including a subtle per-letter wave animation
  on the "Thinking…" text.
- A "Thinking" dropdown under any reply that used real reasoning
  (DeepSeek-R1, QwQ, and other reasoning models served locally through
  Ollama, or DeepSeek's own API) — click to see the model's actual
  chain-of-thought, collapsed by default instead of dumped as raw
  `<think>` tags into the reply.
- "Always allow tool calls" (Settings → Privacy, on by default) — code
  execution and connected-plugin (MCP) tool calls run without asking
  each time. Desktop Control still confirms every action regardless,
  since it can move the mouse and type on your behalf.
- Local API Server (Settings → Local API Server, off by default) — run a
  local, OpenAI-compatible server on this Mac that any external tool
  (a script, a coding CLI, another app) can point at, routed through
  whichever backend — Aqua, a BYOK key, or a local model — actually
  serves the requested model. Streaming and non-streaming both work.
  Bound to this Mac only; requires an API key by default.

### Fixed
- A stray rounded line could appear along the top of the sidebar, from a
  system titlebar decoration view rendering at the wrong size once the
  window's traffic-light controls were repositioned.
- A downloaded local image-generation model (e.g. from Ollama) failing
  with "does not support chat" now works — image models need a different
  endpoint than chat models, handled automatically.

## [2026.1.7] — 2026-07-11

### Added
- Plugins — connect real accounts (GitHub, Stripe, Cloudflare, PostHog,
  Semrush, Linear, Supabase, Render, Neon, Datadog, Resend, Sentry,
  Notion, Vercel, LaunchDarkly, Slack) and let the model call their tools
  directly on your behalf — create an issue, query analytics, check a
  deployment, and so on. Every call shows exactly what it's about to do
  and asks first. Uses native tool-calling where the model supports it,
  so it works the same reliable way ChatGPT/Claude's tool use does.
  Settings → Plugins.
- Computer Control (Beta) — ask Eaon to organize files, run shell
  commands, or open/close/navigate apps and websites on this Mac. Off by
  default. Every change asks first; deletions go to the Trash, never a
  permanent delete; there's no admin (sudo) access, no touching system
  files, and it will never enter passwords, buy anything, or change
  account settings. Settings → Computer Control.
- Settings → Hardware — live CPU, memory, and OS info for this Mac, the
  same numbers Eaon already checks before telling you whether a local
  model will actually fit.
- "Learn from your existing chats" — a one-click, on-demand pass that
  mines durable facts out of conversations you had before Memory was
  turned on, instead of only learning going forward. A separate
  "Automatically learn new facts" toggle lets you keep everything already
  remembered working while turning off the silent per-message learning
  specifically. Settings → Memory.
- Settings → General: an "Automatic Update Check" toggle (checks on
  startup and periodically while Eaon is open, not just once), and a Data
  Folder card showing exactly where downloaded local models and
  attachments live, with Show in Finder / Copy Path.
- Custom providers can now have their own logo — click the badge on any
  of your BYOK connections (Settings → Model Providers) to pick an image,
  for the common case where the closest built-in brand icon doesn't
  really look like what you connected.

### Fixed
- The app's on-disk data folder was still physically named "AquaChat"
  from before the rename — never user-visible until the new Data Folder
  card was about to display it. Migrated to "Eaon" automatically
  (renamed, not copied, so existing downloaded models aren't duplicated
  or orphaned).
- Gateway 5xx retries were too short to survive a real provider hiccup —
  three tries across roughly 1.5 seconds, observed to sometimes land
  entirely inside a several-second flap and surface a hard error the very
  next try would have cleared. Now five tries with backoff spanning about
  6 seconds. The model list fetch, which previously had no retry at all,
  is covered the same way.

### Changed
- The Privacy page's "Messages & attachments" description is now
  provider-neutral ("any API provider," not naming Aqua specifically).

## [2026.1.6] — 2026-07-10

### Added
- Live web search — models can now search the internet for time-sensitive
  or current information (news, prices, scores, recent releases, "as of
  today" facts) instead of answering from training data alone. Backed by
  [MIKLIUM](https://github.com/MIKLIUM-Team/MIKLIUM)'s free, keyless
  search API. Works automatically across every provider (Aqua, your own
  API key, and local models) via native tool-calling where the model
  supports it, with a fenced-text fallback (`eaon:search`) for models that
  don't. On by default; turn it off in Settings → Privacy, where the new
  "Web search" toggle also discloses exactly where those queries go.
- The model is now told the current date and time (from this Mac's clock),
  so "what's today?" / "what time is it?" are answered instantly and
  correctly instead of triggering a web search — a search can't reliably
  report the local wall-clock time anyway. This is also the anchor the
  model uses to judge what genuinely postdates its training and therefore
  actually warrants a search.

### Changed
- Sharpened the web-search guidance so models search only when a question
  really needs current, outside information — and skip it for things they
  already know, can reason out, or were just told (like the date/time).
  Verified live: a model that previously web-searched even for "what time
  is it" now answers that from context and reserves search for genuinely
  current questions.
- Gateway/server errors (HTTP 5xx, including the "API error (502)" some
  models intermittently return) now say plainly that it's the provider
  having a temporary problem with that specific model — not something on
  your end — and suggest switching models, rather than showing a bare
  status code with no way forward.

## [2026.1.5] — 2026-07-09

### Fixed
- The traffic-light buttons (close/minimize/zoom) only responded to
  clicks and hover right at their very edge. Cause: they're nudged down
  to sit on the sidebar's header row, but their containing titlebar strip
  stayed its factory height — the moved buttons were still fully
  *visible* outside it, but hover/click only register on the part still
  inside the parent, leaving a ~1pt sliver as the only live area. The
  titlebar strip now resizes along with the buttons.
- The Models tab could show a large empty region on a wide window, with
  the actual list pinned to the left edge. The list's content is
  intentionally capped at 720pt so rows don't stretch absurdly wide, but
  the container holding it filled the whole window and top-left-aligned
  everything instead of centering the capped block. Now centered.

## [2026.1.4] — 2026-07-08

### Fixed
- The model picker's blank-gaps-while-scrolling bug, for real this time.
  2026.1.3's fix deduplicated Aqua's own catalog, but the actual trigger
  was the same model id arriving from two different sources at once —
  e.g. a custom (BYOK) gateway serving `deepseek-v4-flash` while Aqua's
  catalog also lists it. Both copies land in the same picker section
  (everything routes by bare model id), and duplicate ids inside one
  list corrupt SwiftUI's scroll layout. The merged all-sources list is
  now deduplicated at the point where Aqua, custom-provider, and local
  models are combined, keeping the copy with the proper display name —
  so the row also reads "DeepSeek V4 Flash" instead of the raw id.

## [2026.1.3] — 2026-07-08

### Fixed
- The model picker could show large blank gaps while scrolling, hiding
  models below the fold. Cause: the live model catalog occasionally
  listed the same model twice (once with a proper display name, once
  without) — SwiftUI's model list requires unique ids per row, and a
  duplicate silently breaks its scroll layout instead of just showing
  twice. Deduplicated before the list ever reaches the UI, preferring
  whichever copy has a real name.
- Three buttons (Update Now, and Save/Add in Custom Instructions and
  Memory) hardcoded white text on their accent-colored fill — invisible
  for anyone using the "white" accent option, since that's white text on
  a white button. Now uses the accent-aware foreground the app already
  had a helper for (`AppearanceSettings.onAccentColor`), which just
  hadn't been wired into these three.

### Changed
- Aqua is no longer a permanent fixture in Settings → Model Providers on
  a fresh install — it now shows as an "Add Aqua" entry point, same
  discoverability as adding a custom provider, and only earns a
  permanent row once a key is actually saved.
- The update card now has an explicit close (×) button — separate from
  "Update Now" — so declining is never ambiguous. Closing it (or
  clicking × without picking Update Now) never installs anything; you
  can always check again later from Settings → General → Check for
  Updates. Updates have never installed without an explicit "Update Now"
  click — this just makes the "no" path as obvious as the "yes" path.

## [2026.1.2] — 2026-07-08

### Added
- Memory — Eaon can quietly remember durable facts you share (name, role,
  ongoing projects, preferences) and bring them into future chats. Off by
  default; reviewable and editable any time in Settings → Memory.
- Real vision support — attached/pasted images are now actually sent to
  models that support it (verified via `ModelCatalog.supportsVision`), as
  a proper multi-part payload in whichever wire format the active
  provider speaks (OpenAI content-array, Anthropic image blocks, Gemini
  inline_data). Previously an attachment became nothing but its filename
  in the text sent to the model, despite the UI showing a vision icon and
  rendering the image in the chat bubble.
- A confirmation dialog before the coding agent runs generated code for
  the first time in a conversation — it executes with full user
  permissions and no sandbox, so this is a real decision, not a
  formality. Approving covers the rest of that conversation; a new chat
  asks again.
- Lightweight syntax highlighting for chat code blocks and the coding
  workspace's file editor (keywords, strings, comments, numbers) —
  covering Python, JS/TS, Swift, Bash, JSON, Go, Rust, Ruby, PHP, HTML,
  CSS, C/C++, Java, SQL, and YAML.
- Markdown tables now render as real tables instead of raw pipes/dashes.
- Real logos for 7 more model providers that previously fell back to a
  plain SF Symbol: Amazon, Cohere, AI21 Labs, Liquid AI, Allen Institute
  for AI, Upstage, and Groq — sourced from Simple Icons (CC0) and Lobe
  Icons (MIT, AI-provider-specific), each verified to actually be that
  company's mark before bundling. Aqua's own provider row now renders the
  app's real brand mark natively instead of a generic icon. Reka AI and
  Writer still have no available permissively-licensed mark and keep
  their SF Symbol fallback.

### Fixed
- The update manifest URL pointed at a stale domain/path and never
  resolved to anything real.
- "Copy Link" in the share sheet copied a URL with no real page behind
  it. It now copies the actual chat transcript, which works today.
- The share sheet's X/LinkedIn/Reddit buttons were silent no-ops; they
  now show an honest "coming soon" state like the rest of the app does
  for unbuilt features.
- `textTertiary`'s light-mode color failed WCAG AA contrast (~3.24:1
  against white, needs 4.5:1) — most noticeable in timestamps and other
  small de-emphasized text. Darkened to clear the bar; dark mode was
  already fine and is unchanged.

### Changed
- Removed the forced "enter your Aqua API key" screen that gated the
  entire app on first launch. Eaon now opens straight into the chat —
  set up whichever provider you actually want (Aqua, your own API key, or
  a local model) from Settings, whenever you want. The composer's nudge
  when nothing's configured yet is provider-neutral too, not Aqua-specific.
- API keys are now stored in UserDefaults instead of the system Keychain.
  Reason: this app is ad-hoc signed (no paid Apple Developer ID), and an
  ad-hoc signature isn't stable across rebuilds — every update looked like
  a "different app" to Keychain, triggering a scary "wants to use your
  confidential information" system prompt on every single update. Given
  the choice between that and plain local storage for what's just an API
  key, plain storage won. If self-updating ever moves to a stable signing
  identity, this is worth revisiting.

## [2026.1.0] — 2026-07-08

First official release under the new versioning scheme (`YYYY.MINOR.PATCH`
instead of semver).

### Added
- Self-updating installer — "Update Now" downloads, verifies, and installs
  the new version in place and relaunches automatically. No more manual
  quit-and-drag-to-Applications.
- One-click download-and-chat for Hugging Face GGUF models and Ollama
  models, including a real quantization picker.
- Command palette (⌘K) — jump to Settings pages, switch model, set theme,
  in addition to conversation search.
- Idle model auto-unload and configurable keep-alive for local Ollama
  models, plus background model warming on selection.
- Custom instructions, applied to every conversation.
- Export/import all conversations, and delete-all-data.
- Context-window usage indicator per model.
- Pinned conversations.
- Real IBM Plex Mono/Sans typography throughout, with a techy/open-source
  visual direction.
- A signed-locally, drag-to-Applications .dmg installer.

### Changed
- Renamed from AquaChat to Eaon (app identity, source layout, package
  name); "Aqua" is kept only as the underlying model provider's name.
- Wider sidebar; removed the redundant account row at the bottom (Settings
  is still reachable from the main nav).

### Fixed
- A silent data-loss bug where the AquaChat → Eaon-desktop rename stranded
  existing conversation history in the old UserDefaults domain — existing
  users are migrated automatically on first launch.

## [0.8.2] — 2026-07-07

Last release under the old `0.x` versioning, immediately prior to the
Eaon rename.
