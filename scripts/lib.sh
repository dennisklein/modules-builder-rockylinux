# shellcheck shell=bash
# Helpers shared by the host-side entry point and the in-container steps.

log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# load_config ROOT
# Source ROOT/config.env, then the optional untracked ROOT/config.local.env,
# and derive the values every script needs.
load_config() {
	local root=$1
	[[ -r $root/config.env ]] || die "config not found: $root/config.env"
	# shellcheck source=../config.env
	. "$root/config.env"
	if [[ -r $root/config.local.env ]]; then
		# shellcheck disable=SC1091
		. "$root/config.local.env"
	fi

	local v
	for v in EL_RELEASE ARCH KVERS BASE_IMAGE ROCKY_BASEURL SITE_RELEASE_SUFFIX \
		REPO_ID REPO_NAME REPO_PUBLIC_BASEURL OUT_DIR; do
		[[ -n ${!v:-} ]] || die "config: $v is empty"
	done
	[[ $SITE_RELEASE_SUFFIX =~ ^[A-Za-z0-9.]+$ ]] ||
		die "config: SITE_RELEASE_SUFFIX may only contain letters, digits and dots"

	local k
	for k in $KVERS; do
		[[ $k =~ ^[0-9][^-]*-[^-]+$ && $k != *".$ARCH" ]] ||
			die "config: KVERS entry '$k' must be a kernel release without arch, e.g. 5.14.0-611.55.1.el9_7"
	done

	EL_MAJOR=${EL_RELEASE%%.*}
	EL_TAG=el$EL_RELEASE
	GPG_KEY_ID=${GPG_KEY_ID:-}
	export EL_MAJOR EL_TAG
}

# kmp_kver KVER -> 5.14.0_611.55.1
# The kernel as DRBD's spec encodes it in the kmod Version: dist tag
# stripped, dashes turned into underscores.
kmp_kver() {
	local k=$1
	k=${k%."$ARCH"}
	k=$(sed -E 's/\.el[0-9_]+$//' <<<"$k")
	printf '%s\n' "${k//-/_}"
}

# drbd_release -> Release of kmod-drbd (the spec appends %{?dist}).
drbd_release() { printf '1.%s\n' "$SITE_RELEASE_SUFFIX"; }

# lustre_release_id KVER -> 1.k5.14.0_611.55.1.gsi1
# Lustre's spec does not encode the kernel on RHEL; we put it into release_id,
# which becomes Release (plus %{?dist}) of every package of that build.
lustre_release_id() { printf '1.k%s.%s\n' "$(kmp_kver "$1")" "$SITE_RELEASE_SUFFIX"; }

# verify_sha256 FILE EXPECTED
verify_sha256() {
	local f=$1 want=$2 got
	got=$(sha256sum "$f" | cut -d' ' -f1)
	[[ -n $want ]] || die "no sha256 configured for ${f##*/} (computed: $got)"
	[[ $got == "$want" ]] || die "sha256 mismatch for ${f##*/}: expected $want, got $got"
}

# write_if_changed FILE: replace FILE with stdin only if the content differs,
# so unchanged files keep their mtime (and rsync leaves them alone).
write_if_changed() {
	local tmp=$1.tmp
	cat >"$tmp"
	if cmp -s "$tmp" "$1"; then rm -f "$tmp"; else mv "$tmp" "$1"; fi
}

# normalize_url URL: collapse duplicate slashes in the path (LINBIT's
# announcements use https://pkg.linbit.com//downloads/...).
normalize_url() { sed -E 's#([^:/])/{2,}#\1/#g' <<<"$1"; }

# render_repo_file BASEURL: the dnf .repo file for the published tree at
# BASEURL. The e2fsprogs section is disabled by default: it replaces the
# distribution's e2fsprogs, which only Lustre servers want.
render_repo_file() {
	local base=${1%/} check=0 key=
	if [[ -n $GPG_KEY_ID ]]; then
		check=1
		key="gpgkey=$base/RPM-GPG-KEY-$REPO_ID"
	fi
	cat -s <<EOF
# $REPO_NAME, $EL_TAG only. Rendered from config.env.
[$REPO_ID]
name=$REPO_NAME ($EL_TAG)
baseurl=$base/$EL_TAG/\$basearch/
enabled=1
gpgcheck=$check
repo_gpgcheck=$check
$key

[$REPO_ID-source]
name=$REPO_NAME ($EL_TAG, sources)
baseurl=$base/$EL_TAG/SRPMS/
enabled=0
gpgcheck=$check
repo_gpgcheck=$check
$key

# Whamcloud's e2fsprogs replaces the distribution's; enable on Lustre servers only.
[$REPO_ID-e2fsprogs]
name=$REPO_NAME ($EL_TAG, Whamcloud e2fsprogs)
baseurl=$base/$EL_TAG/e2fsprogs-wc/\$basearch/
enabled=0
gpgcheck=$check
repo_gpgcheck=$check
$key
EOF
}
