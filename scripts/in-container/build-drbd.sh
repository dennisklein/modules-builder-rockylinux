#!/bin/bash
# build-drbd.sh KVER: build kmod-drbd and its SRPM for one kernel, using
# upstream's kmodtool-based drbd-kernel.spec.
set -euo pipefail
# shellcheck source=../lib.sh
. /src/scripts/lib.sh
load_config /src
# shellcheck source=buildlib.sh
. /src/scripts/in-container/buildlib.sh

kver=${1:?usage: build-drbd.sh KVER}
kfull=$kver.$ARCH
tarball=/sources/drbd-$DRBD_VERSION.tar.gz
out=/build/rpms/drbd/$kver
log_file=/build/logs/drbd-$kver.log

[[ -f $tarball ]] || die "missing $tarball; run 'make fetch'"
verify_sha256 "$tarball" "${DRBD_SHA256:-}"

new_topdir
spec=$TOP/SPECS/drbd-kernel.spec
tar -xzOf "$tarball" "drbd-$DRBD_VERSION/drbd-kernel.spec" >"$spec"

# Release: append the site suffix and the dist tag, so our build never has the
# NEVR of an upstream or hand-made kmod-drbd.
upstream_rel=$(sed -nE 's/^Release:[[:space:]]*([^[:space:]%]+)[[:space:]]*$/\1/p' "$spec")
[[ -n $upstream_rel ]] || die "unexpected Release: line in drbd-kernel.spec"
release=$upstream_rel.$SITE_RELEASE_SUFFIX
sed -i -E "s/^Release:.*/Release: $release%{?dist}/" "$spec"

marker=kmod-drbd-${DRBD_VERSION}_$(kmp_kver "$kver")-$release$DIST.$ARCH.rpm
if already_built "$out" "$marker"; then
	log "skipping drbd for $kver: $marker already exists (FORCE=1 rebuilds)"
	exit 0
fi

# Compat patches that we generated and committed (patches/drbd-compat/<md5>)
# and that the release tarball does not already ship go into the SRPM as an
# extra source and are unpacked into the cocci cache before the build.
declare -A shipped=()
while read -r md5; do
	shipped[$md5]=1
done < <(tar -tzf "$tarball" |
	sed -nE 's#^[^/]+/drbd/drbd-kernel-compat/cocci_cache/([0-9a-f]{32})/.*#\1#p' | sort -u)
extra=()
for d in /src/patches/drbd-compat/*/; do
	[[ -f $d/compat.patch ]] || continue
	md5=$(basename "$d")
	[[ -n ${shipped[$md5]:-} ]] || extra+=("$md5")
done
if ((${#extra[@]})); then
	log "adding ${#extra[@]} committed compat cache entries"
	tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
		-cf "$TOP/SOURCES/drbd-compat-cache.tar" -C /src/patches/drbd-compat "${extra[@]}"
	sed -i -e '/^Source:/a Source1: drbd-compat-cache.tar' \
		-e '/^%setup -q -n drbd-/a tar -xf %{SOURCE1} -C drbd/drbd-kernel-compat/cocci_cache' "$spec"
	[[ $(grep -c 'drbd-compat-cache.tar\|%{SOURCE1}' "$spec") == 2 ]] ||
		die "could not add the compat cache to drbd-kernel.spec"
fi
cp "$tarball" "$TOP/SOURCES/"

install_kernel_pkgs "$kver" kernel-devel
[[ -f /usr/src/kernels/$kfull/Makefile ]] || die "kernel-devel for $kfull not found"
grep -qx 'CONFIG_INFINIBAND_ADDR_TRANS=y' "/usr/src/kernels/$kfull/.config" ||
	die "$kfull lacks CONFIG_INFINIBAND_ADDR_TRANS; drbd_transport_rdma would not be built"

defines=(--define "_topdir $TOP" --define "kernel_version $kfull" --define "_buildhost kmod-builder")
dnf -y -q builddep "${defines[@]}" "$spec"

# SPAAS=false keeps the build offline; only DRBD_ALLOW_SPAAS=yes lets DRBD's
# build ask https://spaas.drbd.io for a missing compat patch.
spaas=false
[[ $DRBD_ALLOW_SPAAS == yes ]] && spaas=true
mkdir -p "${log_file%/*}"
log "rpmbuild kmod-drbd for $kfull (log: ${log_file#/})"
if ! SPAAS=$spaas rpmbuild -ba "${defines[@]}" "$spec" >"$log_file" 2>&1; then
	tail -n 40 "$log_file" >&2
	if grep -q 'spatch-as-a-service was disabled' "$log_file"; then
		die "no DRBD compat patch for $kfull: neither the tarball nor patches/drbd-compat/
has one and no local spatch is available. Re-run once with DRBD_ALLOW_SPAAS=yes
in config.local.env (contacts https://spaas.drbd.io), then commit the new
patches/drbd-compat/<md5> directory."
	fi
	die "rpmbuild failed for drbd $kver"
fi

# Which cache entry did the build use? If we did not ship it, hand it back so
# the host can save it under patches/drbd-compat/.
used=$(readlink -f "$TOP/BUILD/drbd-$DRBD_VERSION/drbd/build-current/compat.patch")
md5=$(basename "$(dirname "$used")")
[[ $md5 =~ ^[0-9a-f]{32}$ ]] || die "cannot tell which compat patch was used ($used)"
if [[ -n ${shipped[$md5]:-} ]]; then
	log "compat patch $md5 from the release tarball"
elif [[ -d /src/patches/drbd-compat/$md5 ]]; then
	log "compat patch $md5 from patches/drbd-compat"
else
	log "compat patch $md5 was generated during this build"
	mkdir -p "/build/drbd-compat/$md5"
	for f in compat.h compat.patch kernelrelease.txt applied_cocci_files.txt; do
		if [[ -f ${used%/*}/$f ]]; then cp "${used%/*}/$f" "/build/drbd-compat/$md5/"; fi
	done
fi

collect_results "$out"
/src/scripts/in-container/check-kmod.sh "$out/RPMS/$marker" "$kfull" \
	drbd drbd_transport_tcp drbd_transport_lb-tcp drbd_transport_rdma
