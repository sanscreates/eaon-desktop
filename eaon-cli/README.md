# Eaon CLI

Eaon in your terminal — agentic coding, Eaon Claw, and plain chat, for any
model: local (Ollama) or hosted (Aqua / your own OpenAI-compatible key).
Cross-platform by construction (Node.js + Ink — the same stack Claude Code's
own CLI runs on): macOS, Linux, and Windows all run the identical code path.

This is a fresh implementation, not a port of the Mac app's Swift or the
Tauri build's Rust — but it deliberately carries over their hard-won tool
contracts, safety rules, and prompting lessons (see "Design notes" below) so
behavior stays consistent across all three surfaces.

## Install / run

```bash
cd eaon-cli
npm install
npm run build
npm link      # makes `eaon` available globally, or just run node dist/cli.js
```

Requires Node.js 18.17+ (uses the platform `fetch`/`ReadableStream` for
streaming — no HTTP client dependency).

## Modes

- **Chat** — plain conversation, no tools.
- **Agent** — a real coding agent: `write_file`, `edit_file`, `read_file`,
  `run_shell`, `list_directory`, `create_folder`, `move_item`, `open_path`,
  scoped to the project you launched Eaon in (relative paths resolve
  against it, matching how Claude Code treats your working directory as the
  project — this is a deliberate change from the Mac app's always-home-rooted
  design, which doesn't have a "current project" concept).
- **Eaon Claw** — the coding tools plus the wider remit: `trash_item`,
  `open_app`, `quit_app`, `open_url`, and (macOS only) `run_applescript`.

Switch with `/mode <chat|agent|claw>` or `--mode` at launch.

## Permission modes

- **Sandboxed** (default) — every non-read-only tool call asks first.
- **Auto** — tool calls run immediately, no prompt.

Toggle with **Shift+Tab** (asks "are you sure?" on the way into Auto) or
`/permission <sandboxed|auto>`. `list_directory` never asks either way — it
only reads names, not contents.

## Commands

Type `/` in the composer for live autocomplete, or see them all:

| Command | What it does |
| --- | --- |
| `/help` | list commands and shortcuts |
| `/mode <chat\|agent\|claw>` | switch mode |
| `/permission [sandboxed\|auto]` | show/set the permission mode |
| `/model [name]` | switch model, or list if no name given |
| `/models` | list every model available right now |
| `/pull <name>` | download a model via Ollama |
| `/init` | scan the project and write `EAON.md` (auto-loaded into future system prompts) |
| `/clear`, `/new` | start a fresh session |
| `/resume [id]` | list or reopen a past session |
| `/cost` | approximate usage for this session |
| `/exit` | quit |

## Flags

```
eaon                              interactive (default: Chat mode, Sandboxed)
eaon --mode agent                 start in Agent mode
eaon --model ollama:qwen3.6       start with a specific model
eaon --auto                       start in Auto permission mode
eaon --cwd ~/projects/thing       set the project root (default: cwd)
eaon -p "add a .gitignore" --mode agent --auto
                                   one-shot, non-interactive (like Claude
                                   Code's -p) — prints the result and exits.
                                   Agent/Claw + -p REQUIRES --auto: there's
                                   no terminal to confirm actions in.
```

## Models and providers

Eaon CLI merges three sources into one picker, same precedence as the Mac
app and the Tauri build:

- **Aqua** — set `EAON_AQUA_API_KEY`, or put `aquaApiKey` in the config file.
- **Local (Ollama)** — auto-detected at `http://127.0.0.1:11434` (override
  with `EAON_OLLAMA_URL` or `ollamaBaseUrl` in config). Native tool-calling
  is used automatically for any model whose `/api/tags` capabilities report
  `"tools"`; everything else falls back to a taught text format (see below)
  — so even a model with no function-calling support can still act, not
  just describe what it would do.
- **BYOK** — any OpenAI-compatible endpoint. Add one to `customProviders` in
  the config file: `{ id, displayName, baseURL, apiKey, modelIDs }`.

Config lives at `~/.eaon/cli/config.json` (created on first run); sessions
at `~/.eaon/cli/sessions/`.

## Design notes

- **Dual-channel tool calling.** Every request offers native OpenAI-style
  `tools`, AND the system prompt always teaches a text-fence fallback
  (` ```eaon:computer tool="write_file" `, plus a prefixless/bare-name
  shorthand). A model that supports native calling just uses it; a model
  that doesn't (or ignores the tools array) still has a real path to act.
  Verified live against both kinds of model — see below.
- **Thinking-only stalls get nudged, not silently dropped.** A reasoning
  model that produces only a `<think>` span with nothing after it gets a
  corrective message asking it to act, instead of the turn quietly ending.
  Three identical failures in a row (not three failures total) stop the
  loop instead of grinding forever.
- **Path safety is enforced in code**, not just asked of the model: writes/
  edits/moves/creates are restricted to the project root, the user's home
  folder, or the system temp folder; `sudo` is refused outright; deletes go
  to the Trash/Recycle Bin, never a permanent delete.
- **Live-verified**, not just built: real runs against a local Ollama
  server covered plain chat, Agent mode with a model that has native tool-
  calling (file genuinely written and executed), Agent mode with a model
  that does NOT (exercised the text-fence fallback, including a model that
  fabricated a "ran it" narrative without calling the tool — which is why
  the prompt explicitly forbids describing a command's output without
  actually having called it), Claw mode, and `edit_file`'s targeted-replace
  path — every one independently checked against the real filesystem
  afterward, not just the model's claim. The Sandboxed permission gate
  (pause-and-wait for a real answer, approve/deny/always-allow) was driven
  directly against the compiled agent loop with scripted answers, since a
  live interactive terminal session isn't drivable from here.
- **NOT yet verified**: the interactive terminal UI itself (Ink rendering,
  keystrokes, autocomplete, Static-list scrollback) — there's no way to
  drive a real TTY from an automated environment; execution on actual
  Windows/Linux machines (written portably — see `src/platform.ts`, the
  single file every OS-specific decision routes through — and grep-audited
  for stray POSIX assumptions, but never run there); and live Aqua/BYOK
  requests (no credentials available here — implemented against the same
  documented request/response shapes the Mac app and Tauri core already use
  successfully). Try these and report back before treating them as settled.

## Not built yet

- Real OS-level GUI automation (mouse/keyboard/screenshots) for Claw —
  scoped out deliberately. Claw's tool set is filesystem/shell/app-launch/
  URL/AppleScript(macOS), matching what's genuinely portable and testable;
  true cross-platform screen automation is a much bigger, riskier
  undertaking (accessibility permissions, X11 vs. Wayland, etc.) and would
  need its own dedicated pass.
- Packaging/distribution (npm publish, a Homebrew formula, a Scoop
  manifest, a signed installer). Right now this runs from source.
- llama.cpp/MLX as first-class local backends — any local OpenAI-compatible
  server (llama-server, LM Studio, etc.) already works today as a BYOK
  entry pointed at its base URL; MLX doesn't apply outside Apple Silicon so
  it was never in scope for a cross-platform CLI.
