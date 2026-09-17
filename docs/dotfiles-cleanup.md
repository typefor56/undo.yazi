# Cleanup checklist for the dotfiles repo

Run this against `~/Documents/programming/github-noforest/dotfiles` **after** undo.yazi is
published and installable. Until then the prototype is what makes `u` work, so do not
remove it early.

## Replace the prototype

1. Delete the prototype from the dotfiles repo:

   ```
   modules/desktop/.config/yazi/plugins/undo-delete.yazi/
   ```

   It contains `main.lua` and `trash-undo.sh`. Both are preserved in this repository under
   `reference/`, so nothing is lost.

2. Delete the live copy as well, since plugins are not symlinked:

   ```
   ~/.config/yazi/plugins/undo-delete.yazi/
   ```

3. Install the real plugin, which also records it in `package.toml`:

   ```sh
   cd ~/.config/yazi && ya pkg add typefor56/undo
   ```

4. Repoint the binding. In `modules/desktop/.config/yazi/keymap.toml`, the `u` entry
   currently reads `plugin undo-delete` and becomes `plugin undo`. It sits just after the
   `g t` trash binding in `[mgr]`.

5. If the shipped design needs configuration, add it to
   `modules/desktop/.config/yazi/init.lua` alongside the existing `full-border`, `duckdb`
   and `custom-shell` setup calls. Add the `p` and `D` interceptor bindings only if
   copy-undo or purgatory are being enabled.

## While in there

6. Remove the 35 stray `.bak-*` files under `plugins/` and `flavors/`, left behind by
   `dot link`:

   ```sh
   find modules/desktop/.config/yazi/plugins modules/desktop/.config/yazi/flavors \
        -name "*.bak-*" -print
   ```

   These are what made `ya pkg upgrade` refuse to touch the catppuccin flavor, reporting
   local modifications. Review the list before deleting.

7. `reference/main.lua` is worth a second look before it is thrown away. Its context aware
   behaviour, where `u` inside `trash://` restores the selection instead of consulting the
   journal, is a real feature and should survive into the plugin.

## Two traps in this repo

**`plugins/` and `flavors/` are real directories, not symlinks.** Only the `.toml` files
in `~/.config/yazi/` are symlinked to the dotfiles repo. The plugin and flavor directories
are independent copies, so a change in one does not appear in the other and they drift.

**Sync them with `cp -rL`, never `rsync -a`.** Several files inside
`~/.config/yazi/plugins/` are themselves symlinks pointing back into the dotfiles repo.
A plain `rsync -a` preserves those links, which turns the repo's own files into
self referential symlinks and produces `Too many levels of symbolic links`. This happened
once already and was recovered with `git checkout`. `cp -rL` dereferences and is safe.

Verify afterwards that no symlinks crept in:

```sh
find modules/desktop/.config/yazi/plugins modules/desktop/.config/yazi/flavors -type l
git status --short | grep "^ T"     # typechanges, should be empty
```

## Verify the swap

```sh
# config still loads
cd /tmp && COLUMNS=120 LINES=40 timeout 6 script -qec "yazi /tmp" /dev/null 2>&1 \
  | strings | grep -aiE "parse error|caused|unknown|failed"

# the old name is gone
grep -rn "undo-delete" ~/.config/yazi/ || echo "clean"
```

Then run the delete and undo round trip from `testing.md` against an isolated
`XDG_DATA_HOME` to confirm `u` still works through the new plugin.
