#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "Building Eaon…"
swift build -q

APP=".build/debug/Eaon-desktop"

if [[ ! -x "$APP" ]]; then
  echo "Build failed: $APP not found"
  exit 1
fi

echo "Launching Eaon (detached from terminal so keyboard focus works)…"

# Launch as a separate GUI process so Terminal does not capture keystrokes.
nohup "$APP" >/dev/null 2>&1 &
disown

echo "Eaon is running. Click the app window once, then type in the chat box."
echo "Tip: keep this terminal open only if you want to see build logs."
