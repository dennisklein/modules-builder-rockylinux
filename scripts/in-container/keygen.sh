#!/bin/bash
# keygen.sh: create a new repository signing key in /keys (the host's KEYDIR).
#   /keys/gnupg/                  GnuPG home holding the key (use as GNUPGHOME)
#   /keys/secret-key.asc          armored secret key, e.g. for a CI secret
#   /keys/RPM-GPG-KEY-<repo-id>   public key
# The key has no passphrase unless GPG_PASSPHRASE_FILE was given.
set -euo pipefail
# shellcheck source=../lib.sh
. /src/scripts/lib.sh
load_config /src

uid=${KEY_UID:-"$REPO_NAME <$REPO_ID@localhost>"}
export GNUPGHOME=/keys/gnupg
[[ ! -e $GNUPGHOME ]] || die "KEYDIR already contains a gnupg/ directory; refusing to overwrite"
install -d -m 700 "$GNUPGHOME"

pass=(--passphrase '')
if [[ -s /run/gpg-passphrase ]]; then pass=(--passphrase-file /run/gpg-passphrase); fi
log "generating RSA 4096 signing key for: $uid"
gpg --batch -q --pinentry-mode loopback "${pass[@]}" --quick-gen-key "$uid" rsa4096 sign never
fpr=$(gpg --batch --with-colons --list-keys "$uid" | awk -F: '$1 == "fpr" { print $10; exit }')

gpg --batch --armor --export "$fpr" >"/keys/RPM-GPG-KEY-$REPO_ID"
(
	umask 077
	gpg --batch --pinentry-mode loopback "${pass[@]}" --armor --export-secret-keys "$fpr" >/keys/secret-key.asc
)
cat >&2 <<EOF

New signing key: $fpr
  GnuPG home:  KEYDIR/gnupg   (revocation certificate in gnupg/openpgp-revocs.d/)
  secret key:  KEYDIR/secret-key.asc
  public key:  KEYDIR/RPM-GPG-KEY-$REPO_ID

Put this into config.env:
  GPG_KEY_ID=$fpr
and point the build at the key with GNUPGHOME=KEYDIR/gnupg or
GPG_PRIVATE_KEY_FILE=KEYDIR/secret-key.asc. Never commit KEYDIR.
EOF
