#!/usr/bin/env bash
# Drive real round trips against an INSTALLED copy of the plugin, not against
# this checkout, on two different filesystems.
#
# Two things only this script can catch:
#
#   `ya pkg` deploys a plugin as LICENSE, README.md, main.lua, any other kebab
#   cased *.lua and assets/. Nothing else travels, so anything the plugin
#   reaches for outside that set works from the repo and is missing for every
#   real user, findings item 14.
#
#   A file deleted from another filesystem is trashed to that filesystem's own
#   trash, not to the home one, findings item 16. A fixture that keeps the work
#   directory and the trash on one filesystem never sees this.
#
# Usage: tests/installed.sh        (needs yazi, tmux and a pty)

set -u
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
FIX=$(mktemp -d)                 # on whatever TMPDIR is, holds the home trash
XWORK=/dev/shm/undo-installed-$$ # another filesystem, when there is one
S=undo-installed-$RANDOM-$$
FAILED=0

cleanup() {
	tmux -L "$S" kill-server 2>/dev/null
	rm -rf "$FIX" "$XWORK"
	# only what this script put in the shared volume trash
	rm -f /dev/shm/.Trash-"$(id -u)"/files/xfs.txt /dev/shm/.Trash-"$(id -u)"/info/xfs.txt.trashinfo
	rmdir /dev/shm/.Trash-"$(id -u)"/files /dev/shm/.Trash-"$(id -u)"/info \
		/dev/shm/.Trash-"$(id -u)" 2>/dev/null
}
trap cleanup EXIT

ok()   { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }
skip() { echo "  skip  $1"; }

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

cat > "$FIX/config/init.lua" <<'LUA'
require("undo"):setup {}
LUA
cat > "$FIX/config/keymap.toml" <<'TOML'
[[mgr.prepend_keymap]]
on  = "u"
run = "plugin undo"

[[mgr.prepend_keymap]]
on  = "<C-r>"
run = "plugin undo -- redo"
TOML

start() { # $1 = directory to open, on a yazi that can only see the deployed copy
	tmux -L "$S" kill-server 2>/dev/null
	sleep 0.5
	tmux -L "$S" new-session -d -x 130 -y 30 \
		"XDG_DATA_HOME=$FIX/data XDG_STATE_HOME=$FIX/state YAZI_CONFIG_HOME=$FIX/config yazi $1"
	sleep 4
}
keys() { tmux -L "$S" send-keys "$@"; }
toast() { # $1 = which verb to wait for, default any
	local out want=${1:-"(undo|redo|cancel)"}
	for d in 0.3 0.6 1.0 1.5 2.0 2.5; do
		sleep "$d"
		out=$(tmux -L "$S" capture-pane -p | grep -aoE "$want \[action: [a-z-]+\]" | tail -1)
		[ -n "$out" ] && { echo "$out"; return; }
	done
	echo "(no toast)"
}

# --- delete and undo, which restores out of the trash ------------------------
printf 'precious\n' > "$FIX/work/a.txt"
start "$FIX/work"

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

# --- redo, which puts it back in the trash, then undo again ------------------
keys C-r
t=$(toast redo)
sleep 2
[ -e "$FIX/work/a.txt" ] && fail "redo did not put the file back in the trash, toast: $t"
keys u; sleep 3
if [ "$(cat "$FIX/work/a.txt" 2>/dev/null)" = "precious" ]; then
	ok "redo and undo again, toast: $t"
else
	fail "undo after redo left nothing behind, toast: $t"
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

# --- the same delete, from a filesystem that is not the home one -------------
same_fs() { [ "$(stat -c %d "$1")" = "$(stat -c %d "$2")" ]; }
if ! mkdir -p "$XWORK" 2>/dev/null; then
	skip "no /dev/shm, cross filesystem delete not covered"
elif same_fs "$XWORK" "$FIX/data"; then
	skip "/dev/shm is the same filesystem as the fixture, nothing to prove"
else
	printf 'elsewhere\n' > "$XWORK/xfs.txt"
	start "$XWORK"
	keys d; sleep 1; keys Enter; sleep 3
	[ -e "$XWORK/xfs.txt" ] && fail "delete did not happen on the other filesystem"

	keys u
	t=$(toast)
	sleep 2
	if [ "$(cat "$XWORK/xfs.txt" 2>/dev/null)" = "elsewhere" ]; then
		ok "delete undone from the volume trash, toast: $t"
	else
		fail "delete on another filesystem not undone, toast: $t"
	fi
fi

[ "$FAILED" = 0 ] && echo "installed copy works" || echo "installed copy is broken"
exit "$FAILED"
