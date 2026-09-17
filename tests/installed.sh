#!/usr/bin/env bash
# Drive a delete and a copy round trip against an INSTALLED copy of the plugin,
# not against this checkout.
#
# `ya pkg` deploys a plugin package as LICENSE, README.md, main.lua, any other
# kebab cased *.lua, and assets/. Nothing else travels, so anything the plugin
# reaches for outside that set works here and is missing for everybody who
# installed it. This script deploys exactly that list, which is why it catches
# that class of bug and a run from the repo does not.
#
# Usage: tests/installed.sh        (needs yazi, tmux and a pty)

set -u
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
FIX=$(mktemp -d)
S=undo-installed-$RANDOM-$$
FAILED=0

cleanup() { tmux -L "$S" kill-server 2>/dev/null; rm -rf "$FIX"; }
trap cleanup EXIT

ok()   { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }

# --- deploy exactly what `ya pkg` deploys ------------------------------------
PLUG="$FIX/config/plugins/undo.yazi"
mkdir -p "$PLUG" "$FIX/data/Trash/files" "$FIX/data/Trash/info" "$FIX/state/yazi" "$FIX/work"
for f in LICENSE README.md main.lua; do
	cp "$REPO/$f" "$PLUG/$f" || { echo "missing $f in the repo"; exit 1; }
done
for f in "$REPO"/*.lua; do
	[ "$(basename "$f")" = "main.lua" ] || cp "$f" "$PLUG/"
done
[ -d "$REPO/assets" ] && cp -r "$REPO/assets" "$PLUG/assets"

echo "deployed: $(cd "$PLUG" && ls -A | tr '\n' ' ')"
if [ -e "$PLUG/trash.sh" ] || [ -e "$PLUG/tests" ]; then
	fail "the deployment copied more than ya pkg would"
fi

# --- a yazi that can only see that copy --------------------------------------
cat > "$FIX/config/init.lua" <<'LUA'
require("undo"):setup {}
LUA
cat > "$FIX/config/keymap.toml" <<'TOML'
[[mgr.prepend_keymap]]
on  = "u"
run = "plugin undo"
TOML

printf 'precious\n' > "$FIX/work/a.txt"
tmux -L "$S" new-session -d -x 130 -y 30 \
	"XDG_DATA_HOME=$FIX/data XDG_STATE_HOME=$FIX/state YAZI_CONFIG_HOME=$FIX/config yazi $FIX/work"
sleep 4

keys() { tmux -L "$S" send-keys "$@"; }
toast() {
	local out
	for d in 0.3 0.6 1.0 1.5 2.0 2.5; do
		sleep "$d"
		out=$(tmux -L "$S" capture-pane -p | grep -aoE "(undo|cancel) \[action: [a-z-]+\]")
		[ -n "$out" ] && { echo "$out"; return; }
	done
	echo "(no toast)"
}

# --- delete and undo, which restores out of the trash ------------------------
keys d; sleep 1; keys Enter; sleep 3
[ -e "$FIX/work/a.txt" ] && fail "delete did not happen, the fixture is wrong"
[ "$(ls -1 "$FIX/data/Trash/files" | wc -l)" = 1 ] || fail "nothing reached the trash"

keys u
t=$(toast)
sleep 2
if [ "$(cat "$FIX/work/a.txt" 2>/dev/null)" = "precious" ]; then
	ok "delete undone by the installed copy, toast: $t"
else
	fail "delete not undone, toast: $t"
fi

# --- copy and undo, which writes a trash record ------------------------------
keys y; sleep 1.2; keys p; sleep 4
[ -e "$FIX/work/a_1.txt" ] || fail "the copy was not created, the fixture is wrong"

keys u; sleep 2
keys y
t=$(toast)
sleep 2
if [ ! -e "$FIX/work/a_1.txt" ] && [ -e "$FIX/work/a.txt" ] &&
	[ "$(ls -1 "$FIX/data/Trash/files" | wc -l)" = 1 ]; then
	ok "copy undone into the trash, original kept, toast: $t"
else
	fail "copy undo left the wrong state, toast: $t"
fi

[ "$FAILED" = 0 ] && echo "installed copy works" || echo "installed copy is broken"
exit "$FAILED"
