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
| `duplicate` | `{ items = { { from = Url, to = Url }, ... } }` (a copying paste) |
| `rename` | `{ tab = 0, from = Url, to = Url }` |
| `bulk-rename` | a table of `from` to `to`, read with `pairs(body)` |
| `yank` | `{ cut = false, urls = { ... } }` (clipboard state, not an applied operation) |

`move` covers cut and paste and plain moves, so one handler serves both. Items 11 and 12
below are corrections to this table that were found by watching a real instance rather
than by reading, and each one was a silent failure until then.

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

## 11. The bulk rename event is called `bulk-rename`, not `bulk`

Subscribing to `bulk` is accepted without complaint and never fires. The publisher is
`Pubsub::pub_after_bulk_rename`, and the kind it publishes is the hyphenated one.

```lua
ps.sub("bulk", function(body) end)          -- never called
ps.sub("bulk-rename", function(body) end)   -- called, once per bulk rename
```

The body is a plain map of old path to new path, so `for from, to in pairs(body)` is all
it takes. The `{ changes = ... }` wrapper in the old version of item 8 does not exist.

A subscription to a kind nothing publishes is the worst shape of silent failure, because
every other subscription in the same `setup()` keeps working and the plugin looks alive.

## 12. A copying paste does broadcast, on `duplicate`

The previous version of this file said there was no copy event and that copy had to be
handled by wrapping the paste command. That is wrong. `yazi-scheduler/src/hook/hook.rs`
pushes `duplicate` when a copy task finishes and `move` when a move task finishes:

```rust
pub(crate) async fn copy(&self, task: HookInOutCopy) {          // -> duplicate
pub(crate) async fn r#move(&self, task: HookInOutMove) {        // -> move
```

So `p` never has to be rebound. Two things follow.

The payload carries the name yazi really created, which matters because a paste renames
around a collision: `a.txt` becomes `a_1.txt`, `c.tar.gz` becomes `c.tar_1.gz`, and a
directory `d` becomes `d_1`. Predicting those names from the yank list is guesswork that
the event makes unnecessary.

A cross filesystem cut stays a single move task, which falls back to copying internally
without publishing `duplicate`, so one cut produces exactly one `move` and never a stray
copy record.

## 13. A copy keeps the source's mtime, so freshness proves nothing

Checking that a pasted copy is younger than the record that describes it always fails: the
copy carries the source's modification time, not the time of the paste. Compare the pair
instead. A file that is still a copy of its source has the same size and the same mtime as
that source, and that is the check worth making before removing it.

## 14. `ya pkg` deploys only the Lua files, the README, the LICENSE and `assets/`

A shell helper next to `main.lua` runs perfectly from a git checkout and does not exist
for anybody who installed the plugin. From `yazi-cli/src/package/dependency.rs`:

```rust
let mut files: Vec<String> =
  ["LICENSE", "README.md", "main.lua"].into_iter().map(Into::into).collect();
// plus every other *.lua whose stem is kebab-cased, plus assets/ wholesale
```

So a plugin is its `.lua` files and nothing else. Sibling modules are fine, a `.sh`, a
`.py` or a data file is not. Testing from the repo cannot see this, which is why
`tests/installed.sh` deploys that exact list before it drives yazi.

It also means the trash logic has to live in Lua, since `fs.trash.*` reads and manages
entries but cannot create one, and `remove` only ever acts on the current selection.
External *commands* are still fine, only shipped *files* are not.

## 15. `fs.read_dir` needs its options table, and lies about `Cha` without `resolve`

Two separate traps in one call.

```lua
fs.read_dir(url)                      -- raises: bad argument #2, nil to table
fs.read_dir(url, {})                  -- works, but every Cha is a dummy
fs.read_dir(url, { resolve = true })  -- works, and the Cha is real
```

The raise happens inside an async entry, where it kills the entry with no toast, no log
line and no visible effect. Identical in shape to item 1.

The second is quieter still. With `{}` every entry comes back with `cha.len == 0` and
`cha.mtime == nil`, so any sort by date or sum of sizes silently produces nothing useful.
`fs.cha(f.url)` on the same path returns the real values, which is what makes the
difference easy to miss.

## 16. A file deleted from another filesystem is not in the home trash

The freedesktop spec puts it in that filesystem's own trash, at the top of the mount, and
yazi follows the spec. Deleting `/tmp/tmp-1/tmp-1.0/d.txt` on a machine where `/tmp` is a
tmpfs writes `/tmp/.Trash-1000/files/d.txt` and leaves `~/.local/share/Trash` untouched.

```
$ df --output=fstype /tmp /home   ->   tmpfs, ext4
$ cat /tmp/.Trash-1000/info/tmp-1.3.trashinfo
[Trash Info]
Path=/tmp/tmp-1/tmp-1.3
```

So restoring means looking in more than one place: the home trash, plus `.Trash-$uid` or
`.Trash/$uid` in each directory above the file, nearest mount first. `ya.uid()` gives the
number that names those directories.

Two details in the records themselves. In a volume trash the spec allows `Path=` to be
relative to the directory holding the trash, so it has to be resolved against that
directory rather than assumed absolute, even though yazi itself writes it absolute. And
when this plugin trashes something, it has to write into the volume trash too, otherwise
the entry is a copy across two filesystems recorded in the wrong place.

The reason this survived a green test suite: every fixture kept the work directory and the
trash on one filesystem, which is the one arrangement where the bug cannot appear.
`tests/installed.sh` now puts a work directory on `/dev/shm` for exactly this.
