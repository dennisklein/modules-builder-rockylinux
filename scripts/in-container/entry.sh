#!/bin/bash
# entry.sh STEP [ARGS...]: common setup inside every container, then run
# /src/scripts/in-container/STEP.sh.
set -euo pipefail

# shellcheck source=../lib.sh
. /src/scripts/lib.sh
load_config /src

if [[ -s /run/builder-ca.crt ]]; then
	cp /run/builder-ca.crt /etc/pki/ca-trust/source/anchors/builder-ca.crt
	update-ca-trust
fi

# Hand files written as root back to the calling user, but only if container
# uids are host uids. With rootless podman/docker or userns remapping, root in
# here already is the calling user (or a subuid, where chown would be wrong).
if [[ -n ${OWNER:-} ]] && [[ $(awk '{ print $1, $2, $3 }' /proc/self/uid_map) == "0 0 4294967295" ]]; then
	trap 'chown -R "$OWNER" /sources /build /repo /keys 2>/dev/null || true' EXIT
fi

step=${1:?usage: entry.sh STEP [ARGS...]}
shift
"/src/scripts/in-container/$step.sh" "$@"
