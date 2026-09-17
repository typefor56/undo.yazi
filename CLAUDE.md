# Directives for implementing undo.yazi

Read `docs/findings.md` before writing a single line. Every item in it cost a real debug
cycle. Several are silent failures that produce no error and no log, so you will not find
them by trial and error in reasonable time.

## Use ponytail

Invoke the `ponytail:ponytail` skill (`/ponytail`) before you start, and hold to it.

This plugin is a journal and an inverter. That is the whole design. Specifically, do not
build:

- a plugin framework, a command registry, or a dispatch abstraction over DDS
- an adapter layer that wraps `ps.sub` in your own event type
- a config system for values that never change
- an undo *stack* with branching, redo trees, or history navigation. One linear log,
  newest first, is the feature. `<C-r>` was added later on request and stays inside that
  rule: one second log holding what was undone, cleared by the next real operation, no
  branch and no tree

The target is a few hundred lines of Lua across a handful of files. If you find yourself
at a thousand, something went wrong upstream of the code.

Reach for what already exists. yazi broadcasts `trash`, `move`, `rename` and `bulk`
itself, so do not reimplement file tracking. The bundled `trash` plugin already restores
entries, so call it rather than writing trash logic. `reference/trash-undo.sh` already
implements a correct freedesktop restore, including percent decoding, and it is tested.

## Scope, in priority order

1. **Delete to trash** and **cut / move**. Both fully reversible, both driven by DDS
   events. Ship these first and make them solid.
2. **Rename** and **bulk rename**. Cheap, same mechanism, from and to are in the payload.
3. **Copy**. yazi does broadcast it, on `duplicate`, so nothing needs wrapping, see
   findings item 12. Undoing a copy deletes files, so it must confirm with `ya.confirm`
   and must verify each target still matches what the paste created before removing
   anything.
4. **Purgatory for `D`**. Opt in, default off. See the README section, and keep that
   framing: it changes what `D` means, and the user must choose it deliberately.

Do not start at 4. Items 1 and 2 are the whole value for most users.

## Correctness rules that are not negotiable

- **Refuse rather than guess.** If the destination is occupied, the source reappeared, or
  the file changed since the operation, decline with a warning and touch nothing. Never
  overwrite to make an undo succeed.
- **Never use yank and paste to restore anything.** Cut and paste across `trash://`
  silently produces a zero byte file, see findings item 5.
- **Never test against the real trash or the real home.** Always an isolated
  `XDG_DATA_HOME`, see `docs/testing.md`. A bug here destroys the user's files.
- Undo of a copy is the only path that deletes data. Route it through the trash, not
  through unlink, so that it is itself recoverable.

## Notifications

Every `u` press must say what it did. The action goes in the title, in this exact shape:

```
undo [action: delete]
undo [action: cut]
undo [action: copy]
cancel [action: copy]
```

Use `ya.notify { title, content, level, timeout }`. `level` is `"info"` on success,
`"warn"` when an undo is refused or there is nothing to undo, `"error"` on failure. The
body carries the detail, such as how many files and where they went.

## Testing

`docs/testing.md` has the harness. The short version: yazi needs a pty, so drive it
through `tmux -L <unique-socket>` and read the result with `capture-pane`.

Per ponytail, non-trivial logic leaves **one** runnable check behind, not a suite. The
inverter for each operation kind is exactly the kind of logic that needs one. The journal
parser too. No frameworks, no fixtures, no mocking of yazi.

Use `tmux -L <unique-socket>` every time. A plain `tmux kill-server` kills the user's own
session, which happened while building the prototype.

## Commits

Subject line, blank line, explanatory body. The body says why, not what.

No trailers of any kind. No `Co-Authored-By`, no "Generated with", no signature. This is a
hard preference of the repository owner and applies to pull request descriptions too.

## Writing style for the docs

No em dashes and no semicolons in prose. Both read as machine written and this is a public
repository. Code blocks are exempt, shell needs what shell needs.

## Reference material

`reference/main.lua` and `reference/trash-undo.sh` are the working prototype this plugin
grows out of. They handle delete to trash only, with no journal, and the Lua one is
context aware for `trash://`. Treat them as a proven starting point for those paths and as
evidence of the API shapes that actually work, not as an architecture to preserve.
