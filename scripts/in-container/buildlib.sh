# shellcheck shell=bash
# Helpers for the in-container build steps. Sourced after lib.sh/load_config.

# shellcheck disable=SC2034 # used by the build scripts that source this file
DIST=$(rpm -E '%{?dist}')
PUBLISHED=/repo/$EL_TAG/$ARCH/Packages

# install_kernel_pkgs KVER PKG...: install PKG-KVER for each PKG, never
# anything newer. kernel-devel must end up at /usr/src/kernels/KVER.ARCH.
install_kernel_pkgs() {
	local kver=$1 p pkgs=()
	shift
	for p; do pkgs+=("$p-$kver"); done
	log "installing ${pkgs[*]}"
	dnf -y -q install "${pkgs[@]}"
	for p; do
		rpm -q "$p-$kver" >/dev/null || die "$p-$kver was not installed"
	done
}

# already_built OUTDIR FILE: true (skip the build) if FILE exists in the
# published repo or in OUTDIR/RPMS, unless FORCE is set.
already_built() {
	case ${FORCE:-} in 1 | yes | true) return 1 ;; esac
	[[ -f $PUBLISHED/$2 || -f $1/RPMS/$2 ]]
}

# new_topdir: private rpmbuild tree in $TOP.
new_topdir() {
	TOP=$(mktemp -d /tmp/rpmbuild.XXXXXX)
	mkdir -p "$TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
}

# collect_results OUTDIR: move all RPMs of $TOP into OUTDIR/{RPMS,SRPMS}.
collect_results() {
	local out=$1
	rm -rf "$out"
	mkdir -p "$out/RPMS" "$out/SRPMS"
	find "$TOP/RPMS" -name '*.rpm' -exec mv -t "$out/RPMS" {} +
	find "$TOP/SRPMS" -name '*.rpm' -exec mv -t "$out/SRPMS" {} +
	log "results in ${out#/}:"
	(cd "$out" && find . -name '*.rpm' | sort | sed 's/^\.\//    /' >&2)
}
