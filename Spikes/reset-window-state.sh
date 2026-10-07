#!/bin/zsh
# Resets MaxAct's saved window geometry and table column layout, so the next launch shows the
# coded defaults. Keeps the Health Auto Export credentials.
#
# Use this after changing a default window size or column width — otherwise the saved state wins
# and the change appears to do nothing. Quit the app first.
#
# Three things make this fiddlier than `defaults delete`, all learned the hard way:
#
#   1. The app is sandboxed, so its real preferences are inside the container. The plain
#      `defaults` command reads ~/Library/Preferences/, which for this app doesn't even exist.
#   2. `cfprefsd` caches the domain and flushes it on exit, so it has to be killed BEFORE the
#      plist is edited. Killing it afterwards writes the stale values straight back.
#   3. Window geometry and the open-window list also live in a restoration directory —
#      on macOS 26 in the container's tmp/, not Library/Saved Application State/.
#
# See .claude/skills/maxact-development/references/xcode-project-conventions.md.

set -u

CONTAINER=~/Library/Containers/com.swiatlowski.MaxAct/Data/Library
PLIST="$CONTAINER/Preferences/com.swiatlowski.MaxAct.plist"

if pgrep -f "MaxAct2.app/Contents/MacOS/MaxAct2" > /dev/null; then
    echo "MaxAct is running — quit it first, or its state will be written back on exit." >&2
    exit 1
fi

# 1. Flush the cache first.
killall cfprefsd 2>/dev/null
sleep 2

# 2. Strip everything except the credentials.
python3 - "$PLIST" <<'PY'
import plistlib, pathlib, sys
KEEP = {'syncHost', 'syncToken'}          # the HAE address and bearer token
path = pathlib.Path(sys.argv[1])
if not path.exists():
    print(f'no preferences at {path}'); raise SystemExit
data = plistlib.loads(path.read_bytes())
removed = [k for k in data if k not in KEEP]
for key in removed:
    del data[key]
path.write_bytes(plistlib.dumps(data))
for key in removed:
    print(f'  removed {key[:78]}')
print(f'  kept    {sorted(data)}')
PY

# 3. And the restoration state, which is a directory rather than a key — and which has moved.
#    On macOS 26 it lives in the container's tmp/, not Library/Saved Application State/; the old
#    locations are cleared too in case an older system wrote there. Leaving it behind is how the
#    app came to relaunch with no window at all (see launchMaxAct in the UI tests).
rm -rf "$CONTAINER/../tmp/com.swiatlowski.MaxAct.savedState" 2>/dev/null
rm -rf "$CONTAINER/Saved Application State" 2>/dev/null
rm -rf ~/Library/Saved\ Application\ State/com.swiatlowski.MaxAct.savedState 2>/dev/null

echo "Done — the next launch will use the coded defaults."
