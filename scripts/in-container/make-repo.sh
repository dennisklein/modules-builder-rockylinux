#!/bin/bash
# make-repo.sh: publish build results into the output tree (/repo = OUT_DIR)
# and (re)generate its metadata.
#
# Published files are immutable: a package whose file name already exists is
# never replaced, so rollbacks keep working and clients never see a package
# change under a known NEVRA. Metadata is generated deterministically (fixed
# revision/timestamps, no sqlite), so an unchanged package set yields
# byte-identical repodata.
set -euo pipefail
# shellcheck source=../lib.sh
. /src/scripts/lib.sh
load_config /src

root=/repo/$EL_TAG
bin_repo=$root/$ARCH
src_repo=$root/SRPMS
mkdir -p "$bin_repo/Packages" "$src_repo/Packages"

added=0
kept=0

# publish RPM REPODIR
publish() {
	local rpm=$1 dir=$2 name=${1##*/}
	if [[ -e $dir/Packages/$name ]]; then
		kept=$((kept + 1))
		return 0
	fi
	cp "$rpm" "$dir/Packages/.$name.tmp"
	mv "$dir/Packages/.$name.tmp" "$dir/Packages/$name"
	log "added ${dir#/repo/}/Packages/$name"
	added=$((added + 1))
}

shopt -s nullglob
for rpm in /build/rpms/*/*/RPMS/*.rpm; do
	case ${rpm##*/} in
	*-debuginfo-*.rpm | *-debugsource-*.rpm)
		[[ $PUBLISH_DEBUGINFO == yes ]] || continue ;;
	esac
	publish "$rpm" "$bin_repo"
done
for rpm in /build/rpms/*/*/SRPMS/*.src.rpm; do
	publish "$rpm" "$src_repo"
done
shopt -u nullglob
log "$added packages added, $kept already published"

# index REPODIR: createrepo_c with metadata that depends only on the packages.
index() {
	local dir=$1 rev
	rev=$(find "$dir/Packages" -name '*.rpm' -printf '%T@\n' | sort -n | tail -n1)
	rev=${rev%.*}
	createrepo_c --quiet --update --no-database --revision "${rev:-0}" \
		--set-timestamp-to-revision "$dir"
}

for dir in "$bin_repo" "$src_repo"; do
	index "$dir"
done

render_repo_file "$REPO_PUBLIC_BASEURL" >"/repo/$REPO_ID.repo"
if [[ -z $GPG_KEY_ID ]]; then
	cat >&2 <<'EOF'

  ********************************************************************
  *  UNSIGNED DEV MODE: GPG_KEY_ID is empty. Packages and metadata   *
  *  are not signed and the .repo file sets gpgcheck=0. Do not       *
  *  publish this tree for production hosts.                         *
  ********************************************************************

EOF
fi
log "repository ready in OUT_DIR ($EL_TAG)"
