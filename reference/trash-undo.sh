#!/usr/bin/env bash
# REFERENCE ONLY, NOT THE IMPLEMENTATION.
# Proven freedesktop-spec restore, including percent-decoding (findings item 7).
# Tested against names with spaces and accents. Reuse this logic rather than
# rewriting it.
# Restore the most recently trashed entries to where they were deleted from.
# Reads the XDG trash directly (the same spec yazi's `remove` writes), so it
# works from anywhere, without having to open trash:// first.
#
# Usage: trash-undo.sh [N]    N = how many of the newest entries (default 1)

set -u
TRASH="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"
N="${1:-1}"

[ -d "$TRASH/info" ] || { echo "no trash at $TRASH"; exit 1; }

# Path= in a .trashinfo is percent-encoded per the freedesktop spec
decode() { printf '%b' "${1//%/\\x}"; }

restored=0
# newest first, by the info record's mtime
while IFS= read -r info; do
    [ -n "$info" ] || continue
    [ "$restored" -ge "$N" ] && break

    base=$(basename "$info" .trashinfo)
    src="$TRASH/files/$base"
    [ -e "$src" ] || [ -L "$src" ] || continue

    orig=$(decode "$(sed -n 's/^Path=//p' "$info" | head -1)")
    case "$orig" in
        /*) ;;
        *)  echo "skipped $base: relative Path in its record"; continue ;;
    esac

    if [ -e "$orig" ]; then
        echo "skipped $base: $orig already exists"
        continue
    fi

    mkdir -p -- "$(dirname -- "$orig")" || continue
    if mv -n -- "$src" "$orig"; then
        rm -f -- "$info"
        echo "restored: $orig"
        restored=$((restored + 1))
    fi
done < <(ls -1t "$TRASH/info"/*.trashinfo 2>/dev/null)

[ "$restored" -eq 0 ] && { echo "nothing to restore"; exit 1; }
exit 0
