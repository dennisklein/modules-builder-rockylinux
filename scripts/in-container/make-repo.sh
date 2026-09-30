#!/bin/bash
# make-repo.sh: publish build results and the verified Whamcloud e2fsprogs
# into the output tree (/repo = OUT_DIR), then sign and index it.
#
# - Published files are never replaced by a rebuild: rollbacks keep working
#   and a NEVRA never changes content. Bump SITE_RELEASE_SUFFIX to publish
#   a rebuild. Only KEEP=N removes old versions.
# - Metadata depends only on the package set (fixed revision/timestamps, no
#   sqlite), so an unchanged set yields byte-identical repodata, and
#   repomd.xml.asc is only renewed when repomd.xml changes.
# - Signed mode (GPG_KEY_ID set): every package, ours and Whamcloud's
#   (which are unsigned upstream), is signed with our key before it is
#   published; packages lacking our signature are (re-)signed in place.
set -euo pipefail
# shellcheck source=../lib.sh
. /src/scripts/lib.sh
load_config /src
# shellcheck source=signlib.sh
. /src/scripts/in-container/signlib.sh

root=/repo/$EL_TAG
bin_repo=$root/$ARCH
src_repo=$root/SRPMS
e2fs_repo=$root/e2fsprogs-wc/$ARCH
repos=("$bin_repo" "$src_repo" "$e2fs_repo")
for dir in "${repos[@]}"; do mkdir -p "$dir/Packages"; done

setup_signing
added=0

# publish RPM REPODIR: copy RPM in unless that file name is already published.
publish() {
	local rpm=$1 dir=$2 name=${1##*/}
	local tmp=$dir/Packages/.$name.tmp
	if [[ -e $dir/Packages/$name ]]; then
		# DRBD's SRPM has the same name for every kernel; say so if a build
		# carried different sources (e.g. a committed compat patch).
		if [[ $name == *.src.rpm ]] &&
			[[ $(rpm -qpl "$rpm" 2>/dev/null) != "$(rpm -qpl "$dir/Packages/$name" 2>/dev/null)" ]]; then
			warn "${rpm#/} has other sources than the published $name; keeping the published one"
		fi
		return 0
	fi
	cp "$rpm" "$tmp"
	if ((SIGNING)); then sign_rpms "$tmp"; fi
	mv "$tmp" "$dir/Packages/$name"
	log "added ${dir#/repo/}/Packages/$name"
	added=$((added + 1))
}

# Build results live in build/rpms/<component>/<kernel or "all">/. Only
# kernels still in KVERS are published, so pruned builds do not come back.
declare -A wanted=([all]=1)
for k in $KVERS; do wanted[$k]=1; done
shopt -s nullglob
for build in /build/rpms/*/*/; do
	build=${build%/}
	if [[ -z ${wanted[${build##*/}]:-} ]]; then
		log "ignoring ${build#/} (kernel not in KVERS)"
		continue
	fi
	for rpm in "$build"/RPMS/*.rpm; do
		case ${rpm##*/} in
		*-debuginfo-*.rpm | *-debugsource-*.rpm)
			[[ $PUBLISH_DEBUGINFO == yes ]] || continue ;;
		esac
		publish "$rpm" "$bin_repo"
	done
	for rpm in "$build"/SRPMS/*.src.rpm; do
		publish "$rpm" "$src_repo"
	done
done
shopt -u nullglob

# Whamcloud e2fsprogs: exactly the configured files, re-verified.
while read -r sum file; do
	[[ -n $sum ]] || continue
	src=/sources/e2fsprogs/$file
	[[ -f $src ]] || die "missing sources/e2fsprogs/$file; run 'make fetch'"
	verify_sha256 "$src" "$sum"
	publish "$src" "$e2fs_repo"
done <<<"$E2FSPROGS_FILES"
log "$added packages added"

# Signed mode on a tree that has unsigned (dev mode) or foreign-key packages.
if ((SIGNING)); then
	unsigned=()
	for dir in "${repos[@]}"; do
		for rpm in "$dir"/Packages/*.rpm; do
			[[ -e $rpm ]] || continue
			signed_by_us "$rpm" || unsigned+=("$rpm")
		done
	done
	if ((${#unsigned[@]})); then
		warn "signing ${#unsigned[@]} published packages that lack our signature"
		sign_rpms "${unsigned[@]}"
	fi
fi

# KEEP=N: keep the N newest versions of each package name. Packages built for
# a kernel that is still listed in KVERS are never removed; the kernel appears
# as "_<kmp>-" in kmod-drbd's file name and as ".k<kmp>." in Lustre's.
prune() {
	local dir=$1 path k keep old
	local -a protect=()
	for k in $KVERS; do protect+=("$(kmp_kver "$k")"); done
	old=$(dnf -q repomanage --old --keep "$KEEP" "$dir")
	while read -r path; do
		[[ -n $path ]] || continue
		keep=0
		for k in "${protect[@]}"; do
			case ${path##*/} in *"_$k-"* | *".k$k."*) keep=1 ;; esac
		done
		if ((keep)); then continue; fi
		log "pruning ${path#/repo/}"
		rm -f "$path"
	done <<<"$old"
}

# prune_srpms: remove source packages that no published binary package was
# built from any more (DRBD's SRPM name carries no kernel, so KEEP per name
# would not fit).
prune_srpms() {
	local rpm
	local -A used=()
	for rpm in "$bin_repo"/Packages/*.rpm; do
		[[ -e $rpm ]] || continue
		used[$(rpm -qp --qf '%{SOURCERPM}' "$rpm" 2>/dev/null)]=1
	done
	for rpm in "$src_repo"/Packages/*.src.rpm; do
		[[ -e $rpm ]] || continue
		if [[ -z ${used[${rpm##*/}]:-} ]]; then
			log "pruning ${rpm#/repo/} (no published package built from it)"
			rm -f "$rpm"
		fi
	done
}

# index REPODIR: createrepo_c with metadata that depends only on the packages.
index() {
	local dir=$1 rev
	rev=$(find "$dir/Packages" -name '*.rpm' -printf '%T@\n' | sort -n | tail -n1)
	rev=${rev%.*}
	createrepo_c --quiet --update --no-database --revision "${rev:-0}" \
		--set-timestamp-to-revision "$dir"
}

if [[ -n ${KEEP:-} ]]; then
	[[ $KEEP =~ ^[1-9][0-9]*$ ]] || die "KEEP must be a positive number"
fi
for dir in "${repos[@]}"; do
	index "$dir"
	if [[ -n ${KEEP:-} ]]; then
		if [[ $dir == "$src_repo" ]]; then prune_srpms; else prune "$dir"; fi
		index "$dir"
	fi
	if ((SIGNING)); then
		sign_repomd "$dir"
	else
		rm -f "$dir/repodata/repomd.xml.asc"
	fi
done

render_repo_file "$REPO_PUBLIC_BASEURL" | write_if_changed "/repo/$REPO_ID.repo"
if ((SIGNING)); then
	pubkey=$(gpg --batch --armor --export "$GPG_KEY_ID")
	[[ -n $pubkey ]] || die "could not export the public key of $GPG_KEY_ID"
	printf '%s\n' "$pubkey" | write_if_changed "/repo/RPM-GPG-KEY-$REPO_ID"
else
	rm -f "/repo/RPM-GPG-KEY-$REPO_ID"
	cat >&2 <<'EOF'

  ********************************************************************
  *  UNSIGNED DEV MODE: GPG_KEY_ID is empty. Packages and metadata   *
  *  are not signed and the .repo file sets gpgcheck=0. Do not       *
  *  publish this tree for production hosts.                         *
  ********************************************************************

EOF
fi
log "repository ready in OUT_DIR ($EL_TAG)"
