# shellcheck shell=bash
# Signing helpers for make-repo.sh. The key is handed in by scripts/builder as
# a read-only GnuPG home (/run/gnupg-home) or an armored secret key
# (/run/gpg-key.asc), optionally with a passphrase file (/run/gpg-passphrase).
# It is copied into a private GNUPGHOME inside the throwaway container.

# shellcheck disable=SC2034 # read by make-repo.sh
SIGNING=0
SIGNING_FPRS=()
GPG_EXTRA=()

setup_signing() {
	[[ -n $GPG_KEY_ID ]] || return 0
	export GNUPGHOME=/tmp/gnupg
	install -d -m 700 "$GNUPGHOME"
	# --batch: rpm's own gpg command line lacks it; without it a key with a
	# passphrase but no GPG_PASSPHRASE_FILE would prompt instead of failing.
	GPG_EXTRA=(--batch --pinentry-mode loopback)
	if [[ -s /run/gpg-passphrase ]]; then GPG_EXTRA+=(--passphrase-file /run/gpg-passphrase); fi
	if [[ -d /run/gnupg-home ]]; then
		tar -C /run/gnupg-home --exclude='S.*' --exclude='*.lock' -cf - . | tar -C "$GNUPGHOME" -xf -
	fi
	if [[ -s /run/gpg-key.asc ]]; then
		gpg --batch -q "${GPG_EXTRA[@]}" --import /run/gpg-key.asc
	fi
	# Primary key and subkeys: rpm and gpg may sign with either.
	mapfile -t SIGNING_FPRS < <(gpg --batch --with-colons --list-secret-keys "$GPG_KEY_ID" 2>/dev/null |
		awk -F: '$1 == "fpr" { print tolower($10) }')
	((${#SIGNING_FPRS[@]})) ||
		die "secret key $GPG_KEY_ID not available: set GNUPGHOME or GPG_PRIVATE_KEY_FILE (see README)"
	SIGNING=1
}

# ours KEYID_OR_FPR: true if it identifies our primary key or a subkey.
ours() {
	local f
	[[ -n $1 ]] || return 1
	for f in "${SIGNING_FPRS[@]}"; do
		[[ $f == *"${1,,}" ]] && return 0
	done
	return 1
}

# signed_by_us RPM: true if RPM carries a signature from our key.
signed_by_us() {
	local id
	id=$(rpm -qp --qf '%|DSAHEADER?{%{DSAHEADER:pgpsig}}:{%{RSAHEADER:pgpsig}}|\n' "$1" 2>/dev/null |
		sed -nE 's/.*Key ID ([0-9a-f]+).*/\1/p' || true)
	ours "$id"
}

# sign_rpms RPM...: add our signature (replaces any existing one).
sign_rpms() {
	rpmsign --addsign --define "_gpg_name $GPG_KEY_ID" \
		--define "_gpg_sign_cmd_extra_args ${GPG_EXTRA[*]}" "$@" >/dev/null
}

# sign_repomd REPODIR: detached armored signature for repo_gpgcheck, renewed
# only when repomd.xml changed or the signature is not from our key.
sign_repomd() {
	local md=$1/repodata/repomd.xml fpr
	if [[ -f $md.asc ]]; then
		fpr=$(gpg --batch --status-fd 1 --verify "$md.asc" "$md" 2>/dev/null |
			awk '$2 == "VALIDSIG" { print tolower($3) }' || true)
		if ours "$fpr"; then return 0; fi
	fi
	gpg --batch --yes -q "${GPG_EXTRA[@]}" -u "$GPG_KEY_ID" --armor --detach-sign -o "$md.asc" "$md"
}
