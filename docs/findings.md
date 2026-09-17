# Findings: yazi 26 facts that cost a debug cycle each

Gathered while building the prototype against yazi 26.9.1 on Arch. Read all of it before
writing code. Items 1 to 5 are silent failures, meaning the code runs, reports success,
and does nothing. You will not find those by iterating.

## 1. A plugin touching `cx.*` must declare `--- @sync entry`

`cx.active.current.cwd`, `cx.active.selected`, `cx.yanked` and friends are only available
to sync plugins. Without the annotation on the first line, the entry function runs and
silently does nothing. No error, no notification, nothing in any log.

```lua
--- @sync entry
local M = {}
function M:entry(job)
  local cwd = cx.active.current.cwd   -- nil without the annotation above
end
```

This one cost a full round of "the binding does not fire" debugging when the binding was
fine.

## 2. `ya pub trash-restore` needs `%S`, not `%s`

`%s` expands to plain filesystem paths. `%S` expands to URLs. The trash restore handler
resolves its argument with `Url(arg)` and needs the `trash://` scheme to find the entry.

```toml
# works
run = 'shell -- ya pub trash-restore --list %S'
# runs, exits zero, restores nothing
run = 'shell -- ya pub trash-restore --list %s'
```

The `%s` form produces no error at all.

## 3. Never call `require("trash"):setup()` in `init.lua`

yazi exits immediately with `Error: Lua runtime failed`. Preset plugins are initialised
internally and calling their setup by hand breaks startup. The `trash-restore` and
`trash-empty` subscriptions already exist without you doing anything.

## 4. A user plugin cannot override a same named preset plugin

Dropping `~/.config/yazi/plugins/file.yazi/main.lua` to extend the built in `file` plugin
does nothing. The preset wins and the user copy is ignored.

This matters because every built in spotter merges `require("file"):spot_base(job)` into
its own table, which looks like an elegant extension point and is not reachable that way.
Register under a different name and dispatch to the built in explicitly:

```lua
local ok, mod = pcall(require, "image")      -- the preset, not yours
local rows = ok and mod:spot_base(job) or {}
```

## 5. Cut and paste across `trash://` silently produces a zero byte file

Tested directly: a 7 byte file in the trash, `x` to cut, navigate out, `p` to paste. The
result is a file of the right name and **0 bytes** at the destination, and the original is
still sitting in the trash.

Never restore anything by yanking it out of the trash. Use `ya pub trash-restore` or the
freedesktop records directly.

## 6. An orphaned `.trashinfo` hangs the trash listing forever

If `Trash/info/x.trashinfo` exists but `Trash/files/x` does not, yazi's `trash://` listing
never completes. It sits on `Loading...` with no error and no timeout.

Reproduced deliberately: 5 real files plus 298 orphaned records hangs. Remove the orphans
from that same trash and it lists instantly. A clean trash with stray extra directories,
such as `expunged` and a leftover `ucollage`, loads fine, so it is the orphan records
specifically.

Real trashes accumulate these when something deletes from `Trash/files` without clearing
`Trash/info`. Worth detecting and offering to clean, since the symptom is
indistinguishable from the plugin being broken.

## 7. `Path=` in a `.trashinfo` is percent encoded

Per the freedesktop spec. Decode before using it as a destination.

```
Path=/home/u/mon%20fichier%20%C3%A9.txt   ->   /home/u/mon fichier é.txt
```

`reference/trash-undo.sh` has a working decoder. In bash:
`printf '%b' "${value//%/\\x}"`.

## 8. DDS payload shapes

Confirmed against the DDS documentation for 26.x. These are what the recorder subscribes
to.

| kind | payload |
| --- | --- |
| `trash` | `{ urls = { Url, ... } }` |
| `delete` | `{ urls = { Url, ... } }` (permanent, nothing to invert) |
| `move` | `{ items = { { from = Url, to = Url }, ... } }` |
| `rename` | `{ tab = 0, from = Url, to = Url }` |
| `bulk` | `{ changes = { ["/from"] = "/to", ... } }` |
| `yank` | `{ cut = false, urls = { ... } }` (clipboard state, not an applied operation) |

There is **no copy event**. A paste that copies creates files and broadcasts nothing,
which is why copy has to be handled by wrapping the paste command.

`move` covers both cut and paste and plain moves, so one handler serves both.

## 9. Command and placeholder syntax changed in 26

Relevant if you ship a keymap example. yazi 26 renamed arguments that 25.x spelled
numerically, and silently ignores the old spellings.

| 25.x | 26.x |
| --- | --- |
| `arrow -1` / `arrow 1` | `arrow prev` / `arrow next` |
| `arrow -99999999` / `99999999` | `arrow top` / `arrow bot` |
| `swipe -1` / `swipe 1` | `swipe prev` / `swipe next` |
| `move -999` / `move 999` | `move bol` / `move eol` |
| `copy dirname` | `copy dirpath` |
| `sort x --reverse` | `sort x --reverse=yes` |
| `forward --far` | `forward wide` |
| `tasks_show` | `tasks:show` |
| `[completion]` section | `[cmp]` section |
| `name = "*/"` in rules | `url = "*/"` |

Openers and `shell` use `%s`, `%s1`, `%d1` and `%S` placeholders. The old shell style
`"$1"` and `"$@"` no longer expand.

Also: `"$schema" = "..."` as a TOML key is rejected outright in 26. The schema hint is now
a comment, `#:schema https://...`.

## 10. Glob rules need `*/` for directories

`url = "*"` does not match directories. A fallback rule that should cover everything needs
both:

```toml
{ url = "*/", run = "my-plugin" },
{ url = "*",  run = "my-plugin" },
```

Order matters, first match wins, so a catch all belongs last.
