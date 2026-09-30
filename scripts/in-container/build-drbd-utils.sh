#!/bin/bash
# build-drbd-utils.sh: build drbd-utils and its subpackages from LINBIT's
# release tarball. Not kernel specific; built once.
set -euo pipefail
# shellcheck source=../lib.sh
. /src/scripts/lib.sh
load_config /src
# shellcheck source=buildlib.sh
. /src/scripts/in-container/buildlib.sh

tarball=/sources/drbd-utils-$DRBD_UTILS_VERSION.tar.gz
out=/build/rpms/drbd-utils/all
log_file=/build/logs/drbd-utils.log

[[ -f $tarball ]] || die "missing $tarball; run 'make fetch'"
verify_sha256 "$tarball" "${DRBD_UTILS_SHA256:-}"

new_topdir
mkdir -p "${log_file%/*}"
# The tarball ships drbd.spec.in only; upstream's "make rpm" generates the spec
# with "configure --enable-spec". configure takes paths such as the udev rules
# directory from pkg-config, so the spec is generated once to learn the build
# dependencies and again once they are installed.
work=$(mktemp -d)
tar -xzf "$tarball" -C "$work"
spec=$TOP/SPECS/drbd.spec
gen_spec() {
	(cd "$work/drbd-utils-$DRBD_UTILS_VERSION" &&
		./configure --enable-spec --prefix=/usr --sysconfdir=/etc --localstatedir=/var) \
		>>"$log_file" 2>&1 || { tail -n 20 "$log_file" >&2; die "configure --enable-spec failed"; }
	cp "$work/drbd-utils-$DRBD_UTILS_VERSION/drbd.spec" "$spec"
	upstream_rel=$(sed -nE 's/^Release:[[:space:]]*([^[:space:]%]+)%\{\?dist\}[[:space:]]*$/\1/p' "$spec")
	[[ -n $upstream_rel ]] || die "unexpected Release: line in drbd.spec"
	release=$upstream_rel.$SITE_RELEASE_SUFFIX
	sed -i -E "s/^Release:.*/Release: $release%{?dist}/" "$spec"
}
: >"$log_file"
gen_spec

marker=drbd-utils-$DRBD_UTILS_VERSION-$release$DIST.$ARCH.rpm
if already_built "$out" "$marker"; then
	log "skipping drbd-utils: $marker already exists (FORCE=1 rebuilds)"
	exit 0
fi
cp "$tarball" "$TOP/SOURCES/"

# Man pages are prebuilt in the release tarball: no docbook/xsltproc/po4a.
opts=(--define "_topdir $TOP" --define "_buildhost kmod-builder"
	--define "_with_prebuiltman --with-prebuiltman")
dnf -y -q builddep "${opts[@]}" "$spec"
gen_spec

log "rpmbuild drbd-utils $DRBD_UTILS_VERSION (log: ${log_file#/})"
if ! rpmbuild -ba "${opts[@]}" "$spec" >>"$log_file" 2>&1; then
	tail -n 40 "$log_file" >&2
	die "rpmbuild failed for drbd-utils"
fi
collect_results "$out"
[[ -f $out/RPMS/$marker ]] || die "expected $marker was not built"
