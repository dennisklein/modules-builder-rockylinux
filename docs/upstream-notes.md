# Upstream build notes

Facts about the upstream build systems this builder relies on, verified on
2026-09-30 by reading the sources at their release tags (GitHub mirrors:
`LINBIT/drbd` tag `drbd-9.3.4`, `LINBIT/drbd-utils` tags `v9.34.0`/`v9.35.0`,
`lustre/lustre-release` tag `v2_17_0`, `elrepo/packages`). Release tarballs,
the Whamcloud SRPM and the Rocky trees could not be downloaded from the
environment the notes were written in, so anything that only the tarball or
SRPM can show is marked "to verify".

## Base image and Rocky trees

- `docker.io/rockylinux/rockylinux:9.7` resolves to
  `sha256:53f4c6dcb34e1403bd93207351f0af9a593610faeb7165cb8a037346765199b0`
  (created 2025-11-23, amd64, `/etc/rocky-release` = 9.7).
- Inside that image `%{dist}` is `.el9` and `$releasever` is `9`. The stock
  repo files use `mirrorlist=https://mirrors.rockylinux.org/...` with
  `$releasever`, which today resolves to 9.8. They must be replaced by
  explicit `baseurl=` entries for the 9.7 trees.
- Rocky tree layout (same for `dl.rockylinux.org/vault/rocky/9.7` and, per the
  old role, `lxrpt8.gsi.de/rocky/9.7`):
  `<base>/{BaseOS,AppStream,CRB}/x86_64/os/`,
  `<base>/BaseOS/x86_64/debug/tree/`, `<base>/BaseOS/source/tree/`.

## DRBD 9.3.4 kernel module

- `drbd-kernel.spec` is already a kmodtool spec: it calls
  `%kernel_module_package -n drbd -v <version>_<kernel>`, so the result is
  `kmod-drbd` with weak-modules scriptlets and ksym requires from the stock EL9
  `kernel-rpm-macros`. No spec of our own is needed.
- Kernel identity is in Version: `9.3.4_5.14.0_611.55.1` (the kernel release
  with `-` turned into `_` and `.el9_7.x86_64` stripped). `Release: 1` is a
  literal with no `%{?dist}`, so the site suffix has to be patched into the
  spec's `Release:` line.
- Files: `/lib/modules/<kver>/extra/drbd/*.ko`, `/etc/depmod.d/drbd.conf`
  (overrides that prefer `extra/drbd` and `weak-updates/drbd`), and LINBIT's
  Secure Boot certificate `/etc/pki/linbit/SECURE-BOOT-KEY-linbit.com.der`
  (irrelevant for modules we build, but harmless).
- Modules (`drbd/Kbuild.drbd`): `drbd.ko`, `drbd_transport_tcp.ko` and
  `drbd_transport_lb-tcp.ko` are always built. `drbd_transport_rdma.ko` is
  built only if the kernel config has `CONFIG_INFINIBAND_ADDR_TRANS`. A
  compat `handshake` module is added only when the generated `compat.h`
  defines `COMPAT_HAVE_TLS_TX_RX`.
- MLNX_OFED/DOCA-OFED: `--define "ofed_kernel_dir /usr/src/ofa_kernel/..."`
  builds against OFED headers and appends `.ofed.<ver>` to the version.
- The spec's `Requires: drbd-utils >= 9.27.0` sits on the main package, which
  has no `%files` and is never emitted. `kmod-drbd` does not pull in
  userland; install drbd-utils explicitly.
- **`make kmp-rpm` pitfalls.** It depends on the `tgz` target, which re-tars
  the tree and checks changelogs. It forwards `kernel_version` to rpmbuild
  only when `KVER` was *derived* from `KDIR` (make origin `file`). Passing
  `KVER=` on the command line silently drops it, and the spec then picks
  the newest installed `kernel-devel`. The builder therefore calls
  `rpmbuild -bb drbd-kernel.spec` directly with
  `--define "kernel_version <kver>.<arch>"`.

### Compat patches and SPAAS (corrects the hand-off)

- The service is `SPAAS_URL=https://spaas.drbd.io` (HTTPS), not
  `drbd.io:2020`. It is used only when the build runs from a release tarball
  (never from a git checkout), only when no suitable local `spatch` exists,
  and only with `SPAAS=true`, which is the default. `SPAAS=false` in the
  environment disables it; the Makefile uses `?=` and `export`.
- Cache: `drbd/drbd-kernel-compat/cocci_cache/<md5 of compat.h>/compat.patch`.
  The key is the md5 of the `compat.h` generated from compile tests against
  the target kernel, not the kernel release string. A new kernel whose
  feature set matches a cached entry reuses it without network access.
- Reproducible plan: build with `SPAAS=false` after copying
  `patches/drbd-compat/<md5>/{compat.h,compat.patch}` into the cache. If the
  cache misses, run once with SPAAS or a local Coccinelle (>= 1.1.1, suggested
  1.2), then commit the generated entry. Fail with a clear message if none of
  these is available.

## drbd-utils

- Newest tag: `v9.35.0` (2026-09-30). The previous one is `v9.34.0`
  (2026-03-17).
- API compatibility with DRBD 9.3.4: the `drbd-headers` submodule in utils
  9.35.0 (`bdf8650`) is an ancestor of the one in drbd 9.3.4 (`778d527`), two
  commits apart. Commit `f275314` reorders netlink attribute declarations
  without changing any attribute type. Commit `778d527` adds the metadata
  feature flag `DRBD_MDFF_BITMAP_AUTHORITATIVE`, and drbdmeta 9.35.0 clears
  feature bits it does not know when it writes metadata (`DRBD_MD_FEATURES`
  mask). That is the designed forward-compatibility path. LINBIT's
  announcement could not be read to confirm this (to verify).
- Spec (`drbd.spec.in`, which the tarball should ship generated as
  `drbd.spec`; to verify) yields `drbd` (meta), `drbd-utils`, `drbd-udev`,
  `drbd-pacemaker`, `drbd-bash-completion`, `drbd-selinux` (auto on EL >= 8),
  and `drbd-man-ja`. Bconds: `manual`, `udev`, `pacemaker`, `bashcompletion`,
  `84support`, `drbdmon` (on), and `prebuiltman`, `coverage`, `selinux` (off).
  Use `--with prebuiltman` so the prebuilt man pages from the tarball are
  used and xsltproc/docbook/po4a are not needed. `Release: 1%{?dist}` is a
  literal, so the suffix has to be patched in.

## Lustre 2.17.0 server

- Bconds (`lustre.spec.in`): on by default are `servers`, `ldiskfs`,
  `lustre_tests`, `lustre_utils`, `lustre_iokit`, `lustre_modules`,
  `manpages`, `shared`, `static`, `mpi`, `o2ib`, and `l_getsepol`. Off by
  default are `zfs`, `gss`, `gss_keyring`, `systemd`, `kabi`,
  `multiple_lnds`, `mofed`, `kfi`, and `gni`.
- Kernel selection: `--define "kdir /usr/src/kernels/<kver>"` makes the spec
  read the kernel release from `<kdir>/include/generated/utsrelease.h`, which
  overrides the `kver` baked into Whamcloud's SRPM (their
  `5.14.0-611.13.1_lustre.el9`). The spec then sets `kernel_version` for
  kmodtool itself.
- **Kernel identity is not encoded on RHEL.** `kmod-lustre` has Version
  `2.17.0` and Release `%{release_id}%{?dist}`. `release_id` can be
  overridden with `--define "release_id ..."`, and the builder puts kernel
  and site suffix there, which also applies to the userland packages of the
  same run.
- Packages with servers+ldiskfs on EL9: `lustre`, `kmod-lustre`,
  `kmod-lustre-osd-ldiskfs`, `lustre-osd-ldiskfs-mount`,
  `lustre-resource-agents`, `lustre-devel`, `kmod-lustre-devel`, plus
  `lustre-iokit`, `lustre-tests` and `kmod-lustre-tests` when enabled. 2.17
  also builds a new in-memory OSD, `kmod-lustre-osd-wbcfs` and
  `lustre-osd-wbcfs-mount`, for every non-SUSE server build, with no bcond to
  turn it off. `lustre` requires "an `lustre-osd` and an `lustre-osd-mount`",
  and either OSD satisfies that, so hosts should install the ldiskfs pair
  explicitly.
- Module paths: `/lib/modules/<kver>/extra/lustre/...` and
  `/lib/modules/<kver>/extra/lustre-osd-ldiskfs/fs/{ldiskfs,osd_ldiskfs}.ko`.
  o2iblnd stays in `kmod-lustre` unless `multiple_lnds` is enabled.
- Dependencies worth knowing: `BuildRequires: kernel >= 3.10`, so the build
  root needs a `kernel` package, not only `kernel-devel`.
  `kmod-lustre-osd-ldiskfs` has `Requires: ldiskfsprogs >= 1.44.3.wc1`, which
  only Whamcloud's e2fsprogs provides, so the e2fsprogs repo is required for
  the ldiskfs OSD. `lustre-tests` pulls in `openmpi-devel` (bcond `mpi`). The
  spec sets `optflags -g -O2 -Werror`.
- MLNX_OFED/DOCA-OFED: `--with mofed` plus `--with-o2ib=<ofa_kernel dir>` in
  `configure_args`.

### ldiskfs (patchless, stock kernel)

- Series selection (`config/lustre-build-ldiskfs.m4`): for RHEL kernels it is
  keyed on `RHEL_RELEASE_NO` from the kernel headers. `97` selects
  `ldiskfs-5.14-rhel9.7.series`, which has 45 patches. `LDISKFS_SERIES=<file>`
  in the environment overrides the choice.
- ext4 source (`LB_EXT4_SOURCE_PATH`) is searched in order at
  `$LINUX/fs/ext4`, then `$LINUX/../../debug/*/linux-<kver without arch>*`,
  then `/usr/src/debug/*/linux-<kver without arch>*`. The last one is where
  `kernel-debuginfo-common-x86_64` installs, so no copying into
  `/usr/src/kernels` is needed (the old role used the first path). There is
  no override: `EXT4_SRC_DIR` is always assigned.
- **Silent failure mode:** if the ext4 source is not found, configure only
  warns and disables ldiskfs, and the build still succeeds without
  `kmod-lustre-osd-ldiskfs`. The builder must assert that the package exists
  and contains `ldiskfs.ko` and `osd_ldiskfs.ko`.
