#!/bin/bash
# test-install.sh KVER: runs in a fresh container from BASE_IMAGE with only the
# pinned Rocky repos and the generated repo (file:///repo, through the rendered
# .repo file). Installs the kernel and the full server set for KVER, then
# checks that the modules resolve and that the repo is closed.
set -euo pipefail
# shellcheck source=../lib.sh
. /src/scripts/lib.sh
load_config /src

kver=${1:?usage: test-install.sh KVER}
kfull=$kver.$ARCH
kmp=$(kmp_kver "$kver")
repofile=/repo/$REPO_ID.repo
[[ -f $repofile ]] || die "no ${repofile#/repo/} in OUT_DIR; run 'make repo' first"

/src/scripts/in-container/render-rocky-repos.sh "$ROCKY_BASEURL" "$ROCKY_GPGKEY"
sed "s#${REPO_PUBLIC_BASEURL%/}#file:///repo#g" "$repofile" >"/etc/yum.repos.d/$REPO_ID.repo"
dnf=(dnf -y -q --setopt=keepcache=1)

log "installing kernel-core-$kver"
"${dnf[@]}" install "kernel-core-$kver"

pkgs=("kmod-drbd-${DRBD_VERSION}_$kmp")
log "installing ${pkgs[*]}"
"${dnf[@]}" install "${pkgs[@]}"

for p in "${pkgs[@]}"; do
	rel=$(rpm -q --qf '%{RELEASE}' "$p")
	[[ $rel == *".$SITE_RELEASE_SUFFIX"* ]] || die "$p-$rel is not our build"
	log "installed $(rpm -q "$p")"
done

depmod -a "$kfull"
for m in drbd drbd_transport_tcp drbd_transport_rdma; do
	modprobe -S "$kfull" --show-depends "$m" >/dev/null ||
		die "module $m does not resolve for $kfull"
done
log "modules resolve for $kfull: drbd drbd_transport_tcp drbd_transport_rdma"

"${dnf[@]}" install dnf-plugins-core
log "repoclosure of $REPO_ID"
dnf -q repoclosure --check "$REPO_ID"
log "install test for $kver passed"
