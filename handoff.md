# Handoff — Agent mode as a real coding agent

## Goal

Turn Eaon's **Agent mode** into a real, on-device coding agent — like Cursor /
Claude Code — for *any* model the user picks (local Ollama models, GLM,
Nemotron, DeepSeek, etc.), not just capable cloud models:

- The model should write real files to the user's Mac, run them, read the
  output, and iterate until the code works.
- A **Shift+Tab** toggle switches between **Sandboxed** (confirm every
  command — light purple pill) and **Auto** (unsandboxed, runs without
  asking — amber pill), with an "are you sure?" gate on the way *into* Auto.
- This should feel reliable across weak and strong models alike. The user
  has explicitly said getting models to actually code is still the core
  unsolved problem — this is not done yet.

## Current state of the code

Agent mode now has real plumbing, not just a demo:

- **`DesktopControl.swift`** — added `write_file` (writes real file content,
  guarded to home/`/tmp`/`/Volumes` only, creates parent dirs, refuses to
  clobber a directory). Added `DesktopTool.codingTools` (the subset Agent
  gets: `write_file, run_shell, list_directory, create_folder, move_item,
  open_path`) and `DesktopControlTool.codingInstructionBlock()` — the
  coding-specific system prompt with exact fence-format examples.
- **`ChatViewModel.swift`**:
  - `mergedNativeTools` gives Agent mode the coding tool subset (not the
    full Claw device catalog, not MCP plugins).
  - `systemPromptHistory` sends `codingInstructionBlock()` in Agent mode.
    **Just fixed this session:** MCP plugin instructions (GitHub, Cloudflare,
    Supabase, Notion, Vercel) were leaking into Agent's prompt via a
    `!inClaw` check that should have been `currentMode == .chat` — this is
    what caused GLM 5.2 to think it had those services and get confused
    about "the transcript." Changed the guard to `currentMode == .chat`.
  - `executeAgentTools`' `.computerCall` case now allows execution in
    `.agent` (previously Claw-only), refuses non-coding tools when in Agent,
    and — new this session — sets a real `failureSignature` on parse/JSON
    failures so 3 identical failures in a row stop the loop instead of
    grinding to a gateway 502.
  - Added `agentAutoRun: Bool` (Sandboxed/Auto state, NOT persisted —
    resets to Sandboxed every launch) and `isAskingToEnterAutoMode`, plus
    `requestAgentPermissionToggle()` / `confirmEnterAutoMode()` /
    `cancelEnterAutoMode()`.
  - `confirmDesktopCallIfNeeded` bypasses the ask when `currentMode ==
    .agent && agentAutoRun`.
  - `maxAgentSteps` raised to 40 for Agent (was 16), matching Claw — coding
    iterates a lot.
- **`CodeWorkspace.swift`** (`WorkspaceParser`) — the fence parser now
  recognizes the *shorthand* a model commonly emits, `` ```eaon:write_file ``
  instead of the canonical `` ```eaon:computer tool="write_file" `` — maps
  any bare `eaon:<kind>` where `<kind>` is a real `DesktopTool` name straight
  to a `.computerCall`. (Verified with a standalone parser replica — 7/7
  cases pass, including that MCP routing still works.)
- **`ChatViewModel.swift`** (again) — the "tool block couldn't be parsed"
  error message is now mode-aware: Agent/Claw get a real `eaon:computer
  tool="write_file"` example with the actual tool list; only Chat-adjacent
  MCP calls get the old `eaon:mcp server="<server id>"` example. (This
  fixed a bug where the *old* hardcoded MCP-format error taught models to
  literally emit `server="<server id>"` as a literal string, which then
  failed as "not a connected service" and spiraled — this was the actual
  cause of the first screenshot's infinite error loop.)
- **`ChatComposer.swift`** — Shift+Tab handler (`EnterSendingTextView`
  intercepts keyCode 48 + `.shift`), `AgentPermissionPill` (the
  Sandboxed/Auto pill, visible throughout the conversation in Agent mode,
  not just before the first message like the mode switcher).
- **`Dialogs.swift`** — `AutoModeConfirmationDialog`, the are-you-sure sheet
  for entering Auto.
- **`RootView.swift`** — wires the Auto-mode dialog in as an overlay.
- **`EaonMode.swift`, `ModeHomeViews.swift`, `SidebarView.swift`,
  `ChatHomeView.swift`** — Image Studio mode was removed entirely this
  session (separate, already-resolved thread — image generation itself
  still works via the model picker, it's just not a dedicated mode
  anymore).
- **`AudioPlayerBubble.swift`** (untracked, new file) — a standalone,
  **not-yet-wired-up** audio player UI component built earlier this
  session per a design reference. Unrelated to the coding-agent work.
  Nothing currently renders it.
- **`CuratedOllamaModels.json`** — has an uncommitted diff (+136 lines)
  from earlier local-model catalog work in this session; not touched in
  the coding-agent work described here.

Nothing has been committed yet. `git status` shows all of the above as
modified/untracked in the working tree.

## What's been tried that failed / is still failing

1. **First reported bug (Nemotron 3 Ultra):** repeated `"tool block...
   couldn't be parsed"` loops ending in a 502. Root cause turned out to be
   the hardcoded MCP-format re-emit example teaching the model to write a
   literal `server="<server id>"` string. **Fixed** (mode-aware error
   message + real failure signature so it stops after 3 identical
   failures) — not yet re-verified live by the user after the fix.
2. **Second reported bug (GLM 5.2):** model responds as if there's "no real
   request in the transcript," lists GitHub/Cloudflare/Supabase/
   Notion/Vercel as available. Root cause: the MCP plugin instruction
   block was being sent in Agent mode's system prompt (`!inClaw` instead of
   `currentMode == .chat`), telling the model about five services it didn't
   actually have tools for, and burying the coding instructions under that
   bulk. **Just fixed, not yet built/tested.** This is the most recent
   change and the most urgent to verify.
3. **User-reported (via mid-turn message, not yet acted on):**
   - A tool-call parse error the user pasted (`ERROR: a tool block in your
     reply couldn't be parsed...`) — this looks like the pre-fix error
     format, so likely resolves once the GLM fix above is confirmed
     working, but hasn't been independently re-checked against this exact
     transcript.
   - `run_shell` hitting **`error: externally-managed-environment`** when a
     model tried `pip install` on this Mac (PEP 668 — Homebrew's Python
     blocks system-wide pip installs). **Not yet addressed at all.** The
     coding prompt currently says models "may install packages if the task
     needs them (pip/npm)" without accounting for this — needs either (a)
     teaching the model to use a venv first, or (b) a code-level
     workaround (auto-creating a venv per project, or defaulting pip calls
     to `--break-system-packages` in `run_shell`, which has real
     downsides). Needs a decision, not just a prompt tweak.
   - **"The models are not writing code in the folder"** — the user's
     clearest complaint, still open. Not yet root-caused. Possible causes
     not yet checked: whether `write_file`'s path guard is silently
     rejecting relative/ambiguous paths some models emit; whether models
     are calling `run_shell` with `python3 -c "..."` / heredocs instead of
     `write_file` at all (never triggering a real file write); whether the
     project folder gets created but files land somewhere else because a
     model didn't pass `working_directory` consistently. **This needs
     investigation with real transcripts, ideally from the exact model the
     user is using, before making further changes.**
4. **End-to-end model testing (this session):** built a Python harness
   (`test_agent_e2e.py`, since deleted from scratch — not committed
   anywhere) that posed the real agent-mode system prompt + tool schemas to
   local Ollama models directly:
   - `nemotron-3-nano:4b` → **passed** (called `create_folder` correctly).
   - `deepseek-r1:7b` → **failed** (talked about its plan, never emitted a
     tool call).
   - Cloud-hosted Ollama models (`glm-5.1:cloud` etc.) **could not be
     tested this way** — they 403'd on direct API calls (need whatever
     auth Eaon itself uses, not a bare local request). So the actual GLM
     5.2 fix above has **not been verified against a live GLM response** —
     only reasoned from reading the prompt-assembly code.

## Next step

1. **Rebuild and relaunch**, then have the user retry the exact GLM 5.2
   prompt ("build a simple python snake game") to confirm the MCP-catalog
   leak fix actually resolves the "no real request" confusion.
2. **Root-cause "models aren't writing code in the folder"** specifically —
   ask the user for (or capture) a fresh transcript after the above fix,
   and check: is `write_file` being called at all, with what path, and
   does the confirmation dialog (Sandboxed mode) show a real absolute path
   before it's approved? This is the highest-priority open item since it's
   the user's most direct complaint.
3. Decide and implement a fix for the `externally-managed-environment` pip
   failure — most likely: teach the coding prompt to create/activate a
   venv before any pip install, since silently passing
   `--break-system-packages` risks the user's system Python.
4. Once both are fixed, re-run the `deepseek-r1:7b`-style failure case
   (a model that plans in prose instead of calling a tool) — consider
   whether the prompt needs an even more forceful "call a tool NOW, don't
   describe what you'll do" instruction for weaker/reasoning models, similar
   to the `clawIdentityPreamble` forcefulness that fixed a similar denial
   problem in Eaon Claw earlier this session.
5. Only after the user confirms real coding works end-to-end on at least
   one weak local model and one cloud model should this be committed —
   nothing from this work has been committed yet.

## Update — 2026-07-13: root-caused "models aren't writing code" + pip venv

The user hit both open items live and pasted real transcripts. Root cause
found for the file-writing bug, and it's a different, more specific bug than
anything above — the fixes at the top of this doc (MCP-catalog leak,
mode-aware error message) were real but were not the reason files weren't
landing on disk.

**Root cause:** `WorkspaceParser.events()` (`CodeWorkspace.swift`) is shared
by two unrelated features: Chat's sandboxed code-workspace panel (a
`file="..."` fence there is intentionally *ephemeral* — it never touches
real disk, just an in-memory tree for the live preview/editor) and Agent
mode's real coding loop. `ChatViewModel.refreshWorkspace()` re-derives that
panel from *every* assistant message regardless of mode, and
`executeAgentTools` excluded `.write` events from `hasActions` — both
decisions correct for Chat, both wrong for Agent. Net effect: any model
that reached for the extremely common `​```lang file="path"​` convention (or
a bare, unattributed code block — the single most natural thing a
chat-tuned model does when asked to "build" something) instead of the exact
`eaon:computer tool="write_file"` fence would render a fully convincing file
in the workspace panel and get either silence or a confusing "couldn't be
parsed" error — while nothing ever touched the real filesystem. This is
almost certainly the primary cause of "the models are not writing code in
the folder," independent of which specific model is used.

**Fixed (`ChatViewModel.swift`, `executeAgentTools`):**
- `.write` events now count toward `hasActions` in Agent mode (previously
  excluded in every mode).
- A `.write` event whose sanitized path starts with `~/` — unambiguous,
  since `sanitizePath` strips a leading `/` from a truly absolute path but
  never touches a leading `~/` (verified empirically, not just reasoned
  through — see below) — is now auto-promoted to a real, guarded
  `write_file` call (same confirmation/Sandboxed-Auto flow as the canonical
  fence). So `​```python file="~/snake-game/snake.py"​` now really writes the
  file, no re-prompt needed.
- A `.write` event with a bare relative path (no real anchor to guess) gets
  a corrective tool-result naming the exact filename and the real fence to
  re-emit, with a `failureSignature` so 3 identical misses stop the loop.
- A reply with **zero** parseable events but a complete, recognizable-language
  bare code fence (no attributes at all — the deepseek/GLM-style case) now
  gets a similar corrective nudge instead of the loop silently ending with
  no error and no file. New helper: `containsBareCodeFence`.
- `DesktopControlTool.codingInstructionBlock()` (`DesktopControl.swift`) now
  explicitly states a plain code block or `file="..."` fence saves nothing.

**Fixed — pip `externally-managed-environment`:** decided on the
prompt-teaches-venv approach (not `--break-system-packages`, not an
implicit auto-venv). `codingInstructionBlock()`'s environment paragraph now
gives the exact `python3 -m venv .venv && .venv/bin/pip install <package>`
recipe and says to run scripts via `.venv/bin/python3`. Belt-and-suspenders:
`DesktopControlService.runShell` (`DesktopControl.swift`) now appends the
same hint directly to a `run_shell` result whenever its output contains
`externally-managed-environment`, tied to the exact command that just
failed rather than relying on the system prompt alone.

**Verified:** `swift build` is clean (no new warnings). Wrote a standalone
script (`sanitizePath`/`fenceInfo`/`containsBareCodeFence` replicas —
deleted from scratch after, not committed, same throwaway-verification
style as last session's parser check) confirming: a `~/`-rooted path
survives sanitization with its prefix intact; a truly-absolute path loses
its leading `/` and is never mistaken for `~/`-rooted; the recovered tilde
path resolves through the real `normalizedPath`/`isModifiablePath` guard to
a genuine home-directory location; and `containsBareCodeFence` correctly
distinguishes a bare fence from a real tool call, a `file=`-attributed
fence, and no fence at all (6/6 cases).

**Not yet verified:** none of this has been exercised against a live model
in the running app — only the pure logic, in isolation. Still needed:
rebuild, relaunch, and retry the exact "build a simple python snake game"
prompt end to end (ideally on a model that previously failed this way),
watching for (a) a real file actually appearing at the path the agent
states, and (b) a pip install recovering cleanly via venv without the user
needing to intervene. Also still true: nothing from any of this work —
today's or the prior session's — has been committed yet.

## Update — 2026-07-13 (later): the `</think>` glue bug, root-caused from real transcripts

The user retried live on Nemotron 3 Ultra with the fresh build. Progress:
`~/snake-game/snake.py` (7,680 bytes) **actually landed on disk** — the
file-writing complaint is resolved. But the run then died in a new
3-identical-errors stop on the venv/pip step.

**How it was root-caused (do this again next time):** the real transcripts
are recoverable without any live repro —
`defaults export Eaon-desktop <file>.plist`, then read the
`aqua_conversations` key (JSON `Data`) with Python `plistlib` + `json`.
The exact assistant reply bytes showed the cause immediately.

**Root cause:** Nemotron glues its opening fence to the end of its
reasoning span — `…game.</think>```eaon:computer tool="run_shell"` — on
one line. The line-based parser only recognizes a fence at line start, so
the call was invisible; the closing ``` then opened a plain-fence state
that swallowed the rest. Every single parse failure in both saved
conversations (AC0F5831, 422DD29A) had this shape. The JSON inside was
valid every time — even the venv command was right.

**Fixed (all verified against the exact transcript strings — 27/27 checks,
compiled from the REAL `CodeWorkspace.swift`/`DesktopControl.swift`, not
replicas):**
- `WorkspaceParser.strippedOfThinking()` — removes completed
  `<think>`/`<thinking>` spans (replacing with a newline, so a glued fence
  lands back at line start) before the line scan in `events()`. Also stops
  fences *quoted inside* reasoning from firing as phantom calls (observed
  once in a real transcript). Unclosed spans (mid-stream) untouched.
- Prefix-less fences accepted: ```computer / ```mcp / bare tool names
  (```run_shell) — observed live as `​```computer tool="run_shell"`, which
  previously died SILENTLY (no error, loop just ended).
- **`read_file` tool added** (`DesktopTool.readFile`) — a model literally
  guessed this name in a real transcript and it didn't exist; the
  fix-and-iterate loop needs reads. Read-anywhere like list_directory, but
  confirmable (not `isReadOnly` — contents are more sensitive than names).
  Added to `codingTools`, teaching block step 5 updated.
- `create_folder` now mkdir-p-semantics: existing folder = success ("use
  it"), only a file in the way errors. (A real transcript showed the model
  stumbling over the old "Already exists" ERROR on its very first step.)
- The unparseable-tool-block error message no longer glues its hint onto
  the closing-fence line (it was modeling the exact mistake it corrects),
  and now states the fence must START its own line. Same rule added to
  `codingInstructionBlock()`.
- `<think>` spans are now stripped from ASSISTANT history turns in
  `apiContent` (all three routing paths go through it) — stops token bloat
  and stops showing the model its own glued output as precedent. Display
  and saved messages unchanged.
- Non-coding-tool refusal text now generated from `codingTools` instead of
  a hardcoded list.

**State:** builds clean; fresh debug instance relaunched. NOT yet
re-verified live — next step is the same snake-game prompt on Nemotron 3
Ultra again (expect: venv creation + pip install pygame + a run, with
read_file available). Nothing committed yet.

## Update — 2026-07-14: thinking-only stalls + edit_file

Next live failure (elon-fan-page conversation, 473C7B30): the model
created the folder, then produced THREE consecutive replies that were
**pure `<think>` spans with nothing after them** (~45 tokens each) — it
plans the action inside its reasoning ("Now I'll create the HTML file…"),
closes `</think>`, and stops. The loop treated "no tool call requested" as
"turn over" and ended silently; the user was hand-typing "continue?" after
every step. Not truncation (earlier 8k-char writes went through), not
dropped native tool calls — verified from the raw transcript.

**Fixed:**
- `executeAgentTools` now bounces a thinking-only reply back (Agent+Claw
  modes only): if the think-stripped visible text is empty while the raw
  reply wasn't (unclosed trailing `<think` also counts as thinking for the
  emptiness check), it returns an "ERROR: your reply was only internal
  thinking… ACT" tool-result with a concrete fence example, instead of nil.
  `failureSignature: "thinking-only-turn"` → three in a row still stops
  cleanly. This automates exactly what the user was doing manually.
- Both instruction blocks now state: never end a turn on thinking alone —
  after reasoning, always call a tool or answer the user.
- **`edit_file` tool added** (`DesktopTool.editFile` — path/search/replace,
  exact-match-exactly-once via the shared `WorkspaceParser.applyEdit`,
  same path guard as writes, atomic write-back). This is the Cursor-style
  targeted edit the user explicitly asked for — one-line changes no longer
  cost a full-file rewrite (matters enormously at cloud-Ollama speeds).
  Taught in `codingInstructionBlock` with a concrete example; failure text
  steers to `read_file` + retry.

**Verified:** 39/39 checks (real parser + real DesktopControlService
compiled from source; regression cases are the exact transcript strings,
including the new pure-think stall message and the working turn from the
same conversation; edit_file exercised on a real scratch directory —
apply/no-match/ambiguous/missing-file). Fresh instance relaunched.

**Still open / next:**
- Live re-verification of the whole loop on Nemotron 3 Ultra (or any
  model): expect folder → index.html write → thinking-only stalls now get
  auto-bounced instead of requiring "continue?".
- Nemotron 3 Ultra over Ollama cloud ran at ~1 tok/s in these transcripts —
  even a perfect harness feels broken at that speed for full-file writes.
  Worth suggesting the user also validate on a faster model to separate
  harness issues from serving-speed issues.
- Nothing committed yet (per the user's rule: only after live end-to-end
  confirmation).

## Update — 2026-07-14 (later): inline diff view for write_file/edit_file

User request (with a Claude Code screenshot as the reference): see the
actual lines the agent writes, with line numbers, the way Claude Code/
Cursor show a diff — not just a generic pill. Separately noted: the
existing chip already rendered every `eaon:computer` call as the literal
label "eaon:computer" (unhandled `kind` in `ToolActionChip`'s switch fell
to its `default` case) — visible in every screenshot the user has sent
this whole conversation, unrelated to any prior fix.

**Added — `FileDiffCard`** (`AssistantMessageContentView.swift`), routed
from `blockView` instead of the generic chip specifically for
`write_file`/`edit_file`:
- `write_file`: every content line shown, real line numbers 1..N, all
  green/"+" — honest framing, since this layer only has the fence body,
  not the file's prior contents, so a genuine diff against "before" isn't
  available here (would need to thread full conversation history down
  through MessageCell → HoverRevealAssistantBody → this view — not done,
  scoped out).
  - `edit_file`: real diff from the tool's own `search`/`replace` — removed
  (red/−) then added (green/+) lines, each side numbered independently
  from 1 (old-line-N → new-line-N) rather than faking an absolute file
  position this layer doesn't have.
- Bounded-height (280pt) internal ScrollView, same established pattern as
  `ToolResultsCard` — no separate expand/collapse click needed, arbitrarily
  long files just scroll.
- Two new theme colors added (`ThemeColors.diffAdded`/`diffRemoved`,
  GitHub's own light/dark diff palette — verified-contrast values, not
  raw system green/red which would clash with this app's neutrals).

**Also fixed while in there:**
- `ToolActionChip`'s generic-pill bug: `kind == "computer"` now gets a real
  icon + a label built from the fence's own JSON body (`Run: <command>`,
  `List <path>`, `New folder <path>`, `Move x → y`, etc.) for every
  computer tool that ISN'T write_file/edit_file, instead of the literal
  string "eaon:computer".
- The prefixless shorthand (```computer, ```write_file — see the
  2026-07-14 earlier update) now renders correctly in the UI too, not just
  executes correctly — `WorkspaceParser.prefixlessToolKind` was made
  non-private so the display parser recognizes the identical shorthand the
  execution parser already does. Previously a call that WORKED would still
  render as an unrecognized raw code block with language "write_file".

**Verified:** compiled a standalone replica of the line-splitting/JSON
logic (no SwiftUI dependency) against the real 8,111-char write_file body
from AC0F5831 (227 real lines, sequential numbering, correct first/last
line) plus edit_file cases. First run caught a real bug: `edit_file` with
an empty `replace` (the tool's own documented "delete this text" case)
rendered as "+1 blank line added" instead of a clean 0-added deletion —
fixed (`editSnippetLines`: empty string is zero lines, not one blank line;
`write_file`'s `content` keeps the old behavior since an empty *file* is
genuinely one blank line). 11/11 checks pass after the fix. `swift build`
clean.

**NOT verified — no pixels seen.** This is a UI change and I have no way to
drive or screenshot the native app myself (Chrome automation doesn't reach
a native macOS app; a screen capture attempted mid-task caught the user's
Zoom call, not Eaon, and was deleted immediately without inspecting
further). The already-running debug instance (PID 8494, up since 6:53 AM)
predates this change and was deliberately NOT killed/relaunched — the user
appeared to be mid-meeting and a relaunch pops a window that could
interrupt a call. **Next step: user relaunches when free and opens any
past conversation with a write_file/edit_file call (e.g. the snake-game
threads) — rendering is derived fresh from stored message text every time,
so old messages should retroactively show the new diff card with no new
prompt needed.** Confirm it actually looks right (colors, alignment,
scroll) before treating this as done. Nothing committed.

User then said "can you run this" — killed the stale instance, relaunched
(PID 88825). Running clean.

## Update — 2026-07-14 (later): scroll-follow + real diff-card syntax color

Two more requests: (1) stop auto-scrolling to the bottom while the user
has manually scrolled up mid-generation, (2) the diff card added earlier
today renders plain white/monochrome text — color it.

**(1) Scroll-follow — `ChatHomeView.swift`.** The chat `ScrollView` had no
concept of "the user scrolled away" — three `.onChange` handlers
(message content, message count, agent activity text) unconditionally
called `scrollToBottom` on every change, and the agent loop changes all
three constantly while streaming. Fixed with the standard SwiftUI
GeometryReader+PreferenceKey pattern: the bottom anchor reports its own
position (`BottomAnchorOffsetKey`) relative to the ScrollView's own
coordinate space (`.coordinateSpace(name:)` applied to the ScrollView
itself represents the fixed *viewport*, not the scrolling content — a
child's reported position moves as content scrolls underneath it), giving
a live, ungamed `isNearBottom` derived from real content position rather
than inferred from a gesture (which would miss a trackpad scroll or
keyboard page-down). All three auto-scroll triggers now check
`isNearBottom` first — EXCEPT a brand-new user-sent message, which always
force-scrolls (re-arming follow for that whole turn), and a conversation
switch (`currentConversationId` change), which always resets to the new
chat's own bottom rather than inheriting the old one's scroll state. Added
a small floating "jump to bottom" button (arrow-down pill, bottom-trailing,
matching the theme) that appears only once scrolled away — the explicit
way back without a manual drag.
**Not verified with real pixels** — this is pure SwiftUI layout/geometry
behavior with no way to headlessly test outside a running window; unlike
tonight's other fixes there's no standalone-script equivalent for this
one. Needs the user to actually scroll up during a live generation and
confirm (a) it stays put, (b) the jump-to-bottom button appears/works,
(c) switching chats still opens at the bottom.

**(2) Diff-card syntax color — `AssistantMessageContentView.swift`.**
Investigated the "zero syntax highlighting" claim from the 2026-07-08
audit memory first, per the rule to verify stale memories before trusting
them — it's actually already wired up correctly in `CodeBlockView` and
`CodeWorkspacePanel` (added sometime after that audit; memory corrected).
The gap was specifically `FileDiffCard` (built earlier today), which used
flat `Text` with a single foreground color. Fixed by reusing the existing
`SyntaxHighlighter`/`SyntaxLanguage` service: highlight the WHOLE snippet
once (language detected from the file's extension), then split the
*highlighted result* into per-line pieces for the row-by-row gutter
layout — highlighting each line independently was considered and rejected,
since a multi-line construct (a block comment, a triple-quoted string)
would lose its color on any line that doesn't carry the opening/closing
delimiter itself.

**Verified:** compiled `SyntaxHighlighter.swift`/`ThemeColors.swift` with a
standalone harness (16/16 checks) against the real 227-line snake.py body
— confirmed the highlight-then-split line count exactly matches the
already-shipped plain-line-count logic (no drift between the two), a real
keyword line shows multiple colors, a comment line shows one flat color,
and — the actual reason for the whole-then-split design — a synthetic
triple-quoted-string test proved naive per-line highlighting genuinely
DOES lose the string color on inner lines (empirically: gave the plain
foreground `#ECECEC` instead of the string color `#98C379`) while
whole-then-split gets it right. `swift build` clean. App rebuilt and
relaunched (PID 29218) with both fixes.

**Still needs live confirmation on:** scroll-follow behavior (no way to
test headlessly) and a final visual check that the diff card's colors
read well against the diffAdded/diffRemoved backgrounds. Nothing
committed yet.

## Update — 2026-07-14 (later still): live-streaming diff content

User request: watch the model write code in real time, not just see it
appear all at once when the tool call finishes.

**Root cause — confirmed, not assumed.** Read `TypewriterStreamController`
first to rule out the raw text itself being buffered: it isn't — it
reveals `message.content` continuously (every ~4-16ms while there's
backlog). The actual gap was `FileDiffCard.parsedArgs`, which required a
FULLY VALID `JSONSerialization` parse of the whole tool call's JSON body.
For the entire duration a `write_file`/`edit_file` call is mid-stream, that
JSON is by definition incomplete (an unterminated string, a missing
closing brace) — so the card showed nothing (or the "Writing…" spinner)
for the whole call, then revealed everything at once the instant the JSON
finally closed. Exactly "wait till it finishes."

**Fixed:** added a lenient fallback, `partialStringField(_:in:)` — when
strict JSON parsing fails, it finds `"key":"` directly in the raw fence
text and decodes forward character-by-character honoring real JSON string
escapes (`\"`, `\\`, `\/`, `\n`, `\t`, `\r`, `\uXXXX`), stopping at an
unescaped closing quote (field complete) or simply running out of
characters (field still arriving — returns whatever's decoded so far, no
guessing at an incomplete trailing escape). `path`/`content`/`search`/
`replace` all route through this now. Also added a blinking cursor to the
diff's last line while streaming, matching the identical `TimelineView`
pattern `CodeBlockView` and `CodeWorkspacePanel` already use for their own
in-progress content.

**Verified — this was the highest-risk piece of logic written all
session** (a hand-rolled JSON string decoder, not a shared/proven
primitive), so it got the most scrutiny: 20/20 checks, compiled from the
real function body. Synthetic cases cover every escape type plus the
truncation edge cases that actually matter (a lone trailing backslash, an
incomplete `\uXX` with 2-3 of 4 hex digits, whitespace before the opening
quote, a field that hasn't started yet vs. one that's empty). The one that
mattered most: took the real 7,680-character snake.py content, truncated
the raw JSON at 17 points from 0.1% to 100%, and confirmed at EVERY cut
point the partial decode is (a) a valid prefix of the true final content
— never garbled — (b) monotonically non-shrinking as more arrives, and
(c) at 100%, byte-for-byte identical to what strict `JSONSerialization`
produces. `swift build` clean. App relaunched (PID 50354) with all three
of today's later fixes (scroll-follow, diff-card color, live streaming).

**Not yet seen live** (same caveat as the other UI work today) — needs the
user to actually watch a write_file call stream in and confirm it grows
smoothly rather than jumping in big chunks or stuttering. Nothing
committed.

## Update — 2026-07-14 (later still): sidebar reordering on every click

User: clicking a chat in the sidebar reorders the list even though they
didn't send anything. Root cause found by direct code reading, no repro
harness needed — small, mechanical bug: `ChatViewModel.swift`'s
`selectConversation(_:)` calls `saveMessages()` unconditionally to flush
the conversation being switched AWAY from, before loading the new one.
`saveMessages()` was itself unconditional too — it always set
`conversations[index].updatedAt = Date()`, even when `messages` hadn't
changed at all. Since `sortedConversations` sorts by `updatedAt`
descending, merely navigating away from a chat (not editing it) stamped
it as "just modified" and jumped it to the top of the list.

**Fixed:** `saveMessages()` now only writes `messages`/bumps `updatedAt`/
re-derives the placeholder title when `conversations[index].messages !=
messages` (arrays of `ChatMessage`, already `Equatable`) — a real content
difference, not merely re-saving what's already stored. `persistConversations()`
still runs unconditionally at the end either way, so nothing about actual
disk-persistence timing changed, only whether a no-op re-save counts as
"just updated." This is a single shared fix point — `startNewChat()` had
the identical unconditional-`saveMessages()`-on-switch pattern and is
covered by the same change, not patched separately.

`swift build` clean. Not standalone-tested with a harness (unlike
tonight's other fixes) — this one's a one-line equality gate around
already-used code and `ChatViewModel` isn't practical to instantiate
outside the running app (deep ties to UserDefaults/singletons), so it was
verified by tracing the exact reported scenario through the code instead.
App rebuilt and relaunched (PID 61070). Nothing committed.

## Update — 2026-07-14 (later still): Chat mode had NO coding instruction at all

**Security note first:** while diagnosing this, a `defaults read | grep`
command printed the user's real GitHub/Cloudflare/Supabase tokens (and
partial Notion/Vercel OAuth blobs) in plaintext into the conversation.
Flagged to the user immediately; nothing was saved to a file or memory,
but it's visible in that transcript — they may want to rotate what they're
not comfortable with. The `defaults export` plist files this session
generated (which also contained the same tokens) have been deleted from
the scratchpad. **Lesson: never grep/cat a `defaults read`/plist dump for
"mcp\|connected" or similar again — pipe through something that redacts
values, or just check for the presence of specific keys, never print the
whole matching line.**

**The actual bug report** ("model isn't generating code at all," Tesla
mockup screenshot) turned out to be the SAME "which mode is this"
confusion as the very first bug this session — `eaon_current_mode` was
`"chat"`, not `"agent"`. But the user pushed back: they knew they were in
Chat mode, Agent mode already works, and they want Chat mode itself fixed,
not just "switch modes."

**Root cause:** Chat mode had ZERO system-prompt guidance for writing code
at all. `CodeWorkspacePanel`/`WorkspaceRunner`/`WorkspaceParser`'s full
sandboxed code-workspace feature (file explorer, editor, console, live
website preview, scripts that actually run in a scratch temp directory)
was already completely built and wired on the execution side — but
`WorkspaceParser.systemInstruction`, the ONE system prompt that teaches a
model to use it, was dead code (declared, never referenced anywhere —
confirmed by grep). So a Chat-mode "make me a website mockup" got no
guidance on how to present code at all, and — seen directly in the saved
transcript — the model filled that gap with its own assumption, reasoning
about using the connected GitHub/Vercel services instead of just writing
the code (`"I'll use the deploy_to_vercel tool"` — a tool that doesn't
exist under that name; it was extrapolating from knowing those services
were connected, which Chat mode does correctly tell it via the MCP
instruction block).

**Fixed:**
- `WorkspaceParser.systemInstruction` is now actually sent — as a Chat-mode
  system prompt in `ChatViewModel.systemPromptHistory`, placed BEFORE the
  MCP connected-services catalog so the model anchors on "I can write real
  code right here" before reading about GitHub/Vercel/etc. (same primacy
  lesson already applied to Claw's identity preamble).
- Added one line to the instruction's own WORKFLOW section: default to
  writing code directly; don't reach for a connected service unless the
  user specifically asks to push/deploy/connect somewhere.
- Verified `WorkspaceRunner.run(files:entry:workspaceKey:)` writes to
  `FileManager.default.temporaryDirectory` (system scratch space, keyed by
  conversation id) before reviving this — confirmed it can't touch the
  user's real files, since this is now live for real users, not a
  code-reading exercise.

**Scope note:** this is intentionally different from Agent mode — Chat's
code workspace is preview/scratch-run only, nothing persists to the user's
real disk from here (that's what Agent mode is for, and the user
confirmed Agent mode already works). Not conditioned on detecting "this
looks like a coding request" — sent unconditionally whenever
`currentMode == .chat`, matching how Agent's and Claw's own mode-level
instructions already work unconditionally per-mode.

`swift build` clean. App rebuilt and relaunched (PID 8409). Not yet
confirmed live — needs the user to re-ask for a mockup in Chat mode and
confirm it now writes `file="..."` fenced code (triggering the workspace
panel/live preview) instead of wandering toward a connected service.
Nothing committed.

## Update — 2026-07-14 (much later): MCP + Skills — a real feature, not a fix

User asked for "amazing" MCP integration plus a whole new Skill system
(install from GitHub/Claude Code, a library with enable/disable, `/skill`
invocation) — the biggest single ask this session. Two things were
genuinely ambiguous and got a quick clarifying question first rather than
guessed: what "get skills from Claude" could honestly mean (there's no
public API for Anthropic's actual built-in skills — landed on importing
from the user's own real `~/.claude/skills/` files instead, confirmed to
exist: 20 real skill folders on this Mac, not 9 as first scanned — grew
between an early survey and the final verification pass, presumably
another Claude Code update in between), and whether to seed starter
content (yes, 3 original skills, not copied from Anthropic's).

**MCP — custom servers (the "amazing" part).** Researched the existing
implementation first via a background agent: 15 hand-verified services,
fixed catalog, but `MCPClient`/`MCPOAuth` were ALREADY fully generic
(vendor-agnostic Streamable-HTTP JSON-RPC + generic OAuth 2.1) — the
"fixed list" was a deliberate catalog-layer choice, not a technical limit.
Added:
- `CustomMCPServer`/`CustomMCPServerStore` (`Services/CustomMCPServer.swift`)
  — name + endpoint URL + token (+ optional advanced auth-scheme override),
  UserDefaults-backed, mirroring `CustomProviderStore`'s exact pattern.
  Scoped to pasted-token auth only, not OAuth — assuming RFC 9728/8414/7591
  discovery for an arbitrary pasted URL is a much bigger, riskier bet than
  for individually-verified major vendors.
- `MCPCatalog.available` is now `builtIn + CustomMCPServerStore.shared.definitions`
  (computed, `@MainActor`) instead of a fixed literal — every existing
  consumer (Plugins page, tool dispatch, reconnect-at-launch) picks up
  custom servers automatically, zero other changes needed.
- `PluginsSettingsView` gained a "Custom servers" section reusing the
  existing `PluginRow` component as-is (it already took any
  `MCPServerDefinition`, not just catalog ones) plus an "Add Custom
  Server" sheet that saves and immediately attempts to connect in one step.

**Skills — built from scratch.** `Services/Skill.swift`:
- `Skill`/`SkillSource`/`SkillParser` — parses the exact SKILL.md
  convention (frontmatter `name:`/`description:` + markdown body), a
  narrow hand-rolled parser (not general YAML) deliberately, since every
  real skill checked uses only flat single-line scalars.
- `SkillStore` (UserDefaults-backed, same pattern as everything else):
  toggle/remove/addManual, `addFromGitHub` (tries raw/blob/tree/bare-repo
  URL shapes via `candidateRawURLs`), `localClaudeSkillCandidates` +
  `importLocal` (real scan of `~/.claude/skills/*/SKILL.md`), seeds 3
  starter skills (`Services/StarterSkills.swift`:
  steelman-then-decide, explain-at-two-levels, tighten-my-writing) on
  first launch if empty.
- `SkillsSettingsView.swift` — new Settings page (list + toggle + remove,
  add-from-GitHub sheet, import-from-Claude-Code sheet, write-one-manually
  sheet), wired into `SettingsRootView`'s sidebar.
- `ChatComposer` — typing a bare `/name` shows a live autocomplete
  popover of matching enabled skills; picking one fills `/name ` ready to
  type the actual request.
- `ChatViewModel.extractSkillInvocation` — at send time, detects a leading
  `/skill-name`, strips it, injects the skill's instructions as a
  system-prompt entry for JUST that turn (`activeSkillForTurn`, reset
  fresh every `sendMessage()` call — not a persisted mode), placed LAST in
  `systemPromptHistory` regardless of mode (Chat/Agent/Claw) since it's an
  explicit per-message user request, same recency reasoning as Claw's own
  tool detail. `ChatMessage.invokedSkillName` (new optional field, decodes
  fine on old saved messages) drives a small "⚡ Skill: name" badge above
  the sent bubble.

**A real bug caught mid-build, not by inspection:** `SkillStore
.candidateRawURLs` is pure string→URL logic but inherited `@MainActor`
isolation from the enclosing class by default — the compiler caught this
immediately when the standalone test harness tried to call it
synchronously. Fixed with `nonisolated` rather than working around it in
the test, since forcing every caller through the MainActor for a function
that touches no instance state at all would have been the wrong fix.

**Verified:** 39/40 checks (1 "failure" was a stale hardcoded count in the
test itself, not a code defect — see above). Real coverage: all 20 actual
`~/.claude/skills/` files parse correctly (name/summary/instructions all
sane); CRLF line endings, quoted frontmatter values, a colon inside a
description value, and extra unknown frontmatter fields all handled
correctly; missing name/description throw the right specific errors; all
4 GitHub URL shapes (raw, blob, tree, bare repo) produce the right
candidate list in the right order; slash-command extraction correctly
handles case-insensitivity, a bare invocation with nothing after it, an
unmatched command passing through untouched, and — the one that actually
matters for correctness — a command glued directly to extra text
(`/tighten-my-writing/extra`) correctly does NOT false-match. All 3
starter skills parse with real content. `swift build` clean throughout
(every real build was double-checked to be an ACTUAL recompile, not a
false-positive fast no-op — this happened twice this session with
brand-new files and was caught both times before trusting a "Build
complete" that turned out to be stale). App rebuilt and relaunched
(PID 52865).

**NOT yet seen live** — same limitation as all of tonight's UI work: no
way to click through the actual Settings pages, the `/` autocomplete
popover, or a real GitHub/local-skill install myself. Needs the user to:
try Settings → Skills (should show 3 starter skills already there), try
typing `/` in the composer (autocomplete should appear), try `/steelman-
then-decide should I use SQLite or Postgres` end to end, and try Settings
→ Plugins → Add Custom Server with a real MCP endpoint if one's handy.
Nothing committed — this is a large enough change that it should get a
real look before that.

**Immediate follow-up, same feature:** user tried "Import from Claude
Code" live and got a real screenshot — it correctly found and listed all
20 real local skills (some already marked "Imported" from earlier
testing, confirming the feature genuinely works), but the sheet itself
was taller than the screen, cut off at both top and bottom. Real bug: the
candidates list (`SettingsCard { VStack { ForEach(...) } }` in
`ImportLocalSkillsSheet`) had no scroll view or height cap at all, so the
sheet just grew to fit all 20 rows. Fixed by wrapping that list in its
own `ScrollView` with `.frame(maxHeight: 420)` — same bounded-list pattern
already used elsewhere this session (`ToolResultsCard`, `FileDiffCard`).
The other three sheets (GitHub install, write-manually, custom MCP
server) only ever hold a handful of fixed form fields, not an
unboundedly-long list, so they weren't at risk of the same thing — didn't
touch them. `swift build` clean, relaunched (PID 57575).

## Update — 2026-07-14 (afternoon): performance — lag, hangs, "crashes"

User: app is laggy when scrolling, "crashes sometimes," optimize
everything. Evidence gathered BEFORE fixing:

**"Crashes": no crash reports exist.** Zero Eaon `.ips` files in
`~/Library/Logs/DiagnosticReports` (macOS files one for every real
crash). Told the user honestly: the perceived crashes are (a) my own
kill-and-relaunch cycles all day — from their side the app "randomly
quit" ~8 times — and (b) main-thread hangs (beachballs), which the CPU
evidence below fully explains. Lag and "crashes" = same root cause.

**Measured evidence of the burn:** an earlier `ps` snapshot showed PID
8409 at 94.8% CPU with 126 accumulated CPU-minutes (~2h of a pinned
core). After the first round of fixes below, a fresh launch STILL pinned
~99% at idle — which made it properly profilable: `sample` (3s, 1ms
interval) showed the main thread continuously re-evaluating
`ChatComposer.body`, dominated by `ChatViewModel.chatModels` →
`providerKey(forModelId:)` → `CustomProviderStore.config(owning:)` →
`trimmedModelIDs` re-trimming every id per call — plus a persistent
`NSAnimationContext`/`NSHostingView.layout()` cycle and stray
`scrollToBottom`/`NSClipView _scrollTo` frames AT IDLE. Top suspect for
the idle-loop driver: the always-on `.animation(.easeOut, value:
isNearBottom)` over the conversation ZStack (added THIS morning with
scroll-follow; the burn's first appearance matches that build exactly).

**Render-path fixes (all in one pass):**
- `Services/RenderCache.swift` (new): @MainActor FIFO memo cache (400
  entries) for pure text→value transforms. `store: false` for
  still-streaming content whose key changes every tick.
- `FileDiffCard`: was FIVE computed properties each re-parsing the full
  JSON and/or re-highlighting the whole file PER ACCESS, ~5 accesses per
  render, per typewriter tick. Now: one `DiffModel` computed in a single
  pass (one strict JSON parse; lenient per-field fallback only when the
  whole doc is invalid), memoized via RenderCache; `body` reads it once.
  Diff rows: VStack → LazyVStack (the card caps at 280pt; building 227
  Text rows per tick when ~25 are visible was pure waste).
- `CodeBlockView` + `CodeWorkspacePanel.editorText`: highlight memoized.
- `AssistantMessageContentView`: ReasoningExtractor + MessageContentParser
  ran 2-3× per body eval — now one cached tuple. `ToolActionChip`'s
  per-call JSON parse memoized.
- `MarkdownBlockView`: line-parse memoized; `inline()`'s
  `AttributedString(markdown:)` (Foundation's full markdown parser, ~once
  per paragraph/bullet/cell per render) memoized by raw string.
- `MessageCell`: now `Equatable` + `.equatable()` at the call site. Its
  closure properties made SwiftUI's reflection-based change detection
  treat EVERY visible row as changed on EVERY tick — all visible rows
  re-rendered ~250×/s during streaming. == compares everything but the
  (semantically constant) closures. @Observable/environment invalidation
  still bypasses == correctly (theme switches, nickname changes work).
- `setAssistantMessageContent`: streaming `refreshWorkspace` throttled to
  10Hz (was per tick — full line-scan reparse of every fence-carrying
  message in the conversation, up to ~250×/s). Final exact state
  guaranteed by the existing unconditional refresh in `sendMessage`'s
  epilogue.
- `CustomProviderStore.config(owning:)`: O(1) `ownerByModelId` dictionary
  (stored/observable-safe, rebuilt on save/remove/load) instead of
  re-trimming every config's model list per call — the sample's top leaf.

**Mid-work user message — "make it that I can scroll up while the model
is responding and stay there":** the morning's scroll-follow wasn't
holding. Root cause (fits the sample): every content tick issued a 200ms
ANIMATED scrollTo; a user's upward flick mid-animation still measured
"near bottom," so the next tick re-captured them — escape was nearly
impossible during fast streams. Fixed three ways in `ChatHomeView`:
1. `NSEvent.addLocalMonitorForEvents(.scrollWheel)` while the
   conversation is on screen: any upward scroll (`scrollingDeltaY > 0`)
   disarms following INSTANTLY — gesture beats measurement, no race.
   Re-arm stays measurement-based (genuinely returning to bottom) or
   explicit (send a message / jump button). Monitor returns events
   untouched; installed/removed on appear/disappear.
2. Content-tick follows are now NON-animated (instant jump) — no more
   overlapping eased animations fighting each other 60×/s. User-initiated
   scrolls (send, jump button, conversation switch) stay animated.
3. Removed the always-on `.animation(value: isNearBottom)` over the
   ZStack (the idle-burn suspect) — replaced with diff-guarded
   `withAnimation` writes at the exact flip sites, so the jump button
   still animates in/out but no permanent animation context exists.

**Verified:** standalone harness (real `RenderCache` + `SyntaxHighlighter`
+ `ThemeColors` compiled from source, real 8,111-char transcript body):
new single-pass DiffModel is line-for-line identical to ground truth
(227 lines, exact first/last text); RenderCache hit/store:false/eviction
all behave; measured **old path 26.6ms per render vs new 0.036ms — 738×**
(and 26.6ms/render × 60fps = 1.6s of work per second: mathematically MORE
than a full core, matching the observed 94.8% exactly). One test
expectation was corrected mid-run: initially claimed the old lenient
fallback could phantom-match a key inside a written file's content;
DISPROVEN by the test itself — valid JSON always escapes inner quotes, so
the old fall-through was only wasted work, not a correctness bug. 10/10
checks pass. `swift build` clean.

**State: idle burn CONFIRMED FIXED by measurement.** At 60s uptime the
new build reads 0.0% CPU / 1.37s total CPU time, vs ~47s of CPU time at
the same point on the previous build (~99% pinned). The driver was the
always-on `.animation(value: isNearBottom)` over the conversation ZStack
(shipped this morning with scroll-follow), with the expensive per-frame
`ChatComposer.body`/`chatModels` evaluation as the amplifier — both now
gone. Scroll-feel during streaming and scroll-up-and-stay still need the
user's hands to confirm (no way to drive the GUI from here). Nothing
committed.

## Update — 2026-07-14 (late afternoon): memory overhaul

User: "memory is not working" + wants it to feel like another human
(mention their week, have the model remember), memory from plugins with
consent, manual context, and files with "heavy consent."

**Diagnosis (evidence, not guesswork):** memory was ENABLED
(`eaon_memory_enabled = 1`, autolearn defaulted on) but the
`eaon_memories` key was ABSENT — zero memories ever stored across dozens
of chats. Two compounding causes: (1) design gap — the extractor prompt
stored only "durable facts" (name/role/location) and biased against
day-to-day life, while the user's chats are mostly coding tasks, so even
perfect extraction found ~nothing; episodic memory ("knows my week")
didn't exist as a concept. (2) silent fragility — extraction reuses the
CURRENT chat model; reasoning models wrap replies in `<think>` whose
prose can contain stray `[`, sending the JSON-array hunt into garbage;
every failure path was silent; the settings page gave zero feedback, so
"working but finding nothing" was indistinguishable from "broken."

**Built:**
- `MemoryKind` (fact | event) — `MemoryItem.kind` optional for
  decode-compat (per the documented `wasColdLoad` lesson). Events are the
  episodic half: "had a chess tournament", "math final on Friday".
- Extraction prompts rewritten (shared `whatToRemember` core, used by
  per-turn AND backfill/file so they can't drift): extracts facts AND
  events a thoughtful friend would remember; keeps stated timing in the
  text; explicit exclusions (one-off assistant requests, sensitive data
  beyond what was plainly volunteered).
- `MemoryParsing` (pure, in MemoryStore.swift, standalone-compilable):
  tolerant parse of object shape / legacy string shape / mixed / buried
  in prose / wrapped in think spans (its own tiny think-strip regex);
  unknown kinds → fact. The old parse lived inside MemoryExtractor with
  the networking stack and handled strings only.
- `MemoryStore.promptBlock(now:)` — the injected briefing: facts (cap 60)
  + events from the last 30 days (cap 15, newest first, "Wed Jul 9:"
  prefixes) + guidance to weave memories in naturally (follow up on how
  things went) rather than recite. Old injection was a flat bullet list
  of everything forever. Events age OUT of prompts after 30 days but stay
  stored/reviewable. Storage cap 100 → 250 (prompt caps do the bloat
  control now).
- Reliability: `TypewriterStreamController(instant: true)` for the
  invisible extraction stream (was animating at typing pace for nobody);
  `triggerMemoryExtractionIfNeeded` now excludes `isError` messages from
  "what the assistant said" (a 3-strikes stop message used to pollute
  extraction).
- **Visible status**: every auto-learn run records
  `MemoryStore.lastAutoLearnSummary` ("Learned 2 new things · 3:41 PM" /
  "Nothing new…" / "Couldn't check (the model didn't answer)…"), shown
  under the auto-learn toggle. Kills the is-it-even-working mystery.
- **Plugin memory with consent**: `isPluginLearnEnabled` (default OFF,
  its own toggle under Memory settings, disabled unless memory+autolearn
  are on). When on, THIS turn's tool-result messages (after the last user
  message, capped 4k chars) ride into extraction as clearly-labeled
  consented context. Off = extraction never sees plugin output at all.
- **File memory with heavy consent**: Settings → Memory → "Learn from a
  file on this Mac" → NSOpenPanel (text files only, single file, never a
  folder) → confirmation alert spelling out exactly what's sent (first
  12k chars, to the currently selected model, file stays local) →
  `ChatViewModel.learnFromFile` → `MemoryExtractor.runOnFileText` →
  result reported + everything learned reviewable/deletable in the list.
- Settings list rows: events get an "Event" badge + the date mentioned;
  facts stay undated on purpose (a stale-looking date invites doubt about
  a fact that's still true).

**Verified:** 25/25 standalone checks against the REAL MemoryStore.swift
(test binary uses its own UserDefaults domain — the app's real data is
untouched): all parse shapes (canonical/legacy/mixed/prose-wrapped/
think-wrapped-with-stray-brackets/unknown-kind/blank/oversized/escaped
quotes), dedup + honest add-count, and promptBlock composition (enabled
gate, both-section layout, weekday-date prefixes, 30-day aging OUT of
prompt while staying stored, facts never aging, 15-event prompt cap with
25 stored). One vacuous test caught and fixed mid-run (the enabled-flag
gate made the first nil-check pass for the wrong reason). `swift build`
clean; app relaunched (PID 26434).

**Reality check for the user's expectation:** the "knows my week" feel
needs (a) auto-learn ON (it is), (b) actually telling it about your week
in chats, and (c) a model reliable enough to do the extraction call —
with everything now surfaced in the status line when it fails. NOT yet
verified live end-to-end (needs a real chat mentioning a life event, then
checking Settings → Memory). Nothing committed.

## Update — 2026-07-14 (afternoon): "add Bonsai 27B to the model list"

User asked to add a specific model and make it downloadable. Did NOT
assume this was fictional or already-known — verified live, since a bad
guess here has real teeth: `CuratedOllamaModels.json`'s loader
(`CuratedOllamaCatalog.loadOrFail`) `fatalError`s the ENTIRE APP on
launch if a `brand` string doesn't match a real `ProviderBrand` case, by
design ("a typo here should be impossible to miss" — not a place to
guess).

**What was actually verified (not assumed):**
- Bonsai 27B is real — PrismML released it TODAY (2026-07-14), a 27.8B
  model (based on Qwen3.6 27B) compressed via 1-bit/ternary quantization.
  Multiple press sources confirm (9to5Mac, Techmeme, PrismML's own
  announcement).
- It is NOT on Ollama — live-searched ollama.com; zero official listing,
  only unofficial third-party uploads of its smaller/older 1.7B/8B
  siblings under different namespaces. Adding it to the curated JSON
  as an Ollama pull would mean the download 404s.
- It IS on Hugging Face right now, real repo
  `prism-ml/Ternary-Bonsai-27B-gguf` — fetched its actual file tree: 6
  real GGUF quant variants (1.95GB–53.8GB) plus 2 mmproj (vision
  projector) files, confirming the model really is multimodal.
- Replicated the app's OWN exact search API call byte-for-byte
  (`LocalAIManager.searchHuggingFace`'s URL, filters, and all) via curl
  before writing any UI code — confirmed it finds exactly this one repo,
  with real live counts (23 downloads, 58 likes at verification time).

**Built:** a `featuredModelCard` in `ModelLibraryView.swift` (Settings →
Models, shown above both the Ollama and Hugging Face tabs) — reuses the
existing `NewModelBadge` for visual consistency. Tapping it switches to
the Hugging Face/GGUF tab and sets the search box to the exact verified
repo id, which runs through the app's completely unmodified, already-
working search → quant-picker → download pipeline. Deliberately carries
NO hardcoded size or download count (those would go stale/be wrong) —
only the one thing that's actually stable, the repo id. Documented in
code as a one-off callout worth deleting once it's no longer news, not a
permanent fixture like the curated lists.

**Known, out-of-scope wrinkle (not fixed, not asked for):** the one-click
default "Download" button auto-picks the SMALLEST file when none of the
standard quant-name patterns (`resolveGGUFFile`'s `q4_k_m`/`q4_k_s`/etc.
preference list) match — none do, for this repo's naming (`PQ2_0`,
`dspark-Q4_1`, etc.), so it'd land on `dspark-Q4_1` (1.95GB), not
necessarily the best-quality option. The quant-picker (already built,
unmodified) shows all 6 real options with real sizes if a user wants to
choose deliberately. Pre-existing general heuristic, not something to
special-case for one repo without being asked.

`swift build` clean (real recompile, not a stale no-op — watched the
actual "Compiling ModelLibraryView.swift" step). App relaunched (PID
17352). Not seen live (same limitation as all UI work this session) —
worth the user actually opening Settings → Models and confirming the
card looks right and the tap-through works. Nothing committed.

## Update — 2026-07-14 (later): Bonsai 27B card REVERTED — real incompatibility, not a bug in this app

User tried it live within the hour: download succeeded, llama.cpp failed
to load it ("Something went wrong… srv load_model: failed to load
model"). Root-caused properly instead of guessing:
- Downloaded file verified byte-perfect (1,946,393,568 bytes — exact
  match to Hugging Face's own reported size). Not a corrupted/partial
  download.
- Loaded the exact same file directly with the real `llama-server`
  binary via Bash, bypassing the app entirely, to get the FULL error the
  app's UI had truncated: `gguf_init_from_file_ptr: tensor
  'token_embd.weight' has invalid ggml type 42. should be in [0, 42)`.

**Real root cause:** PrismML's ternary/1-bit quantization uses a ggml
tensor type (42) that doesn't exist in any current ggml/llama.cpp
release — confirmed against a fresh Homebrew install (build b9050,
ggml 0.11.0). This lines up exactly with what the ORIGINAL research (done
before adding the card) already surfaced but under-weighted: a dedicated,
separate "bonsai" CLI exists specifically to run these models because
stock llama.cpp/Ollama can't — an open `ollama/ollama` GitHub issue for
even the small 8B sibling says the same thing. This isn't quant-choice
bad luck (the auto-picked smallest file was suspected as the weak point
in the last update) — every meaningfully-compressed variant in that repo
almost certainly hits the same wall, since ternary weights are the
model's whole premise. Only the untested 53.8GB F16 file might
architecturally load (it wouldn't need the exotic tensor type at all),
but that's impractically large and defeats the point of downloading this
model specifically.

**Fixed by reverting, not patching:** removed `featuredModelCard`
entirely rather than trying to steer the auto-pick to a "better" quant —
there ISN'T a working quant to steer to right now. Left a code comment
explaine the exact failure and citing the precise error, so a future
session doesn't have to re-discover this from scratch, and doesn't
mistake "removed" for "forgotten" — re-add once ggml/llama.cpp adds
support upstream (re-verify from scratch at that point, don't assume this
note is still accurate). This is the exact "UI promises something that
doesn't happen" bug class this app has been burned by before (the
Jan.ai-audit memory: vision attachments, ShareChatSheet's fake share
buttons) — caught and reverted same-day instead of becoming another one.

`swift build` clean, relaunched. The user's ~1.95GB broken download is
still sitting in `~/Library/Application Support/Eaon/Models/` — didn't
delete it myself (their disk, their call); mentioned it's removable via
Settings → Models → On This Mac. Nothing committed.

**Follow-up:** user asked to delete it — removed the file AND its
`aqua_local_models` registry entry (deleting only the file would've left
a ghost row with a dead "Chat" button), app quit first so it didn't race
its in-memory copy, verified registry now empty, relaunched.

## Update — 2026-07-14 (later): the OTHER HF failure — strict chat templates

User reported "many issues" downloading HF models, two screenshots: the
Bonsai one (already closed — unsupported quantization, nothing app-side)
and a NEW one that IS an app bug: Gemma-based GGUF
(`Gemma-3-1B-it-GLM-4.7-Flash-Heretic-…`) loading fine but 500ing on the
first message with `Jinja Exception: Conversation roles must alternate
user/assistant/user/assistant`. Also asked for model sizes to be shown.

**Root cause (code-confirmed):** local llama.cpp/MLX servers render the
model's own EMBEDDED chat template, and strict ones (Gemma family
classically) require exactly [one leading system] + strictly alternating
user/assistant starting with user. Eaon's history violates that three
ways: (1) `systemPromptHistory` emits up to FIVE separate system turns
(mode teaching, custom instructions, memory, MCP catalog, web search);
(2) tool results ride as extra `user`-role turns that can sit
back-to-back with the user's own message; (3) a reasoning-only assistant
turn becomes an EMPTY assistant message after history think-stripping.
Cloud providers accept all of this; llama-server executes the template
verbatim and raises before generating a token. The error surfaced with
the misleading "provider having a temporary problem — try again" hint
(it would never recover by retrying).

**Fixed — `[HistoryTurn].flattenedForStrictChatTemplates`**
(HistoryTurn.swift, pure Foundation, standalone-compilable): merges all
system turns into one leading turn (order preserved), drops
empty-no-image turns, drops app-generated assistant notices that precede
the first user turn (user-first is a hard template requirement), and
coalesces consecutive same-role turns (contents joined, images
concatenated). Applied ONLY on the local path
(`ChatViewModel.streamLocalCompletion` + `MemoryExtractor`'s local
branch) — cloud paths deliberately keep the finer-grained turns.

**Also fixed:**
- Model-load failures (the Bonsai class of error) now get a plain-words
  headline before the raw server output — what happened, that it's the
  file not the download, and what to actually do (try another quant via
  the sliders icon / another model / update llama.cpp / remove in
  Settings). Raw detail kept for diagnosability (`LocalAIError`).
- HF search rows now show the real download size ("1.9 GB · 23 downloads
  · 58 likes"), size first — it was already prefetched for the fit badge
  but never displayed as a number without hovering.

**Verified:** 12/12 standalone checks compiled from the REAL
HistoryTurn.swift, including a `satisfiesStrictTemplate` oracle that is a
direct transcription of the raise condition visible in the user's own
screenshot — the realistic 5-system+tool-result+empty-assistant history
provably violates it raw and provably satisfies it flattened; system
content preserved in order; images preserved through coalescing;
already-clean histories pass through unchanged. (Wanted to also render
the actual Gemma Jinja template as a second oracle — no jinja2 on this
Mac and NOT pip-installing on its externally-managed Python, which is the
exact error class this whole session started with.) `swift build` clean;
relaunched (PID 13237).

**Live re-test needed from the user:** re-download that Gemma GGUF (or
any Gemma-family GGUF) and send a message — should now respond instead of
500ing. The size column and the friendlier load-failure text also want a
visual once-over. Nothing committed.

## Update — 2026-07-14 (later): "deleted" models weren't deleted

User: deleting models shows as deleted but storage doesn't change.
**Disk-truth evidence first:** app's managed Models dir genuinely empty
(GGUF deletion works); but `~/.ollama/models` holds 20GB across 7 real
local models, ALL still present per `ollama list` — that's the
unchanged storage.

**Empirical elimination (throwaway `ollama cp` aliases — share blobs,
zero disk cost, real models never touched):** the server responds; the
exact request shape (`DELETE /api/delete`, `{"model": name}`) works via
curl; and — hypothesis refuted — the app's LITERAL URLSession code also
works standalone. The machinery was never broken. What's broken is
HONESTY, in three stacked ways:
1. `deleteOllamaModel` ignored the outcome entirely (`_ = try? …`) — any
   failure (server briefly down, name mismatch, refusal) looked
   identical to success.
2. `refreshOllamaModels` CLEARED the whole `ollamaModels` list on any
   transient fetch failure — right after a delete attempt, every row
   vanishing at once reads as "everything deleted" while 20GB sits
   untouched.
3. `ModelListCard`'s destructive-red "Remove model?" button ONLY HIDES
   the model from the picker (`hideModel` — never touches disk). For a
   local model, "Remove" reasonably reads as delete.
   (Bonus found while in there: MLX model deletion removed only the
   registry row — the actual weights live in `~/.cache/huggingface/hub`,
   silently left behind.)

**Fixed:**
- `deleteOllamaModel` → returns nil ONLY on verified success: checks the
  HTTP status, includes Ollama's own error body on refusal, and — even on
  a 200 — confirms via the tags list that the model is actually gone.
  Switched to `upload(for:from:)` (explicit body; both styles tested
  working today, upload can't be silently body-stripped).
- `removeUserModel` → verifies the file is really gone; for MLX, also
  removes exactly that model's own `models--org--name` HF cache
  directory (never anything else in the shared cache) and verifies.
- `deleteModel` passes results through; BOTH UI call sites
  (`ModelLibraryView.deleteRecord`, `LocalProviderSettingsView`'s alert)
  now show a "Couldn't delete the model" alert with the real reason.
- `refreshOllamaModels` keeps the last-known list on transient failure
  (flips `ollamaReachable=false` only) — the genuinely-uninstalled path
  still clears. Checked `ollamaReachable`'s 4 UI consumers; none breaks.
- `ModelListCard`: "Remove model?" → "Hide this model?", button "Hide"
  (non-destructive style), message says explicitly nothing is deleted
  from disk and points to Settings → Models for real deletion.

**Verified live** (not just built): replica of the new verified-delete
semantics against the running Ollama — real throwaway model deletes and
verifies (nil); deleting a nonexistent model surfaces Ollama's actual
`{"error": …}` instead of pretending. User's 12 real models confirmed
untouched after the tests. `swift build` clean; relaunched (PID 42990).

**For the user's actual 20GB:** their earlier "deletions" never happened
(and/or were picker-hides). They should re-delete what they don't want
via Settings → Models — it will now either really delete (verifiable in
storage) or say exactly why not. Nothing committed.

## Update — 2026-07-14 (later still): "remove Aqua API"

User sent a screenshot of "No chat model selected. Wait for models to
load from the Aqua API, then pick one from the menu." with "Can you
remove Aqua API". Genuinely ambiguous (drop the whole backend vs. fix
the wording) and Aqua/Eaon's positioning is itself an open question (see
memory), so asked before acting — user picked the narrow option: fix the
misleading text only, leave the Aqua backend/Settings page alone.

**Root cause:** `sendMessage()`'s guard fires for ANY reason
`selectedModel` doesn't resolve in `chatModels` (which already merges
Aqua+BYOK+local) — genuinely-still-loading, zero providers configured,
*or* a stale selection from a deleted/hidden model — but hardcoded an
Aqua-specific explanation regardless of which. Checked every other
"Aqua API" string in the codebase (image-gen fallback, chat-send
fallback, memory backfill, the Aqua-only `streamCompletion`'s own
fallback) — all of those only fire once the code has already confirmed
the relevant model really is Aqua-backed, so they're accurate as-is and
were left untouched.

**Fixed:** `ChatViewModel.swift` ~1175 now branches on real state —
`isLoadingModels` → "still loading"; `chatModels.isEmpty` → "no models
available yet, add a provider or download a local one"; otherwise →
generic "pick one from the model menu", no backend named. `swift build`
clean (real compile step); relaunched (PID 63390).

## Update — 2026-07-14 (same day): Bonsai again — worse than we thought, plus a truncation bug

User re-downloaded the same `prism-ml/Bonsai-27B-gguf` repo (a different
quant, Q4_1) via general HF search — not the reverted featured card, the
repo itself is still normally searchable/downloadable. Registry check
confirmed it's the only local model present. Reproduced directly with
`llama-server -m <file>` rather than trusting the pattern match.

**Real failure this time:** `unknown model architecture: 'dspark'` — not
a ggml-tensor-type problem like the earlier incident, an architecture
llama.cpp has zero code for at all. The file's own metadata
(`mask_token_id`, `confidence_head`, `log_snr_conditioning`,
`min_log_snr`/`max_log_snr`) reads as a discrete-diffusion LM, not a
transformer — every quant in this repo will fail identically. Nothing
about that architecture will ever "just work" with a different quant.

**Second bug found via the repro, not guessed:** the crash-log tail kept
for `LocalAIError` was `.suffix(400)`. The user's file path (~115 chars,
an HF `<repo>__<file>.gguf` name) appears 2-3 times in llama.cpp's last
lines; that alone ate the whole 400-char budget and pushed the ONE line
that names the real failure (`unknown model architecture: …` /
`invalid ggml type …`) out of the window entirely. The user only ever
saw the generic wrapper text — the existing classification logic was
silently never seeing what it needed to classify correctly.

**Fixed:**
- Tail widened to 1500 chars (measured: the real dspark failure needed
  511 from the architecture line to end-of-log; kept real headroom for
  longer repo names).
- `LocalAIError.errorDescription` now detects
  `unknown model architecture: 'x'` specifically, before the existing
  ggml-type/quantization branch, and gives different advice: doesn't
  suggest a different quantization (false hope — the whole repo shares
  the architecture), says pick a different model instead.

**Verified:** extracted the real `LocalBackend`/`LocalAIError` enums
into a standalone harness, fed it the ACTUAL captured 1500-char tail
from the live repro (confirmed the architecture line survives the new
window and gets detected) plus a synthetic ggml-type-42 case (confirms
the original branch still fires and still recommends another
quantization — no regression) plus a plain unrelated-failure case. 7/7
pass. `swift build` clean; relaunched (PID 79495). Test files deleted
after.

## Update — 2026-07-14 (same day): per-model CPU/GPU control for llama.cpp

Ask: let the user control how a model runs (CPU vs GPU), Hugging-Face
models only. Checked what "Hugging Face only" actually means in this
codebase: llama.cpp and MLX are the two HF-sourced backends (Ollama has
its own registry, not in scope). Checked `mlx_lm.server --help` for real
(installed it in a throwaway venv since it wasn't on this Mac) — it has
no CPU/GPU device flag at all, MLX is Metal-only on Apple Silicon by
design. So the control only makes sense, and is only wired, for
`.llamaCpp`. Checked `llama-server --help` for the real flag:
`-ngl/--gpu-layers/--n-gpu-layers N` — accepts an exact number, `auto`,
or `all` (default `auto`).

**Added:**
- `GPUOffloadMode` enum (`.auto`/`.cpuOnly`/`.maxGPU`) in `LocalAI.swift`,
  mapping to `-ngl` values `nil`/`0`/`all`. `.auto` omits the flag
  entirely so anyone who never touches this gets today's exact spawned
  command, unchanged.
- `LocalModelRecord.gpuMode: GPUOffloadMode?` — optional/decode-safe like
  every other field added after records already existed.
- `LocalAIManager.setGPUMode(_:for:)` — llama.cpp-only guard, stops the
  currently-running server for that model if it's the active one (so the
  new flag takes effect on the next send instead of silently continuing
  under the old one), persists.
- `startSpawnedServer`'s `.llamaCpp` branch now appends the `-ngl` args.
- New `GPUModeMenu` view (small `Menu`, cpu-icon button, checkmark on the
  active choice) — shared by both places a llama.cpp model row already
  exists (`ModelLibraryView.localRow`, `LocalProviderSettingsView.localModelRow`),
  gated on `record.backend == .llamaCpp` so it never shows for Ollama or
  MLX rows.

**Verified:** standalone test of the arg-construction logic (nil/.auto
→ no flag, .cpuOnly → `-ngl 0`, .maxGPU → `-ngl all`, full assembly
ordering) — 5/5 pass. Confirmed both `-ngl 0` and `-ngl all` are accepted
values on the real installed llama-server binary (parses past argument
handling into backend init, doesn't error as an unrecognized flag).
`swift build` clean (real compile across all touched files); relaunched
(PID 27519). Not seen live in the running GUI — user should open
Settings → Models (or the llama.cpp backend page) and confirm the new
CPU-icon menu appears next to a downloaded llama.cpp model and that
switching modes actually changes generation speed/behavior. Nothing
committed.

## Update — 2026-07-14 (evening): v2026.2.0 SHIPPED, then scroll-lag root cause + resizable workspace panel

**Release 2026.2.0 fully shipped** (user chose MINOR deliberately over
the documented PATCH default — asked first, they confirmed; and chose
full public release over source-only):
- Everything this session committed in two commits (`2a36a7d` features
  +fixes, `2d7ec96` version bump + CHANGELOG), pushed to eaon-desktop.
- `build-installer.sh` → universal dmg+zip; published via
  `gh release create v2026.2.0 --repo sanscreates/eaon-releases`;
  verified the zip downloads anonymously (200, byte-exact).
- **The manifest mystery solved**: downloads.eaon.dev is a direct-upload
  Cloudflare Pages project named `eaon-downloads` (NOT in any git repo,
  NOT the eaon.dev worker in ~/Projects/Eaon — that only routes
  eaon.dev/www). Deploy: write update-manifest.json into a dir, then
  `cd ~/Projects/Eaon && npx wrangler pages deploy <dir>
  --project-name=eaon-downloads --branch=main` (wrangler auth is cached
  there; the project hosts ONLY the manifest — / and /index.html 404).
  Live manifest verified announcing 2026.2.0. Existing installs get the
  update card on next launch.

**Scroll lag ("app keeps lagging when scrolling") — root-caused with a
benchmark on the user's real lagging conversation** (the aether-trails /
tic-tac-toe Claw session, extracted from UserDefaults; 45 messages, 38K
chars, streaming cell = a 6.5KB `eaon:computer write_file` JSON fence):
- **The bug: TypewriterStreamController ticked as fast as every 3ms
  (~330 updates/s) under backlog.** Every tick mutates
  `messages[i].content` → transcript ForEach re-diff, streaming cell's
  full reparse (ReasoningExtractor + MessageContentParser, `store:false`
  while streaming), FileDiffCard's full JSON parse + full-file
  re-highlight, ContextUsageBadge's 3× O(conversation) grapheme-walk
  reduce, follow-scroll `proxy.scrollTo` — all per tick. Measured on
  real data: 1.73ms per tick × 203 updates/s = **~350ms of main-thread
  work per second** (35% of a core BEFORE SwiftUI layout/render, which
  scale on top) — the main thread saturates and wheel events queue =
  the reported lag. A display can only show ~60-120 updates/s; the rest
  was invisible pure burn.
- **Fix: fixed 16ms tick (~60Hz), same chars/sec reveal expressed as
  bigger steps** (rate table re-derived from the old step/delay pairs so
  the visible typing speed is unchanged). Re-measured: 59 updates/s,
  ~100ms/s pipeline work — 3.5× fewer updates, and every downstream
  cost (diff, layout, scrollTo) scales down with it.
- Also fixed while in there, same benchmark file: `estimatedUsedTokens`
  now reduces `utf8.count` (stored O(1)/message) instead of `count`
  (O(n) grapheme walk × 3 reads/tick); WorkspaceFileCard's line count no
  longer allocates an array-of-all-lines per tick (utf8 byte scan).
- Benchmark method preserved for reruns: compile the REAL
  TypewriterStreamController/MessageContentParser/SyntaxHighlighter/
  ThemeColors sources + a copy of the old controller into a swiftc
  harness, feed the extracted real conversation. Fixtures deleted after
  (they contain user chat content).

**Workspace panel now user-resizable** (was hard `.frame(width: 440)`
in RootView): drag its leading edge — invisible 11pt grab strip in the
gutter, grip bar appears on hover, resize cursor. Width persisted in
`eaon_workspace_panel_width` (AppStorage), clamped live to
[340, window−420] so the chat column never collapses; clamping happens
at use so a big-display width degrades gracefully on a laptop.

`swift build` clean; relaunched (PID 56921). Not seen live: the resize
handle feel, and whether the lag is gone under a real fast local-model
stream — user should scroll during a long generation and drag the panel
edge. Release IS committed+pushed (that was the point); the perf/resize
work after it is NOT yet committed.

## Update — 2026-07-15: friend's feedback batch (font/naming/onboarding), Bonsai declined again

User relayed 5 items of secondhand feedback from a friend. Handled each
on its own merits rather than complying uniformly:

**Font Size setting "not working" — root-caused, not just re-tested.**
`MessageCell` reads `AppearanceSettings.shared` directly inside `body`
(for `fontSize` and the colored-user-bubble/accent-color fill), but is
also `.equatable()`-gated with an `==` that only compares its own
stored fields. Once a row renders once, `EquatableView` skips future
`body` calls whenever `message`/`isActivelyTyping`/etc. haven't
changed — so a later Font Size (or colored-bubble/accent-color) change
in Settings never reaches ALREADY-RENDERED messages; only a brand-new
message afterward would show the new size. Classic "equatable view
with a hidden external dependency" pitfall. Fixed by threading
`fontSize`/`userBubbleFill` through as explicit stored properties
computed by `ChatHomeView` (which now itself holds
`@Bindable AppearanceSettings.shared`, so it's a genuine tracked
dependency) and added to `MessageCell`'s `==` — a real settings change
now produces a real inequality instead of relying on an Environment
read the Equatable gate can't see. Checked for the same pattern
elsewhere: `.equatable()` is only ever applied to `MessageCell` in this
codebase, so nothing else has this bug.

**"Computer control should be replaced with eaon claw in settings"** —
straightforward rename, done: `SettingsRootView`'s category title,
`ComputerControlSettingsView`'s own heading, and the one cross-reference
in `ModeHomeViews.swift` ("Settings → Eaon Claw."). Left the Swift
type/file names (`ComputerControlSettingsView`, `DesktopControl.swift`)
alone — internal-only, not what was asked, pure churn.

**"Old models in local"** — investigated `CuratedOllamaModels.json`'s
Popular section for stale duplicate-generation entries (e.g. qwen3 next
to qwen3.6). Genuinely ambiguous on closer read: some apparent
duplicates (llama3.2 next to llama3.3) turned out to have distinct
blurbs staking out different niches (small/fast vs. largest/most
capable) rather than being simple staleness — not confident enough to
unilaterally edit a curated content file on a guess. Asked the user
instead of editing. NOT changed.

**Onboarding — rebuilt from scratch.** Build cache had compiled
`OnboardingView.swift` artifacts under `.build/` but the actual source
file was gone and nothing referenced it — confirms (matching what was
already found earlier investigating "remove Aqua API") that onboarding
used to exist and was fully removed, including its hard-gate-behind-an-
Aqua-key behavior, which should NOT come back. New `OnboardingView.swift`:
3-step overlay (Welcome → the three real `EaonMode` cases → "run
locally" vs "connect an API key"), shown once via
`eaon_has_seen_onboarding` (AppStorage), skippable from any step, and
every path — including doing nothing — lands in a normal empty chat.
"Run locally" opens the Models feature; "connect an API key" opens
Settings on the Aqua/provider page. Wired into `RootView` as the
topmost overlay (zIndex 30).

**"Add bonsai models" — declined, not silently ignored.** This is the
exact PrismML repo already root-caused this session (dspark = a
diffusion-style architecture llama.cpp has zero code for, confirmed by
directly running llama-server against it) and deliberately reverted.
Told the user directly rather than either quietly re-adding a model
already proven broken or quietly dropping the request without
explanation.

`swift build` clean (real compile: RootView, OnboardingView,
ChatHomeView, ComputerControlSettingsView, SettingsRootView, ModeHomeViews);
relaunched (PID 72545). Not seen live: the onboarding flow's look/feel
end to end, and whether the font-size fix actually re-renders existing
messages live (should: open a chat with existing messages, change Font
Size in Settings, confirm they resize without sending anything new).

**Follow-up same session: "old models in local" clarified** — user's
answer: "There are very old models. I want all new models instead of
old models." Went back into `CuratedOllamaModels.json` and pruned
properly instead of the narrow Popular-only dedup first considered:
- Removed 54 entries — clearly superseded generations with a newer
  generation of the SAME family already present elsewhere in this same
  catalog (llama2 family, qwen2/2.5 family, gemma/gemma2, bare
  mistral/mixtral, phi3 family, deepseek-v2/coder-v1/llm, codellama,
  granite3.1-dense/3.2), plus the entire "More Open Models" grab-bag of
  single-release finetunes with no newer version of themselves anywhere
  in the file and no other recency signal (dolphin-mixtral, vicuna,
  orca-mini, wizardlm2, openhermes, falcon, falcon2, yi, olmo2, etc.).
- Deliberately did NOT touch Vision, Small & Fast, Liquid AI, or most of
  Mistral/Cohere/Coding — no newer in-catalog replacement exists for
  those, so removing would delete a capability rather than replace old
  with new.
- Popular section rebuilt: llama3.2+llama3.3 → llama4:maverick,
  qwen3 dropped (qwen3.6 already there), gemma4 → gemma4:e2b,
  command-r → command-a — each swap COPIES an already-existing
  isNew:true entry's real data from its own category rather than
  inventing sizes/blurbs. Left glm4 alone specifically because no
  verified newer GLM entry exists in this file to copy from (the only
  evidence of one — "glm-4.7:cloud" — comes from the user's own real
  installed Ollama tags, not this catalog, and fabricating plausible-
  looking size data for it would be a real fabrication, not curation).
- Verified: JSON well-formed, no duplicate (name, category) pairs, no
  category emptied out (all 14 still have 2+ entries), then relaunched
  the actual app and confirmed it did NOT crash —
  `CuratedOllamaCatalog.loadOrFail()` re-validates every brand string
  against `ProviderBrand` at real launch time and `fatalError`s on any
  mismatch, so a clean launch is real proof the edit is schema-valid,
  not just well-formed JSON. PID 81266.

Nothing committed.

## Update — 2026-07-15 (later): Settings modal overflowing a narrow window

User's screenshot: Settings open, and BOTH edges cut off — the main
sidebar's own text clipped on the left ("Chat"/"Projects" intact but
"...ch"/"...ls" for Search/Models — inconsistent cut positions ruled out
simple text truncation), Settings' own category sidebar clipped the
same way, AND action buttons clipped on the right ("Check for Upda[te]",
"Emai[l]", "eaon.[dev]"). Both edges cut, not one — pointed at something
wider than the window overflowing symmetrically, not a truncation bug.

**Root cause, found in code, not guessed from the screenshot:**
`SettingsRootView`'s floating card was a bare `.frame(width: 980, height:
700)` — completely fixed, no responsiveness at all. `App.swift`'s
`WindowGroup` only enforces `minWidth: 800, minHeight: 600`. A window
sitting anywhere near that real, enforced minimum is narrower AND
shorter than the card's hardcoded size, so the card overflows both
edges (and top/bottom) when centered in its ZStack — content past the
window boundary is invisible, not scrolled or wrapped. Swept every
other fixed-width overlay/dialog in the app (`grep` for any
`.frame(width: N)` ≥ 500pt) to check for the same bug elsewhere —
Onboarding (560), SearchPalette (560), LocalBackendsInstallSheet (560),
one Dialogs.swift sheet (520) — all comfortably under 800−24, so
`SettingsRootView` was the sole offender, not a systemic pattern.

**Fixed:** wrapped `SettingsRootView.body` in a `GeometryReader`,
applying `.frame(width: min(980, geo.size.width - 24), height: min(700,
geo.size.height - 24))` to the card from the OUTSIDE instead of the
card's own hard-coded frame (removed). 980×700 is now a ceiling, not a
fixed value — identical appearance on any window actually big enough
for it, shrinks to fit with a 24pt margin on anything smaller instead
of silently overflowing. The card's internal 230pt category sidebar
stays fixed (plenty of room left even at the 800pt floor); its content
pane already used `.frame(maxWidth: .infinity, maxHeight: .infinity)`,
so it absorbs whatever width remains once the outer frame shrinks.

Deliberately did NOT raise the window's own minWidth/minHeight instead
— the user's ask was to make the app work AT their current size, not
tell them to make their window bigger. Also deliberately did NOT apply
the same GeometryReader-clamp defensively to the other already-safe
overlays (560/520pt, nowhere near the 800pt floor) — would be a no-op
in every real case, pure speculative churn.

`swift build` clean; relaunched (PID 297). Not seen live: actually
reproducing the narrow window and confirming the card now fits with
margin on both sides instead of clipping. Nothing committed.

## Update — 2026-07-15 (later): concurrent generation — new chats no longer cancel another one's reply

Ask: start a new chat and talk to another model while a reply is still
coming in elsewhere, without interrupting it. Investigated before
touching anything — this was NOT "unsupported," it was actively broken
two different ways, found by reading the real pipeline, not guessed:

1. **`startSend()` unconditionally cancelled the single shared
   `generationTask`** before starting a new one — literally cancelling
   whatever conversation was still generating the instant you sent a
   message anywhere else.
2. Even without that: `messages`, `isGenerating`, `activeTypingMessageId`,
   `loadingStatusText`, `agentActivityText`, `typewriter`, and all three
   `pendingXConfirmation` fields were single scalars on `ChatViewModel`,
   implicitly meaning "whichever conversation is on screen." Switching
   conversations swapped out `messages` from under a still-running
   generation — its `setAssistantMessageContent`/`finalizeGeneration`
   calls would silently no-op forever after (the message id they look
   for isn't in the new array), so the old reply would just freeze with
   no error, mid-sentence, the moment you navigated away. Confirmation
   dialogs had the same problem: a second conversation's confirmation
   request would silently orphan the first one's `CheckedContinuation`
   forever (never resumed), permanently hanging that conversation's
   agent loop.

**Fix — per-conversation generation sessions**, not a global rewrite:
- New `GenerationSession` (`@Observable`, nested in `ChatViewModel`,
  `fileprivate` — a `private` nested type broke `@Observable`'s macro
  expansion, "inaccessible due to private protection level") holds one
  generation's task, typewriter, activeTypingMessageId,
  loadingStatusText, agentActivityText, and all three pending-confirmation
  fields + their continuations. `sessions: [UUID: GenerationSession]`
  keyed by conversation id.
- `isGenerating`, `activeTypingMessageId`, `loadingStatusText`,
  `agentActivityText`, `pendingRunConfirmation`,
  `pendingMCPCallConfirmation`, `pendingDesktopCallConfirmation` are now
  COMPUTED, reading `sessions[currentConversationId]` — every existing
  UI call site (composer, message rows, RootView's confirmation dialogs)
  needed ZERO changes, since "for the visible conversation" is now baked
  into the computed property itself instead of being true by accident.
- New `withMessages(for:_:)`/`persistGeneration(for:)` — the generation
  pipeline's own message-array/save helpers, correct whether or not the
  target conversation is still visible (write to live `messages` if so,
  directly into `conversations[index].messages` if not). Threaded a
  captured `conversationId: UUID` (guaranteed real — `saveMessages()`
  already creates it synchronously before any `await`) through
  `sendMessage → streamOneAgentStep → executeAgentTools →
  streamCustomCompletion/streamLocalCompletion/streamCompletion →
  setAssistantMessageContent/finalizeGeneration/markError`, replacing
  every direct `messages`/`isGenerating`/etc. touch along the way.
- Also caught and fixed the same class of bug for `selectedModel`: it's
  the model PICKER's live selection, which the user is free to change
  the instant they switch conversations — reading it fresh at each step
  of what can be a 40-step agent loop would've silently sent a
  DIFFERENT conversation's chosen model mid-generation. Captured
  `modelId` once alongside `conversationId`, threaded the same way.
- `startSend()` no longer cancels anything by default (the old
  unconditional cancel was the actual reported bug); `stopGeneration()`
  targets only the visible conversation's own session.
- Sidebar: new small pulsing dot (`SidebarGeneratingDot`) on any
  conversation still generating in the background, via
  `isGeneratingInBackground(_:)` — confirms the other one really is
  still working instead of leaving that invisible.

**Verified two ways**, given this is real concurrency/data-integrity
work I can't click-test myself:
1. Compiler-driven completeness: converted the scalars to computed
   properties FIRST, then fixed every resulting "cannot assign to
   get-only property" error one at a time — guarantees no stale direct
   write was missed anywhere in the file (grepped afterward to confirm
   zero remain).
2. A standalone harness reproducing `withMessages`/`persistGeneration`/
   `GenerationSession` verbatim (same control flow, same names) against
   the actual reported scenario: generate in conversation A, switch to a
   brand-new chat mid-stream (exactly `startNewChat()`'s real effect),
   generate in B, then confirm — A's FULL reply survived correctly in
   its own storage (not cut off), B's data is completely independent,
   no cross-contamination either direction. Also tested switching to a
   different EXISTING conversation (not just a new one) mid-generation.
   11/11 pass. Deleted after.

`swift build` clean (real full-app rebuild, all views compiled against
the new signatures with zero call-site changes needed outside
`ChatViewModel.swift`/`SidebarView.swift`); relaunched (PID 7829). NOT
seen live: the actual GUI experience of starting a new chat while
another streams, the sidebar dot's appearance/timing, and — real,
worth flagging — whatever LOCAL backend serves both models (if the same
Ollama/llama.cpp instance is asked to serve two conversations at once)
may itself only handle one request at a time; that's the backend's own
capacity, not something fixable in this client. Nothing committed.

## Update — 2026-07-15 (later): Windows version — started a cross-platform Tauri rebuild

Ask: "make a Windows version, working and running smoothly." Led with
the honest verdict first (per user's directness preference), backed by
real numbers from surveying the codebase: this is NOT a port, it's a
ground-up rebuild. SwiftUI does not exist on Windows — 16,744 lines
across 44 View files, plus 32 of 98 files touching macOS-only APIs
(AppKit/WebKit/NSPasteboard/NSEvent/AppleScript/Homebrew/`~/Library`),
would all be rewritten. MLX (one of the 3 local backends) is
Apple-Silicon-only and literally can't run on Windows. Only the design
and the backend HTTP protocols survive.

Surfaced the strategic point: **Jan.ai (the target to beat) is Tauri**,
cross-platform by design; Eaon's native SwiftUI is exactly what locks it
to Mac. Asked the user to pick the stack (genuine fork, zero shared code,
positioning per-memory undecided). They chose **Tauri** (recommended).

**Built a real, running foundation** in `eaon-tauri/` (new dir in this
repo, gitignores exclude target/node_modules/build):
- Installed Rust via rustup (was missing; Node 22 was already present).
- Scaffolded Tauri v2 + Svelte 5 (SvelteKit static/SPA, `ssr=false`).
- Rust core (`src-tauri/src/lib.rs`): `chat_stream` (async command,
  streams over a `tauri::ipc::Channel`, POSTs OpenAI-compatible
  `/v1/chat/completions` with SSE, parses `delta.content` + reasoning)
  and `list_ollama_models` (`/api/tags`). ALL http is in Rust, not the
  webview → tighter CSP, and one path already covers local Ollama + the
  hosted API + any BYOK (base URL + key). reqwest with **rustls-tls**
  (not OpenSSL) specifically so the Windows build needs no C toolchain.
- Svelte chat UI: model picker, live streaming, "Thinking" disclosure
  for reasoning models, real in-band errors, dark Eaon-styled theme,
  window drag region. Product name/identifier set to Eaon/dev.eaon.desktop.

**Verified (real, not claimed):**
- `cargo build` — whole app compiles + links, ~400 crates, 32s.
- `npm run build` — frontend builds clean (tiny output; the Tauri win).
- `npm run tauri dev` — app BOOTS and RUNS: vite served 200 on :1420,
  `target/debug/eaon-tauri` process live, clean startup log. (Launched
  in background, verified, then killed so no stray window is left.)
- `cargo run --example stream_smoke` — the EXACT reqwest+rustls+SSE loop
  the command uses, run against live Ollama (deepseek-r1:7b), streamed
  real tokens, assembled "Streaming works." → SMOKE PASS.

**Honestly NOT verified — stated plainly to the user and in the README:**
the Windows `.exe`/`.msi` build itself. Everything verified above ran on
THIS Mac (Tauri runs on all 3 desktop OSes, so that proves the code).
The code is cross-platform BY CONSTRUCTION (rustls not OpenSSL, zero
macOS-only APIs in the Rust, Tauri auto-uses WebView2 on Windows), but
producing + smoke-testing the actual Windows binary must happen on a
Windows machine or a `windows-latest` CI runner — it cannot be
cross-compiled-and-run from macOS. That's the documented immediate next
step (README roadmap item #1: a GitHub Actions Windows build).

This is a FOUNDATION, not feature-parity with the Mac app — it does
local-Ollama streaming chat well and is architected to grow. Roadmap to
parity is in `eaon-tauri/README.md`. Rust toolchain now installed at
`~/.cargo` (rustup). Nothing committed.

## Update — 2026-07-15 (later): Windows UI made 1:1 with the Mac app

Ask: make the Windows/Tauri UI a faithful 1:1 of the Mac SwiftUI UI, not
a cheap ripoff. Approach: extracted the REAL design tokens from the Mac
source rather than eyeballing —
- `ThemeColors.swift` `.dark` palette → CSS variables verbatim in
  `eaon-tauri/src/app.css` (stage #171717, sidebar #101010, elevated/
  input #242424, inputSecondary #2E2E2E, textPrimary #ECECEC, secondary
  #B4B4B4, tertiary #8E8E9C, borders white .10/.16, userBubble #242424,
  destructive #FF6467, accent #F17455, etc.).
- Fonts: copied the actual bundled **IBM Plex Mono + Sans** .ttf files
  (all 4 weights each) from `Eaon-desktop/Resources/Fonts` into
  `eaon-tauri/static/fonts` (+ the OFL license file) and @font-face'd
  them — the same typefaces AppFonts.swift registers, not lookalikes.
- Layout tokens read straight from RootView/SidebarView/ChatHomeView/
  ChatComposer: floating sidebar card (240px, radius 16, inset padding
  10/6/9/9, border-subtle, shadow), 50px header bands, nav rows (mono 14,
  icon+label, ⌘-hints, radius-9 hover/selected), the composer pill
  (radius 26, bg-input, plus-button 34px circle bg-inputSecondary, the
  Chat/Agent/Eaon Claw mode segmented control, send button 36px circle
  filled textPrimary→dark-arrow, destructive+stop while streaming),
  message layout (user bubble right-aligned #242424 radius-12, assistant
  plain body left with model-attribution header + accent dot + "Thinking"
  disclosure), the "What can I help with?" mono-34-bold hero, composer
  centered when empty / docked at bottom with the disclaimer when active.

New files: `src/app.css`, `src/routes/+layout.svelte` (loads it),
`src/lib/Icon.svelte` (hand-drawn SVGs matching the SF Symbols used),
rewrote `src/routes/+page.svelte` into the full shell (sidebar + chat +
composer) while KEEPING the working Ollama streaming. Added in-memory
conversations (New Chat, sidebar list, title-from-first-message,
centered→docked composer) so the sidebar is real, not decorative —
persistence across launches is still a roadmap item.

**Verified visually, not just compiled:** `npm run build` clean, then
served the frontend and screenshotted it in a browser (the layout/fonts/
colors render identically; only Tauri `invoke` differs). Confirmed the
empty state AND a seeded conversation view both match the Mac app's
design language — fonts, palette, sidebar card, composer pill, message
bubbles, attribution header, Thinking disclosure all faithful. (The
browser preview shows a red `invoke` error because a plain browser has
no Tauri runtime — that's a preview artifact; the real app connects to
Ollama, proven by the earlier stream_smoke PASS.) Reverted the temporary
demo seed after; dev servers stopped.

Known follow-ups (documented, not bugs): ⌘ shortcut hints should become
Ctrl on Windows; window is still standard-decorated (frameless + custom
title-bar controls would complete the seamless look); Projects/Search/
Models/Settings/attachments/Agent/Claw are visually present but show a
"coming to the Windows version soon" notice — only Chat is wired.
Nothing committed.

## Update — 2026-07-15 (later): Windows app rebuilt FULLY — 1:1 UI with real features

Ask escalated: not just the chat surface — scrap the minimal version and
rebuild the whole Windows frontend 1:1 with the Mac app, same features.
Done solo (ultracode was toggled off mid-turn; no workflow orchestration).
Every component was ported from the actual Swift source (read
ModelPickerPopover/SearchPaletteView/ProjectsView/AquaSupportedModels
fully this turn, on top of everything read earlier in the session).

**Rust core expanded** (`src-tauri/src/lib.rs`, 8 commands): cancellable
`chat_stream` (per-request AtomicBool flags — the stop button REALLY
aborts now), `cancel_stream`, `ollama_tags` (detailed: size/params/
quant), `ollama_pull` (NDJSON progress → Channel), `ollama_delete`
(VERIFIED deletion — re-checks tags, Mac parity), `fetch_provider_models`
(OpenAI-shape /models for Aqua+BYOK), `load_app_state`/`save_app_state`
(one JSON blob in app_data_dir, atomic temp+rename writes). Frameless
window (`decorations:false`) + window-control capabilities.

**Frontend rebuilt** (src/lib): state.svelte.ts is the ChatViewModel
equivalent — per-conversation generation sessions (background chats keep
streaming, sidebar pulse dot, unread dots — the Mac concurrency model),
provider-merged catalog (Aqua allowlist port + BYOK configs + Ollama),
debounced persistence, appearance side-effects. markdown.ts + highlight.ts
are line-faithful TS ports of MarkdownLineParser/MessageContentParser/
ReasoningExtractor/SyntaxHighlighter. brand.ts + the actual BrandLogos
assets (58 files) + CuratedOllamaModels.json copied verbatim.
Components (each names the Swift view it ports): Sidebar (nav rows with
mod-key hints, Pinned, expandable Projects, date buckets, hover ellipsis
menus), ModelPicker (capsule + 340×480 popover: search/Favorites/"On this
PC"/provider groups with gear), ChatHome (topbar/empty states per mode/
docked composer + disclaimer), Messages (attribution header, Thinking
disclosure, markdown+code, hover copy/thumbs/regenerate, tok/s caption,
scroll-follow + jump-to-bottom), Composer (radius-26 pill, growing
textarea, mode switcher, send/stop), SearchPalette (mod+K, flat
keyboard-navigable list incl. model/theme switching), SettingsModal
(230px category sidebar + BETA pills + MODEL PROVIDERS/LOCAL sections;
working pages: General/Instructions/Appearance(theme/accent/font/toggles)/
Shortcuts/Privacy/Statistics/Hardware/Aqua key/BYOK editor/Ollama mgmt;
honest coming-soon pages for Memory/Plugins/Skills/ImageProviders/Claw/
LocalAPIServer), ModelsPage (curated categories from the real JSON,
custom pull row, live progress bars, installed section, verified delete),
ProjectsPage (grid + detail), Dialogs (confirm/rename/new-project/
delete-model), WindowControls (custom min/max/close, hidden when no
Tauri runtime so browser previews work). Both themes (exact
ThemeColors.light too), 14 accent colors, 3 font sizes.

**Verified**: cargo build clean; npm run build clean (one nested-button
invalid-HTML error found and fixed — menu buttons became absolutely-
positioned siblings, the ZStack-overlay equivalent); then DROVE the real
UI in a browser and screenshot-verified: empty state, Models page (real
catalog + logos + NEW badges), Settings General + Appearance, LIGHT THEME
(whole app switches correctly), search palette. Real Tauri app launched
and left running (PID 17594). NOT verified by me: clicking inside the
native window (can't drive it) — the user should send a real message;
and the Windows binary itself still needs a windows-latest CI build
(unchanged roadmap item #1).

Old minimal-UI files scrapped (src/lib/Icon.svelte, template SVGs);
README status section rewritten. Nothing committed.

## Update — 2026-07-15 (later still): real icons — Lucide instead of hand-drawn SVGs

Ask: "use the same icons" as the Mac app. Real answer up front: can't
literally reuse them — the Mac app draws every icon via SF Symbols, which
is an Apple system framework proprietary to Apple platforms (rendered by
the OS from a symbol name, not shipped as portable asset files), so it
can't be bundled into a Windows build. Said so directly rather than
quietly reusing the old hand-drawn approximation.

Fix: swapped the hand-drawn `Icon.svelte` palette for **`@lucide/svelte`**
(ISC licensed, `svelte: ^5` peer dep — matches this project exactly).
Grepped the *entire* Mac Swift source for every `systemName:` in use (58
distinct SF Symbols) and cross-referenced every name already in
`Icon.svelte`'s palette (63, since a few are Windows-chrome-only or
invented outline variants) against Lucide's real installed export list —
verified by reading `node_modules/@lucide/svelte/dist/icons/index.js`
directly rather than guessing PascalCase names, since Lucide has renamed/
deprecated a bunch (`bar-chart`→`ChartBar`, `sidebar`→`PanelLeft`,
`sliders`→`SlidersHorizontal`, `CheckCircle`→`CircleCheckBig`, etc. — the
old names still resolve as `.js`-only aliases with no matching `.svelte`
file, i.e. not real Svelte components).

Kept the exact same `<Icon name="..." size={} stroke={} />` call-site API
so none of the ~15 components using it needed to change — only the
internals swapped to a `name → component` lookup rendered as
`<Cmp size strokeWidth={stroke} fill={...} />` (Svelte 5: dynamic
components render directly, no `<svelte:component>` needed — that
triggered a deprecation warning in runes mode, fixed by dropping it).

One real gotcha caught before it shipped: the Lucide primitive destructures
a prop named `strokeWidth` (camelCase) — passing `stroke-width={stroke}`
(kebab-case, what you'd instinctively write) silently lands in `...props`
and gets spread onto the root `<svg>` *before* the component's own
explicit `stroke-width={calculatedStrokeWidth}` attribute, which wins and
silently overrides it back to Lucide's default of 2. Caught by reading the
actual `Icon.svelte` primitive source instead of assuming the prop name.

SF Symbols' two-tone `.fill` rendering (solid shape + a same-color detail
punched out in the background color, e.g. `checkmark.circle.fill`,
`exclamationmark.triangle.fill`) has no Lucide equivalent — Lucide is a
single-tone stroke set. Forcing `fill="currentColor"` on those compound
multi-path icons would make the inner detail (same `currentColor` stroke)
disappear into the now-solid shape. Fixed by only filling genuinely
single-path silhouettes (folder, star, bolt/zap, the stop square, the gear,
the brand droplet) and leaving compound icons (warning triangle, success
checkmark) as clean outlines — verified this was the right call by
screenshotting the actual "Ollama isn't running" warning banner, which
reads perfectly clear as an outlined triangle-with-exclamation-mark.

Verified: `npm run build` and `npm run check` both clean (0 errors, only
the pre-existing unrelated Switch.svelte a11y warning). Screenshotted the
live app (sidebar nav, full Settings category list, Models page + warning
banner, composer) — every sampled icon renders crisp with no console
errors. Nothing committed.

## Update — 2026-07-15 (later still): Skills ported + Windows release CI (macOS untouched)

Two threads this turn. (1) Started "make the API server and skills work" on
Windows. (2) User interrupted mid-way and pivoted to distribution CI, with an
emphatic "only Windows, do not touch the macOS version." Handled both.

**Skills — fully ported (backend + invocation).** New `src/lib/skills.ts` is a
line-faithful port of `Skill.swift`/`StarterSkills.swift`: SKILL.md frontmatter
parser, `normalizeSkillName` slugify, GitHub `candidateRawURLs` (blob/tree/bare-
repo → raw URLs), and the 3 real starter skills verbatim. `types.ts` gained
`Skill`/`SkillSource` + `invokedSkillName` on ChatMessage. `state.svelte.ts`
gained the SkillStore equivalent: `sortedSkills`/`enabledSkills`/`skillNamed`,
toggle/remove/addManual/addFromGitHub/localClaudeSkillCandidates/importLocal,
starter-seed-on-first-load, and `/name` invocation wired into `send()` (extracts
a leading /skill, injects its instructions as the last system turn before the
user msg, tags the user message). Two new Rust commands back the I/O the
webview CSP blocks: `fetch_text_url` (GitHub SKILL.md fetch) and
`scan_claude_skills` (reads ~/.claude/skills/ via `home_dir()` — cross-platform,
works at C:\Users\<you>\.claude\skills on Windows). Skills invocation works
now; the Skills *UI* (settings page, add sheets, composer autocomplete, message
badge) is NOT built yet — pending.

**Local API Server — PARKED half-built.** Had added axum/tokio deps + a state
skeleton (settings fields persist: enabled/port/requireKey/apiKey + runtime
running/error/recentRequests) but not the axum listener or UI. The interrupt
came before wiring, leaving `state.svelte.ts` calling an undefined
`applyLocalServerSettings()` → frontend wouldn't build. Parked cleanly: removed
the dangling call (left a NOTE + the harmless settings fields), reverted the
unused axum/tokio deps from Cargo.toml so the first CI build stays lean. Tree is
green again — `npm run check`/`build` 0 errors, `cargo check` clean.

**Windows release CI — the actual deliverable.** New
`.github/workflows/release.yml`: Tauri v2, **windows-latest only**, triggered by
a `v*` tag. checkout → node20+npm ci (cache-dependency-path eaon-tauri) → rust
stable + Swatinem/rust-cache (workspaces eaon-tauri/src-tauri) → version-sync
from tag (v2026.2.0 → tauri.conf.json 2026.2.0 via node one-liner) →
tauri-apps/tauri-action@v0 with `projectPath: eaon-tauri`, publishing a DRAFT
GitHub Release (contents:write permission set) with .exe(NSIS)+.msi and a
SmartScreen "More info → Run anyway" note in the body. A `workflow_dispatch`
path builds installer-only and uploads it as a run artifact (test-the-build
without releasing). YAML validated (parses, 9 steps). All 5 config icons incl.
icon.ico confirmed present so the bundle won't fail on assets.

New `eaon-tauri/RELEASING.md`: cut-a-release steps, the manual test path, the
unsigned-install/SmartScreen guidance for end users, future code-signing note,
and confirmation that ZERO cross-platform path/structural changes were needed
(app already uses app_data_dir/home_dir/PathBuf::join + rustls, no macOS-only
APIs). Framework placeholder in the user's prompt resolved to Tauri (what the
app already is).

Verified I touched nothing under Eaon-desktop/ this turn (find -mmin: 0 macOS
files). eaon-tauri/ is still entirely untracked — RELEASING.md flags that it
must be committed before a tag push, and .gitignore already excludes
node_modules//build//target/.svelte-kit (git add -n: 0 heavy-dir files).
Nothing committed. STILL OPEN: Skills UI, and finishing the parked Local API
Server (Rust axum listener + settings UI).

---

# ═══ SESSION-END HANDOFF — 2026-07-15 ═══
# (Windows / Tauri cross-platform effort. Read this block first to resume.)

## The goal we're working toward

**Ship a Windows version of Eaon that is 1:1 with the native macOS app, and
distribute it as a `.exe`.** Eaon's flagship is the native macOS SwiftUI app
(`Eaon-desktop/`, built with Xcode). SwiftUI can't run on Windows, so the
Windows app is a **ground-up Tauri v2 rebuild** (`eaon-tauri/` — Rust core +
Svelte 5 UI) that reproduces the Mac app screen-for-screen and feature-for-
feature. This is the same tech path Jan.ai (the app we're chasing) uses for
cross-platform reach. **Hard constraint from the user: do NOT touch the macOS
app — Windows only.**

Concretely, the open sub-goals are: (1) reach feature parity with the Mac app
on Windows, (2) make Skills and the Local API Server actually work on Windows,
(3) produce and test a real Windows `.exe` via CI (the user is on a Mac and
can't build/run Windows locally).

## Current state of the code

- **`eaon-tauri/` builds and runs clean.** `npm run build`, `npm run check`,
  and `cargo check` are all green (only one pre-existing, unrelated a11y
  warning on `Switch.svelte`). This session I launched `npm run tauri dev` on
  the Mac and it **compiled in 3.4s and opened the native window** — the
  Windows codebase runs. (It renders in a Mac window via WKWebView; on Windows
  it's the same code via WebView2.)
- **Icons — DONE.** Swapped the hand-drawn SVG set for **`@lucide/svelte`**
  (ISC license; a real dependency in package.json). All 63 icon names mapped
  1:1 by meaning against the Mac app's SF Symbols. Verified in the live app.
- **Skills — BACKEND DONE, UI NOT BUILT.** `/skill-name` invocation works end
  to end (parse → seed starters → resolve → inject instructions as the last
  system turn → tag the user message). What's missing is the *visible* UI:
  the Skills settings page, the 3 add-sheets (GitHub / Claude-Code import /
  manual), the composer `/` autocomplete popover, and the "Skill: name" badge
  above user messages.
- **Local API Server — PARKED, HALF-BUILT.** Settings + state fields exist and
  persist (enabled / port / requireKey / apiKey + runtime running/error/
  recentRequests), but there is **no Rust listener and no UI**. The Rust axum
  server and the settings page are both still to build. It's parked in a
  non-breaking state (see failures below).
- **Windows release CI — DONE, NOT YET RUN.** `.github/workflows/release.yml`
  (Tauri, windows-latest only, `v*`-tag-triggered, draft GitHub Release with
  `.exe`+`.msi`) and `eaon-tauri/RELEASING.md` are written and validated. It
  has never executed because `eaon-tauri/` isn't committed yet.
- **Git: nothing committed this entire session.** `eaon-tauri/` is *entirely
  untracked*. There are also pre-existing uncommitted changes under
  `Eaon-desktop/` from earlier work — **I did not touch those this session**
  and they are not mine to commit. `.gitignore` correctly excludes
  node_modules//build//target/.svelte-kit (verified: `git add -n` stages 0
  heavy-dir files).

## Files actively being edited (all Windows-side; macOS untouched)

Changed/created this session, under `eaon-tauri/` and `.github/`:
- `eaon-tauri/src/lib/components/Icon.svelte` — now renders Lucide components.
- `eaon-tauri/src/lib/skills.ts` — NEW. SKILL.md parser, GitHub URL resolver,
  3 starter skills (port of Skill.swift + StarterSkills.swift).
- `eaon-tauri/src/lib/types.ts` — added Skill/SkillSource, invokedSkillName,
  and the localServer* settings fields.
- `eaon-tauri/src/lib/state.svelte.ts` — Skills store methods + `/name`
  invocation in `send()`; localServer settings/state fields; starter-seed on
  load. (Has the parked Local-API-Server NOTE where the listener will hook in.)
- `eaon-tauri/src/lib/api.ts` — added `fetchTextUrl` + `scanClaudeSkills`
  wrappers.
- `eaon-tauri/src-tauri/src/lib.rs` — added `fetch_text_url` and
  `scan_claude_skills` commands (both registered in the handler list).
- `eaon-tauri/src-tauri/Cargo.toml` — reverted to clean (the axum/tokio deps I
  briefly added for the parked server were removed).
- `eaon-tauri/package.json` — added `@lucide/svelte` dependency.
- `.github/workflows/release.yml` — NEW. Windows release pipeline.
- `eaon-tauri/RELEASING.md` — NEW. Release + unsigned-distribution docs.
- `handoff.md` — this file.

## Everything tried that failed (and the fix / status)

- **"Run the Windows .exe on the Mac" — not possible.** A Windows binary needs
  a real Windows machine or VM (or the CI build downloaded onto one); macOS
  can't execute it and there's no emulator here. The runnable substitute is
  `npm run tauri dev`, which runs the identical Windows codebase as a Mac
  window. (This is exactly why the CI matters — it's the only way to produce a
  testable `.exe` from a Mac.)
- **Can't literally reuse the Mac app's icons.** SF Symbols are an Apple system
  framework, proprietary to Apple platforms and not redistributable into a
  Windows build. → Used Lucide (closest permissive stroke set) mapped 1:1.
- **Lucide gotchas that bit / would have bitten:** (a) deprecated icon names
  (`bar-chart`, `sidebar`, `sliders`, `CheckCircle`…) are `.js`-only aliases
  with **no `.svelte` component** — had to verify real exports against the
  installed package, not guess. (b) the prop is camelCase `strokeWidth`;
  passing kebab `stroke-width` is silently overridden back to Lucide's default
  of 2. (c) SF Symbols' two-tone `.fill` has no Lucide equivalent, so compound
  icons (warning triangle, success check) are kept as outlines, not force-
  filled (a fill would swallow the inner detail).
- **`<svelte:component>` is deprecated in Svelte 5 runes mode** → render the
  dynamic component directly as `<Cmp .../>`.
- **Parking the Local API Server broke the build.** The half-written state
  called an undefined `applyLocalServerSettings()`, so `npm run build` failed
  (which would fail CI too). → Removed the dangling call (left a NOTE + the
  harmless persisted settings fields) and reverted the unused axum/tokio deps
  so the first CI build stays lean. Tree green again.
- **(Earlier this session, for context)** nested `<button>` invalid-HTML in
  Sidebar.svelte, and a module-init `getCurrentWindow()` crash blanking the
  browser preview — both already fixed earlier.

## How to resume (next steps, in priority order)

1. **Commit `eaon-tauri/` + `.github/workflows/release.yml`**, then push a
   `v<version>` tag (e.g. `v2026.2.0`) to trigger the Windows CI and get a real
   `.exe`. This is the fastest way to actually test the Windows build. (Only
   commit when the user asks — they've kept everything uncommitted on purpose.)
2. **Finish the Local API Server** (Rust axum loopback listener + the settings
   page). Mirror `LocalAPIServer.swift`/`LocalAPIServerStore.swift`/
   `LocalAPIServerSettingsView.swift`. The frontend state/settings are already
   in place waiting for it.
3. **Build the Skills UI** (settings page, 3 add-sheets, composer `/`
   autocomplete, message badge). Backend is done; this is pure UI.
4. Later: code-sign the Windows build to drop the SmartScreen warning
   (see RELEASING.md).
