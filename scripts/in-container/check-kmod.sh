#!/bin/bash
# check-kmod.sh RPM KFULL [MODULE...]
# Quality gate for one kmod package built for kernel KFULL (with .arch):
#  - every module lives under /lib/modules/KFULL/extra/, nothing else in /lib/modules
#  - each module's vermagic is KFULL and it carries no debug info
#  - the package requires kernel symbols (kernel(...)) and runs weak-modules
#  - each MODULE (name without .ko) is present
set -euo pipefail
# shellcheck source=../lib.sh
. /src/scripts/lib.sh

rpm=${1:?usage: check-kmod.sh RPM KFULL [MODULE...]}
kfull=${2:?usage: check-kmod.sh RPM KFULL [MODULE...]}
shift 2
[[ -f $rpm ]] || die "no such package: $rpm"
name=$(rpm -qp --qf '%{NAME}' "$rpm" 2>/dev/null)
fail() { die "$name ($kfull): $*"; }

files=$(rpm -qlp "$rpm" 2>/dev/null)
modre='\.ko(\.xz|\.gz|\.zst)?$'
stray=$(grep '^/lib/modules/' <<<"$files" |
	grep -vE "^/lib/modules/$kfull(/extra(/.*)?)?$" || true)
[[ -z $stray ]] || fail "files outside /lib/modules/$kfull/extra/:"$'\n'"$stray"
grep -qE "$modre" <<<"$files" || fail "contains no kernel modules"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && rpm2cpio "$rpm" | cpio -idm --quiet)

declare -A found=()
nmod=0
while read -r ko; do
	base=${ko##*/}
	base=${base%.xz}; base=${base%.gz}; base=${base%.zst}
	plain=$tmp/check.ko
	case $ko in
	*.xz) xz -dc "$ko" >"$plain" ;;
	*.gz) gzip -dc "$ko" >"$plain" ;;
	*.zst) zstd -qdc "$ko" >"$plain" ;;
	*) cp "$ko" "$plain" ;;
	esac
	vermagic=$(modinfo -F vermagic "$plain")
	[[ ${vermagic%% *} == "$kfull" ]] || fail "$base has vermagic '$vermagic'"
	if grep -q '\.debug_info' <<<"$(readelf -S --wide "$plain")"; then
		fail "$base is not stripped of debug info"
	fi
	found[${base%.ko}]=1
	nmod=$((nmod + 1))
done < <(find "$tmp/lib/modules" -type f -regextype posix-extended -regex ".*$modre")

# Symlinked modules (Lustre's ko2iblnd.ko -> in-kernel-ko2iblnd.ko) count if
# they resolve to a module inside the package.
while read -r ko; do
	target=$(readlink -f "$ko")
	[[ $target == "$tmp"/* && -f $target ]] || fail "${ko##*/} is a dangling symlink"
	base=${ko##*/}
	base=${base%.xz}; base=${base%.gz}; base=${base%.zst}
	found[${base%.ko}]=1
done < <(find "$tmp/lib/modules" -type l -regextype posix-extended -regex ".*$modre")

for m; do
	[[ -n ${found[$m]:-} ]] || fail "missing module $m.ko"
done

nksym=$(rpm -qp --requires "$rpm" 2>/dev/null | grep -c '^kernel(' || true)
((nksym > 0)) || fail "no kernel(...) symbol requirements"
grep -q weak-modules <<<"$(rpm -qp --scripts "$rpm" 2>/dev/null)" || fail "no weak-modules scriptlets"

log "OK ${rpm##*/}: $nmod modules, vermagic $kfull, $nksym kernel symbol requires, weak-modules"
