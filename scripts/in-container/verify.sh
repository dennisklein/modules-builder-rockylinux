#!/bin/bash
# verify.sh: run check-kmod.sh on every kmod package in the published repo,
# and make sure each configured kernel has all required kmods.
set -euo pipefail
# shellcheck source=../lib.sh
. /src/scripts/lib.sh
load_config /src

pkgdir=/repo/$EL_TAG/$ARCH/Packages

# Modules that must be present, per package name.
declare -A expect=(
	[kmod-drbd]="drbd drbd_transport_tcp drbd_transport_lb-tcp drbd_transport_rdma"
)
required=(kmod-drbd)

declare -A have=()
n=0
shopt -s nullglob
for rpm in "$pkgdir"/kmod-*.rpm; do
	case ${rpm##*/} in *-debuginfo-*) continue ;; esac
	name=$(rpm -qp --qf '%{NAME}' "$rpm" 2>/dev/null)
	kfull=$(rpm -qlp "$rpm" 2>/dev/null | sed -n 's#^/lib/modules/\([^/]*\)/extra/.*#\1#p' | sort -u)
	[[ -n $kfull && $kfull != *$'\n'* ]] || die "${rpm##*/}: modules for none or several kernels"
	# shellcheck disable=SC2086 # module list is word-split on purpose
	/src/scripts/in-container/check-kmod.sh "$rpm" "$kfull" ${expect[$name]:-}
	have[$name/$kfull]=1
	n=$((n + 1))
done

for kver in $KVERS; do
	for name in "${required[@]}"; do
		[[ -n ${have[$name/$kver.$ARCH]:-} ]] || die "no $name for $kver in the repo"
	done
done
log "verified $n kmod packages"
