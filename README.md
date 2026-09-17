# undo.yazi

One key to undo the last file operation in [yazi](https://github.com/sxyazi/yazi).

Press `u`. The file comes back.

<!-- SCREENSHOT: assets/undo-delete.gif
     A short loop: hover a file, press d, the file disappears, press u, it returns.
     Record in a clean terminal at ~110x30. -->
![Undo a delete](assets/undo-delete.gif)

## Why

yazi has no undo for file operations. Delete a file and your only recourse is to open the
trash and find it yourself. Cut a file into the wrong directory and you have to remember
where it came from.

The `u` key looks like it should already do this, but upstream it is bound only inside
`[input]`, the text-entry context. There it undoes **typing** in a rename field or a
filter box, exactly like `u` in a vim buffer. It has never had anything to do with files,
and `[mgr]`, the file list, has no `u` binding at all.

This plugin gives that key the meaning you expected.

## Install

```sh
ya pkg add typefor56/undo
```

Then bind it in your `keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = "u"
run  = "plugin undo"
desc = "Undo the last file operation"
```

That is the whole setup. Nothing else is rebound and every other key keeps the meaning
yazi gives it. Undoing a copy is included, and it always asks before it removes anything.
Protecting the permanent delete is opt in, see
[Optional protection](#optional-protection).

## What it can undo

| Operation | Key | Reversible | How |
| --- | --- | --- | --- |
| Delete to trash | `d` | Yes | restored from the system trash to its original path |
| Cut and paste | `x` then `p` | Yes | moved back to where it came from |
| Move | drag or `x` | Yes | same as cut |
| Rename | `r` | Yes | renamed back |
| Bulk rename | `R` | Yes | every name reverted |
| Copy and paste | `y` then `p` | Yes, with a prompt | the created copies are trashed |
| Permanent delete | `D` | **No**, unless protection is on | see below |

`u` is also context aware. Inside `trash://` it restores whatever you have hovered or
selected, so it works the way you would expect in both places.

<!-- SCREENSHOT: assets/notification.png
     The toast after undoing a cut, showing the "undo [action: cut]" title
     and the destination path in the body. -->
![Notification](assets/notification.png)

Every undo tells you what it reversed, so you are never guessing whether it fired:

```
undo [action: delete]    3 files restored to ~/Downloads
undo [action: cut]       moved back to ~/Documents/reports
undo [action: copy]      2 copies moved to the trash
cancel [action: copy]    nothing changed
```

## What it will not do

It refuses rather than guesses. If something now occupies the path a file would return
to, or the file changed since the operation, the undo is declined with a warning and
nothing is touched. A refused undo never destroys data to make room.

**Permanent delete cannot be undone.** `D` runs `remove --permanently`, which unlinks the
file with no copy kept anywhere. No plugin can recover it afterwards.

## Optional protection

If you want `D` to be recoverable, the plugin can intercept it and move files to a
private holding area instead of unlinking them:

```lua
-- init.lua
require("undo"):setup {
  purgatory = true,        -- D stages files instead of unlinking them
  purgatory_max_gb = 1,
  purgatory_max_days = 30,
}
```

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on   = "D"
run  = "plugin undo -- purge"
desc = "Stage a permanent delete, recoverable with u"
```

Both halves are needed, which means you can add either one first and nothing changes until
the other is there. Without the binding, `D` is yazi's own permanent delete. Without
`purgatory = true`, the binding hands straight back to it.

Think about this one before enabling it. It changes what `D` means. If you press `D`
expecting the bytes to be gone, staging them somewhere is the opposite of what you asked
for, and on a machine where that matters it is a step backwards. It is off by default for
that reason.

<!-- SCREENSHOT: assets/trash-restore.png
     yazi inside trash:// with two entries selected, about to press u. -->
![Restore from trash](assets/trash-restore.png)

## How it works

A journal and an inverter, nothing more.

yazi already broadcasts its own file operations over
[DDS](https://yazi-rs.github.io/docs/dds). The plugin subscribes to `trash`, `move`,
`rename`, `bulk-rename` and `duplicate`, writes one record per operation to an append only
log, and on `u` pops the newest record and applies its inverse.

Copies arrive on `duplicate` carrying the names yazi actually created, so a paste that
landed as `report_1.pdf` is undone by name and never by guess.

The log lives at `~/.local/state/yazi/undo.log` and is capped at the last 200 operations.
One line per operation, with the paths percent encoded, which is what stops a tab or a
newline in a filename from breaking it.

## Requirements

- yazi 26.0 or newer, for the `trash://` virtual filesystem and the current DDS payloads
- a freedesktop compliant trash, which is the default on Linux
- bash and coreutils, which the trash and purgatory helper uses

## Troubleshooting

**`g t` hangs on `Loading...`** This is not the plugin. An orphaned `.trashinfo` record,
one whose file no longer exists, makes yazi's trash listing never finish. Check for a
mismatch:

```sh
ls -1 ~/.local/share/Trash/info | wc -l
ls -1 ~/.local/share/Trash/files | wc -l
```

If those numbers differ, run `plugin undo -- clean-trash` to move the orphaned records
into `Trash/orphaned-info`, where they stop breaking the listing and can still be read.

## License

MIT, see [LICENSE](LICENSE).
