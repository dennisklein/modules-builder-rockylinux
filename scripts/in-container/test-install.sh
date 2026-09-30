#!/bin/bash
# test-install.sh KVER [file|http]: runs in a fresh container from BASE_IMAGE
# with only the pinned Rocky repos and the generated repo, configured through
# the rendered .repo file (baseurl pointed at file:///repo, or at a local
# python3 -m http.server serving /repo). Installs the kernel and the full
# server set for KVER, checks that the modules resolve, and runs repoclosure.
set -euo pipefail
# shellcheck source=../lib.sh
. /src/scripts/lib.sh
load_config /src

kver=${1:?usage: test-install.sh KVER [file|http]}
transport=${2:-file}
kfull=$kver.$ARCH
kmp=$(kmp_kver "$kver")
repofile=/repo/$REPO_ID.repo
[[ -f $repofile ]] || die "no ${repofile#/repo/} in OUT_DIR; run 'make repo' first"

case $transport in
file) url=file:///repo ;;
http)
	port=8321
	(cd /repo && exec python3 -m http.server --bind 127.0.0.1 "$port" >/tmp/http.log 2>&1) &
	url=http://127.0.0.1:$port
	for _ in $(seq 50); do
		curl -fs -o /dev/null "$url/$REPO_ID.repo" && break
		sleep 0.2
	done
	;;
*) die "unknown transport: $transport" ;;
esac

/src/scripts/in-container/render-rocky-repos.sh "$ROCKY_BASEURL" "$ROCKY_GPGKEY"
sed "s#${REPO_PUBLIC_BASEURL%/}#$url#g" "$repofile" >"/etc/yum.repos.d/$REPO_ID.repo"
if [[ -n $GPG_KEY_ID ]]; then
	for opt in gpgcheck=1 repo_gpgcheck=1; do
		[[ $(grep -c "^$opt$" "/etc/yum.repos.d/$REPO_ID.repo") == 3 ]] ||
			die "signed mode, but the rendered .repo file does not set $opt everywhere"
	done
	log "signed mode: gpgcheck=1 and repo_gpgcheck=1 for all sections"
fi
log "repo at $url"

e2fs_repo=$REPO_ID-e2fsprogs
dnf=(dnf -y -q --setopt=keepcache=1 "--enablerepo=$e2fs_repo")
dist=$(rpm -E '%{?dist}')
lrel=$(lustre_release_id "$kver")$dist

# The kernel's own scriptlets (kernel-install, dracut) cannot work in a
# container; the kmod scriptlets (weak-modules) below do run.
log "installing kernel-core-$kver (no scriptlets)"
"${dnf[@]}" --setopt=tsflags=noscripts install "kernel-core-$kver" >/dev/null

ours=(
	"kmod-drbd-${DRBD_VERSION}_$kmp"
	"drbd-utils-$DRBD_UTILS_VERSION"
	"kmod-lustre-$LUSTRE_VERSION-$lrel"
	"kmod-lustre-osd-ldiskfs-$LUSTRE_VERSION-$lrel"
	"lustre-$LUSTRE_VERSION-$lrel"
	"lustre-osd-ldiskfs-mount-$LUSTRE_VERSION-$lrel"
	"lustre-resource-agents-$LUSTRE_VERSION-$lrel"
)
[[ $LUSTRE_WITH_IOKIT == yes ]] && ours+=("lustre-iokit-$LUSTRE_VERSION-$lrel")
log "installing the server set:"
printf '    %s\n' "${ours[@]}" e2fsprogs >&2
"${dnf[@]}" install "${ours[@]}" e2fsprogs >/dev/null

for p in "${ours[@]}"; do
	nevr=$(rpm -q "$p") || die "$p is not installed"
	[[ $nevr == *".$SITE_RELEASE_SUFFIX"* ]] || die "$nevr is not our build"
done
e2fs=$(rpm -q e2fsprogs)
[[ $e2fs == *wc* ]] || die "e2fsprogs is $e2fs, not Whamcloud's"
from=$(dnf -q repoquery --installed --qf '%{from_repo}' e2fsprogs)
[[ $from == "$e2fs_repo" ]] || die "e2fsprogs came from '$from', not $e2fs_repo"
log "installed from $REPO_ID: $(rpm -q --qf '%{NAME} ' "${ours[@]}")"
log "installed $e2fs"

depmod -a "$kfull"
mods=(drbd drbd_transport_tcp drbd_transport_rdma libcfs lnet ko2iblnd ptlrpc ldiskfs osd_ldiskfs mgs mdt ofd lustre)
for m in "${mods[@]}"; do
	modprobe -S "$kfull" --show-depends "$m" >/dev/null ||
		die "module $m does not resolve for $kfull"
done
log "modules resolve for $kfull: ${mods[*]}"
version=$(drbdadm --version 2>&1 || true)
grep -qx "DRBDADM_VERSION=$DRBD_UTILS_VERSION" <<<"$version" ||
	die "drbdadm --version does not report $DRBD_UTILS_VERSION:"$'\n'"$version"
log "drbdadm --version reports $DRBD_UTILS_VERSION"

"${dnf[@]}" install dnf-plugins-core >/dev/null
log "repoclosure of $REPO_ID and $e2fs_repo"
dnf -q "--enablerepo=$e2fs_repo" repoclosure --check "$REPO_ID" --check "$e2fs_repo"
log "install test for $kver ($transport) passed"
