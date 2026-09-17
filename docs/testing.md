# Testing a yazi plugin without a terminal

yazi is a full screen TUI, so it needs a pty. `yazi --help` and friends exit before the
config is ever parsed, which means they prove nothing. Drive a real instance through tmux
and read the screen back.

## Three rules

**Always use `tmux -L <unique-socket>`.** A plain `tmux kill-server` destroys the user's
own running session. That happened while building the prototype. Every command below
carries `-L`.

**Always isolate `XDG_DATA_HOME`.** The trash lives under it, so pointing it at a fixture
directory means a bug cannot reach the real trash. This plugin moves and deletes files,
so this is not optional.

**Isolate `YAZI_CONFIG_HOME` too when testing config**, and leave it alone when you want
to test against the user's real setup.

## The harness

```sh
#!/usr/bin/env bash
# build a fixture: an isolated trash plus a working directory
FIX=$(mktemp -d)
mkdir -p "$FIX/Trash/files" "$FIX/Trash/info" "$FIX/work"
echo "REAL WORK" > "$FIX/work/important.txt"

S=test-$RANDOM                      # unique socket, never the default
tmux -L "$S" new-session -d -x 130 -y 30 \
  "XDG_DATA_HOME=$FIX yazi $FIX/work"
sleep 4                             # yazi needs a moment to draw

tmux -L "$S" send-keys d ; sleep 2  # delete
tmux -L "$S" send-keys Enter ; sleep 3   # confirm the prompt
echo "after d: work=$(ls "$FIX/work" | wc -l) trash=$(ls "$FIX/Trash/files" | wc -l)"

tmux -L "$S" send-keys u ; sleep 4  # undo
echo "after u: work=$(ls "$FIX/work" | wc -l) trash=$(ls "$FIX/Trash/files" | wc -l)"

tmux -L "$S" capture-pane -p | grep -aiE "undo|cancel|error"
tmux -L "$S" kill-server
rm -rf "$FIX"
```

A passing delete and undo round trip prints `after d: work=0 trash=1` then
`after u: work=1 trash=0`.

## Reading the screen

`capture-pane -p` returns the rendered text. Pipe through `strings` when you only want
readable content, and `cut -c` to slice a column range when a panel is what you care
about:

```sh
tmux -L "$S" capture-pane -p | sed -n '/Spot/,/╰/p' | cut -c20-105
```

## Catching a notification

Toasts expire. A 4 second timeout is gone by the time a `sleep 5` finishes, so poll
instead of guessing:

```sh
tmux -L "$S" send-keys u
for d in 0.3 0.8 1.3 2.0; do
  sleep "$d"
  out=$(tmux -L "$S" capture-pane -p | grep -aiE "undo \[action|cancel \[action")
  [ -n "$out" ] && { echo "$out"; break; }
done
```

## Checking that the config parses at all

For a pure "does it load" check, `script` is lighter than tmux because it only needs to
allocate a pty:

```sh
COLUMNS=120 LINES=40 timeout 6 script -qec "yazi /tmp" /dev/null 2>&1 \
  | strings | grep -aiE "parse error|caused|unknown|failed"
```

Silence means it loaded. This is how the keymap and config were validated.

## Test the installed copy, not the checkout

`tests/installed.sh` copies out the files `ya pkg` actually deploys, which is `LICENSE`,
`README.md`, `main.lua`, any other kebab cased `*.lua` and `assets/`, and then drives yazi
against that copy. Anything the plugin reaches for outside that list works from the repo
and is missing for every real user, see findings item 14.

```sh
tests/installed.sh    # exits non zero and says which round trip broke
```

Run it before tagging a release, and after any change that adds a file. A plugin that
passes every fixture test from the checkout can still be broken on install.

## Driving a bulk rename

Bulk rename is the slowest thing to drive and the easiest to mistime. Select two or more
files, press `r`, and yazi writes the names into a temp file and hands it to `$EDITOR`
with the terminal blocked. Three things to know:

- `$EDITOR` has to be passed into the tmux command line. A plain `export` before
  `new-session` is not enough to rely on.
- The editor takes about six seconds to be spawned and reaped here. Poll for the file the
  fake editor writes rather than sleeping a fixed amount.
- Afterwards yazi asks `Continue to rename? (y/N):`, and that prompt is an input, so it
  needs `y` and then `Enter`. A lone `y` leaves the prompt open and every later keystroke,
  including the `u` under test, is swallowed by it.

```sh
cat > "$FIX/ed.sh" <<'ED'
#!/usr/bin/env bash
sed -i 's/^/z_/' "$1"
touch /tmp/editor-ran
ED
chmod +x "$FIX/ed.sh"

tmux -L "$S" send-keys Space ; sleep 1 ; tmux -L "$S" send-keys Space ; sleep 1
tmux -L "$S" send-keys r
for i in $(seq 1 15); do sleep 1; [ -e /tmp/editor-ran ] && break; done
for i in $(seq 1 12); do
  sleep 0.5
  tmux -L "$S" capture-pane -p | grep -qa "Continue to rename" && break
done
tmux -L "$S" send-keys y ; sleep 0.5 ; tmux -L "$S" send-keys Enter
```

The same rule applies to any dialog. If a keystroke seems to do nothing, capture the pane
before concluding the code is broken, because an open prompt eats keys silently.

## Isolate the state directory too

`XDG_DATA_HOME` covers the trash, and `XDG_STATE_HOME` covers the journal and the
purgatory. A test that isolates only the first one writes its records into the real
`~/.local/state/yazi`, which is how a test run ends up undoing something from yesterday.

## What this harness cannot test

`tmux send-keys C-i` sends byte `0x09`, which is the Tab character. So `<C-i>` and `<Tab>`
are indistinguishable here no matter what you do. Whether a real terminal can tell them
apart depends on its keyboard protocol at runtime, Kitty protocol capable terminals can,
older ones cannot. Any binding that relies on that distinction has to be verified by hand
in the actual terminal.

The same caution applies to other control characters that collide with ASCII names, such
as `<C-m>` and `<Enter>`, or `<C-[>` and `<Esc>`.
