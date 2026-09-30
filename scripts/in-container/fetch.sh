#!/bin/bash
# fetch.sh: download every configured source into /sources and verify it
# against the sha256 from the config. Existing verified files are kept.
set -euo pipefail
# shellcheck source=../lib.sh
. /src/scripts/lib.sh
load_config /src

# fetch URL SHA256 DESTDIR
fetch() {
	local url dest sum=$2 dir=$3
	url=$(normalize_url "$1")
	dest=$dir/${url##*/}
	mkdir -p "$dir"
	if [[ -f $dest ]]; then
		if [[ $(sha256sum "$dest" | cut -d' ' -f1) == "$sum" ]]; then
			return 0
		fi
		warn "discarding ${dest#/sources/}: checksum does not match the config"
		rm -f "$dest"
	fi
	log "fetching $url"
	curl -fsSL --retry 3 --proto '=https,http' -o "$dest.part" "$url"
	if ! (verify_sha256 "$dest.part" "$sum"); then
		rm -f "$dest.part"
		die "refusing ${url##*/}"
	fi
	mv "$dest.part" "$dest"
}

fetch "$DRBD_URL" "${DRBD_SHA256:-}" /sources
