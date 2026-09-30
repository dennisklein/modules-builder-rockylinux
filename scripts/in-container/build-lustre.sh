#!/bin/bash
# build-lustre.sh KVER: build the Lustre server (patchless ldiskfs, no ZFS)
# for one stock kernel from Whamcloud's SRPM. kmods and userland come from the
# same rpmbuild run.
set -euo pipefail
# shellcheck source=../lib.sh
. /src/scripts/lib.sh
load_config /src
# shellcheck source=buildlib.sh
. /src/scripts/in-container/buildlib.sh

kver=${1:?usage: build-lustre.sh KVER}
kfull=$kver.$ARCH
srpm=/sources/${LUSTRE_SRPM_URL##*/}
out=/build/rpms/lustre/$kver
log_file=/build/logs/lustre-$kver.log

[[ -f $srpm ]] || die "missing $srpm; run 'make fetch'"
verify_sha256 "$srpm" "${LUSTRE_SRPM_SHA256:-}"

release_id=$(lustre_release_id "$kver")
marker=kmod-lustre-osd-ldiskfs-$LUSTRE_VERSION-$release_id$DIST.$ARCH.rpm
if already_built "$out" "$marker"; then
	log "skipping lustre for $kver: $marker already exists (FORCE=1 rebuilds)"
	exit 0
fi

new_topdir
(cd "$TOP/SOURCES" && rpm2cpio "$srpm" | cpio -idm --quiet)
mv "$TOP/SOURCES/lustre.spec" "$TOP/SPECS/"
spec=$TOP/SPECS/lustre.spec

# The spec does not encode the kernel on RHEL. Make our release_id (kernel +
# site suffix) the spec's default, so the SRPM we publish carries it too.
sed -i -E "s/^%\{!\?release_id:[[:space:]]*%global release_id .*\}$/%{!?release_id: %global release_id $release_id}/" "$spec"
grep -qxF "%{!?release_id: %global release_id $release_id}" "$spec" ||
	die "could not set release_id in lustre.spec"

# rpmbuild --with/--without X, spelled as defines so dnf builddep sees them too.
bcond() { # with|without NAME
	printf -- '--define\n_%s_%s --%s-%s\n' "$1" "$2" "$1" "$2"
}
yes_no() { [[ $1 == yes ]] && echo with || echo without; }
mapfile -t opts < <(
	bcond with servers
	bcond with ldiskfs
	bcond without zfs
	bcond without gss
	bcond without mofed
	bcond with o2ib
	bcond "$(yes_no "$LUSTRE_WITH_IOKIT")" lustre_iokit
	bcond "$(yes_no "$LUSTRE_WITH_TESTS")" lustre_tests
)
opts+=(--define "_topdir $TOP" --define "kdir /usr/src/kernels/$kfull"
	--define "_buildhost kmod-builder")

# BuildRequires: kernel >= 3.10 wants a kernel package; its scriptlets
# (dracut) are pointless here. ext4 sources for ldiskfs come from
# kernel-debuginfo-common. Whamcloud's e2fsprogs-devel replaces the distro's.
log "installing kernel-core-$kver (no scriptlets)"
dnf -y -q --setopt=tsflags=noscripts install "kernel-core-$kver"
install_kernel_pkgs "$kver" kernel-devel "kernel-debuginfo-common-$ARCH"
[[ -f /usr/src/kernels/$kfull/Makefile ]] || die "kernel-devel for $kfull not found"
ext4_src=$(find /usr/src/debug -mindepth 4 -maxdepth 4 -type d -path "*/linux-$kver*/fs/ext4" | sort | tail -n1)
[[ -f $ext4_src/super.c ]] || die "ext4 sources for $kver not found under /usr/src/debug"
log "ext4 sources: $ext4_src"
log "installing Whamcloud e2fsprogs from sources/e2fsprogs"
dnf -y -q install /sources/e2fsprogs/*.rpm
dnf -y -q builddep "${opts[@]}" "$spec"

mkdir -p "${log_file%/*}"
log "rpmbuild lustre $LUSTRE_VERSION for $kfull (log: ${log_file#/})"
{ printf 'rpmbuild -ba'; printf ' %q' "${opts[@]}" "$spec"; printf '\n'; } >"$log_file"
if ! rpmbuild -ba "${opts[@]}" "$spec" >>"$log_file" 2>&1; then
	tail -n 40 "$log_file" >&2
	if grep -qiE 'hunks? FAILED|Patch .* does not apply|can.t find file to patch' "$log_file"; then
		warn "ldiskfs patches failed to apply against $kver:"
		grep -iE -B2 'hunks? FAILED|does not apply|can.t find file to patch' "$log_file" >&2 || true
	fi
	die "rpmbuild failed for lustre $kver"
fi

# configure silently drops ldiskfs if it cannot find the ext4 sources.
grep -E 'which ldiskfs series to use|ext4 source directory' "$log_file" | sed 's/^/    /' >&2 || true
collect_results "$out"
/src/scripts/in-container/check-kmod.sh "$out/RPMS/$marker" "$kfull" ldiskfs osd_ldiskfs
/src/scripts/in-container/check-kmod.sh "$out/RPMS/kmod-lustre-$LUSTRE_VERSION-$release_id$DIST.$ARCH.rpm" \
	"$kfull" libcfs lnet ko2iblnd ksocklnd ptlrpc obdclass lustre mgs mdt ofd
