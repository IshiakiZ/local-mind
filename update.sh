#!/bin/bash
# Rebuild Local Mind from its own checkout and relaunch it.
# Invoked by the app's Update button; safe to run by hand too.
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
SRC="${1:-$(cd "$(dirname "$0")" && pwd)}"
LOG="${TMPDIR:-/tmp}/localmind-update.log"
exec > "$LOG" 2>&1

echo "== updating from $SRC"
cd "$SRC"

git fetch --quiet origin
git reset --hard --quiet origin/main
echo "== now at $(git rev-parse --short HEAD)"

./build.sh

# The running copy has to go before it can be replaced.
osascript -e 'tell application "Local Mind" to quit' 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -x LocalMind >/dev/null || break; sleep 0.5; done
pkill -x LocalMind 2>/dev/null || true
sleep 1

DEST="/Applications/LocalMind.app"
[ -d "$DEST" ] || DEST="$HOME/Applications/LocalMind.app"
rm -rf "$DEST"
cp -R LocalMind.app "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
echo "== installed to $DEST"

open "$DEST"
echo "== done"
