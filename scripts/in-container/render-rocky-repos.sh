#!/bin/bash
# render-rocky-repos.sh BASEURL GPGKEY
# Replace every repo file with explicit baseurl= entries for one frozen Rocky
# minor release. No mirrorlists: nothing may resolve to a newer minor release.
set -euo pipefail

base=${1:?usage: render-rocky-repos.sh BASEURL GPGKEY}
gpgkey=${2:?usage: render-rocky-repos.sh BASEURL GPGKEY}
base=${base%/}

rm -f /etc/yum.repos.d/*.repo

section() { # id name path
	cat <<EOF
[$1]
name=$2
baseurl=$base/$3
enabled=1
gpgcheck=1
gpgkey=$gpgkey
countme=0

EOF
}

# $basearch is for dnf to expand, not the shell.
# shellcheck disable=SC2016
{
	section pinned-baseos "Rocky BaseOS ($base)" 'BaseOS/$basearch/os/'
	section pinned-appstream "Rocky AppStream ($base)" 'AppStream/$basearch/os/'
	section pinned-crb "Rocky CRB ($base)" 'CRB/$basearch/os/'
	section pinned-baseos-debug "Rocky BaseOS debuginfo ($base)" 'BaseOS/$basearch/debug/tree/'
} >/etc/yum.repos.d/pinned-rocky.repo
