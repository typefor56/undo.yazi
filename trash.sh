#!/usr/bin/env bash
# Filesystem work that yazi's Lua API does not expose: freedesktop trash writes,
# restore by original path, and the purgatory staging area.
#
# The percent decoder and the restore loop come from the prototype in
# reference/trash-undo.sh, which is tested against names with spaces and accents.
#
# Every subcommand validates the whole batch before touching anything, so a
# refusal leaves the filesystem exactly as it was.
#
#   trash.sh restore PATH...          pull these exact paths back out of the trash
#   trash.sh trash PATH...            send these paths to the trash
#   trash.sh move SRC DST [SRC DST]   move each SRC to DST, refusing occupied DSTs
#   trash.sh orphans                  park .trashinfo records whose file is gone
#   trash.sh prune DIR DAYS GB        age and size cap for the purgatory

set -u
export LC_ALL=C          # byte-wise ${#s} and "'$c", which percent coding needs

TRASH="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"

die() { echo "$1" >&2; exit 1; }

# Path= in a .trashinfo is percent encoded, findings item 7
decode() { printf '%b' "${1//%/\\x}"; }

encode() {
	local s=$1 out= c i
	for ((i = 0; i < ${#s}; i++)); do
		c=${s:i:1}
		case $c in
			[a-zA-Z0-9/._~-]) out+=$c ;;
			*) out+=$(printf '%%%02X' "'$c") ;;
		esac
	done
	printf '%s' "$out"
}

orig_of() { decode "$(sed -n 's/^Path=//p' "$1" | head -1)"; }

cmd_restore() {
	[ -d "$TRASH/info" ] || die "no trash at $TRASH"
	local -a infos=() srcs=() dests=()
	local want info base src orig found

	for want in "$@"; do
		[ -e "$want" ] || [ -L "$want" ] && die "occupied: $want"
		found=
		while IFS= read -r info; do
			[ -n "$info" ] || continue
			base=$(basename "$info" .trashinfo)
			src="$TRASH/files/$base"
			[ -e "$src" ] || [ -L "$src" ] || continue
			orig=$(orig_of "$info")
			[ "$orig" = "$want" ] || continue
			found=$info
			break
		done < <(ls -1t "$TRASH/info"/*.trashinfo 2>/dev/null)
		[ -n "$found" ] || die "not in the trash: $want"
		infos+=("$found")
		srcs+=("$TRASH/files/$(basename "$found" .trashinfo)")
		dests+=("$want")
	done

	local i
	for i in "${!dests[@]}"; do
		mkdir -p -- "$(dirname -- "${dests[$i]}")" || die "cannot create ${dests[$i]%/*}"
		mv -n -- "${srcs[$i]}" "${dests[$i]}" || die "move failed: ${dests[$i]}"
		rm -f -- "${infos[$i]}"
	done
	echo "${#dests[@]}"
}

cmd_trash() {
	mkdir -p "$TRASH/files" "$TRASH/info" || die "cannot create $TRASH"
	local p
	for p in "$@"; do
		[ -e "$p" ] || [ -L "$p" ] || die "gone: $p"
	done

	local ts base name i n=0
	ts=$(date +%Y-%m-%dT%H:%M:%S)
	for p in "$@"; do
		base=$(basename -- "$p")
		name=$base
		i=1
		while [ -e "$TRASH/files/$name" ] || [ -e "$TRASH/info/$name.trashinfo" ]; do
			name="$base.$i"
			i=$((i + 1))
		done
		# the record goes first and is removed again on failure: an info file with
		# no matching file hangs yazi's trash listing forever, findings item 6
		printf '[Trash Info]\nPath=%s\nDeletionDate=%s\n' "$(encode "$p")" "$ts" \
			> "$TRASH/info/$name.trashinfo" || die "cannot write the trash record for $p"
		if mv -n -- "$p" "$TRASH/files/$name"; then
			n=$((n + 1))
		else
			rm -f -- "$TRASH/info/$name.trashinfo"
			die "move failed: $p"
		fi
	done
	echo "$n"
}

cmd_move() {
	[ $(($# % 2)) -eq 0 ] || die "move needs SRC DST pairs"
	local i src dst
	for ((i = 1; i <= $#; i += 2)); do
		src=${!i}
		dst=${@:i+1:1}
		[ -e "$src" ] || [ -L "$src" ] || die "gone: $src"
		if [ -e "$dst" ] || [ -L "$dst" ]; then die "occupied: $dst"; fi
	done
	for ((i = 1; i <= $#; i += 2)); do
		src=${!i}
		dst=${@:i+1:1}
		mkdir -p -- "$(dirname -- "$dst")" || die "cannot create ${dst%/*}"
		mv -n -- "$src" "$dst" || die "move failed: $src"
	done
	echo $(($# / 2))
}

cmd_orphans() {
	[ -d "$TRASH/info" ] || die "no trash at $TRASH"
	local park="$TRASH/orphaned-info" info base n=0
	while IFS= read -r info; do
		[ -n "$info" ] || continue
		base=$(basename "$info" .trashinfo)
		[ -e "$TRASH/files/$base" ] || [ -L "$TRASH/files/$base" ] && continue
		mkdir -p -- "$park" || die "cannot create $park"
		mv -n -- "$info" "$park/" && n=$((n + 1))
	done < <(ls -1 "$TRASH/info"/*.trashinfo 2>/dev/null)
	echo "$n"
}

cmd_prune() {
	local dir=$1 days=$2 gb=$3 max oldest
	[ -d "$dir" ] || exit 0
	[ "$days" -gt 0 ] && find "$dir" -mindepth 1 -maxdepth 1 -mtime +"$days" -exec rm -rf -- {} +
	[ "$gb" -gt 0 ] || exit 0
	max=$((gb * 1024 * 1024))          # KiB
	while [ "$(du -sk "$dir" | cut -f1)" -gt "$max" ]; do
		oldest=$(ls -1tr "$dir" | head -1)
		[ -n "$oldest" ] || break
		rm -rf -- "${dir:?}/$oldest"
	done
	exit 0
}

[ $# -ge 1 ] || die "usage: trash.sh restore|trash|move|orphans|prune ..."
sub=$1
shift
case $sub in
	restore) cmd_restore "$@" ;;
	trash) cmd_trash "$@" ;;
	move) cmd_move "$@" ;;
	orphans) cmd_orphans "$@" ;;
	prune) cmd_prune "$@" ;;
	*) die "unknown subcommand: $sub" ;;
esac
