# kmod builder: DRBD and Lustre server modules for Rocky Linux 9.7

This repository builds binary RPMs of the DRBD 9 and Lustre server kernel
modules, plus matching userland, for explicitly pinned Rocky Linux kernels. It
lays them out as a complete, location-independent dnf repository that can be
copied unchanged to a plain static HTTP server. Storage servers install
signed, kABI-tracking `kmod-*` packages (the RHEL weak-modules model) with
`dnf` and never compile anything.

Everything runs in throwaway containers from a Rocky 9.7 image pinned by
digest, with repo files that point only at the frozen 9.7 trees. The build
never derives the kernel from `uname -r` or the build host.

| Component | Version | Source |
|---|---|---|
| DRBD kernel module | 9.3.4 | LINBIT release tarball, upstream `drbd-kernel.spec` |
| drbd-utils | 9.35.0 | LINBIT release tarball |
| Lustre server (patchless ldiskfs, inbox o2ib, no ZFS) | 2.17.0 | Whamcloud el9.7 SRPM |
| e2fsprogs (mirrored unchanged, separate repo) | 1.47.3-wc2 | Whamcloud el9 RPMs |
| Kernel | 5.14.0-611.55.1.el9_7 | Rocky 9.7 vault |

Background on how the upstream build systems behave is in
[docs/upstream-notes.md](docs/upstream-notes.md).

## What you get

`make repo` produces this tree in `OUT_DIR` (default `out/repo`):

```
out/repo/
├── RPM-GPG-KEY-gsi-kmods          # public key (signed mode only)
├── gsi-kmods.repo                 # ready-to-use dnf repo file
└── el9.7/
    ├── x86_64/                    # our builds: kmods + matching userland
    │   ├── Packages/
    │   └── repodata/
    ├── SRPMS/                     # the exact sources we built from
    │   ├── Packages/
    │   └── repodata/
    └── e2fsprogs-wc/x86_64/       # Whamcloud e2fsprogs, separate repo
        ├── Packages/
        └── repodata/
```

Main repository, per kernel in `KVERS` (the example is for 611.55.1):

| Package | Notes |
|---|---|
| `kmod-drbd-9.3.4_5.14.0_611.55.1-1.gsi1.el9` | `drbd`, `drbd_transport_tcp`, `drbd_transport_lb-tcp`, `drbd_transport_rdma` |
| `kmod-lustre-2.17.0-1.k5.14.0_611.55.1.gsi1.el9` | LNet (`ksocklnd`, `ko2iblnd`) and all Lustre server/client modules |
| `kmod-lustre-osd-ldiskfs-…` | `ldiskfs`, `osd_ldiskfs` |
| `lustre-…`, `lustre-osd-ldiskfs-mount-…`, `lustre-resource-agents-…` | userland from the same rpmbuild run |
| `lustre-iokit-…` | `LUSTRE_WITH_IOKIT=yes` (default) |
| `lustre-tests-…`, `kmod-lustre-tests-…` | only with `LUSTRE_WITH_TESTS=yes` |
| `kmod-lustre-osd-wbcfs-…`, `lustre-osd-wbcfs-mount-…` | Lustre 2.17's in-memory OSD, always built by the spec; not needed |
| `lustre-devel-…`, `kmod-lustre-devel-…` | headers and `Module.symvers` |

Kernel independent: `drbd-utils-9.35.0-1.gsi1.el9` with `drbd` (meta),
`drbd-udev`, `drbd-pacemaker`, `drbd-selinux`, `drbd-bash-completion` and
`drbd-man-ja`.

How versions are formed:

- Every package we build carries `SITE_RELEASE_SUFFIX` (`gsi1`) in its
  Release. An upstream or hand-built package of the same version therefore
  never has the same NEVR. Ours sorts higher: `1.gsi1.el9` > `1` for DRBD,
  and `1.k5….gsi1.el9` > `1.el9` for Whamcloud's Lustre.
- DRBD's spec puts the kernel into the kmod Version (`9.3.4_5.14.0_611.55.1`).
- Lustre's spec does not encode the kernel on RHEL, so the builder puts it
  into `release_id` (`1.k5.14.0_611.55.1.gsi1`). That becomes the Release of
  all packages of that build, and the default in the published SRPM.

Every kmod installs only below `/lib/modules/<kver>/extra/` and has stripped
modules, `kernel(symbol) = crc` requirements, and weak-modules
`%post`/`%postun` scriptlets. dnf therefore refuses to install it on a kernel
with an incompatible ABI.

## Prerequisites

- Linux with `git`, `make`, `bash` and Podman. Rootless Podman is the
  intended setup. Docker also works; set `CONTAINER_RUNTIME=docker` if both
  are installed.
- Network access to the hosts listed under [Network access](#network-access).
- About 10 GB of disk for images, dnf cache, sources and build trees. The first
  full build from a fresh clone took 12 minutes on 4 cores; Lustre is most of it.
- `shellcheck`, only for `make lint`.

## Quick start

```sh
git clone <this repo> kmod-builder && cd kmod-builder
make repo          # builds everything; unsigned dev mode while GPG_KEY_ID is empty
make test          # verify the kmods and install everything in a fresh Rocky 9.7 container
```

`make help` lists all targets.

## Configuration

[`config.env`](config.env) is the only place where versions, checksums and
URLs live. Every script, on the host and in the containers, sources it.

| Variable | Meaning |
|---|---|
| `EL_RELEASE`, `ARCH` | target release (`9.7`) and architecture |
| `KVERS` | space-separated kernel releases without arch; one build each |
| `BASE_IMAGE` | Rocky image for builds and tests, pinned by digest |
| `ROCKY_BASEURL` | root of the frozen trees. BaseOS, AppStream, CRB, HighAvailability and the BaseOS debug tree are derived from it. Default is the Rocky vault; `http://lxrpt8.gsi.de/rocky/9.7` works if it has the same layout |
| `DRBD_*`, `DRBD_UTILS_*` | versions, tarball URLs, sha256 |
| `DRBD_ALLOW_SPAAS` | `yes` lets a DRBD build use LINBIT's spatch service (see below) |
| `LUSTRE_*` | version, SRPM URL, sha256 (from Whamcloud's `sha256sum`), iokit/tests switches |
| `E2FSPROGS_BASEURL`, `E2FSPROGS_FILES` | pinned Whamcloud directory and `sha256  file` lines |
| `SITE_RELEASE_SUFFIX` | appended to the Release of everything we build |
| `REPO_ID`, `REPO_NAME`, `REPO_PUBLIC_BASEURL` | rendered into the `.repo` file only |
| `OUT_DIR` | output tree, kept between runs |
| `PUBLISH_DEBUGINFO` | `yes` also publishes `*-debuginfo`/`*-debugsource` |
| `GPG_KEY_ID` | empty for unsigned dev mode, else the signing key's fingerprint |

Each download is checked against the sha256 in the config, and the build
fails on a mismatch. Whamcloud publishes checksums; LINBIT does not, so the
DRBD hashes were recorded on first download after comparing the tarballs with
the signed-off git tags. Whamcloud's SRPM and RPMs are unsigned upstream.

An untracked `config.local.env` next to `config.env` is sourced after it and
is meant for machine-local settings such as `OUT_DIR`. Settings that concern
only the machine running the build are environment variables:

| Variable | Meaning |
|---|---|
| `CONTAINER_RUNTIME` | `podman` (default if installed) or `docker` |
| `BUILDER_NETWORK` | network mode for all containers, e.g. `host` |
| `BUILDER_CA_BUNDLE` | CA bundle to trust inside the containers (TLS-inspecting proxy); never stored in the image |
| `http_proxy`, `https_proxy`, `no_proxy` | passed through when set |
| `GPG_PRIVATE_KEY_FILE`, `GNUPGHOME`, `GPG_PASSPHRASE_FILE` | signing key, see [Signing](#signing) |

## Building

| Target | What it does |
|---|---|
| `make image` | builds the builder image, tagged by a hash of everything that goes into it |
| `make fetch` | downloads and verifies all sources into `sources/` |
| `make drbd`, `make lustre` | builds for every kernel in `KVERS` |
| `make drbd-utils` | builds drbd-utils once |
| `make repo` | all of the above, then publishes into `OUT_DIR`, signs and indexes |
| `make verify` | checks every kmod in `OUT_DIR` (see [Verification](#verification)) |
| `make test`, `make test-http` | install tests in fresh containers, via `file://` or a local static HTTP server |
| `make prune KEEP=N` | removes old versions, see [The output repository](#the-output-repository) |
| `make shell` | shell in the builder image for debugging |
| `make clean` | removes `build/`; `sources/` and `OUT_DIR` stay |

Each build runs in a new container that installs `kernel-devel` for exactly
that kernel. Lustre also needs `kernel-debuginfo-common-x86_64`, whose ext4
sources Lustre's configure finds by itself. Build dependencies come from
`dnf builddep`. Results land in `build/rpms/<component>/<kernel>/`, logs in
`build/logs/`.

A build is skipped when its result already exists in `OUT_DIR` or `build/`,
so re-running `make repo` is cheap. `FORCE=1` rebuilds anyway, but a rebuild
never replaces a published file (see below). DRBD's SRPM has no kernel in its
name, so it is published once and shared by all kernels. If a later kernel's
build needed a committed compat patch, `make repo` warns that the published
SRPM lacks it. The patch itself is always in `patches/drbd-compat/`.

The Lustre build applies the ldiskfs patch series that configure picks from
the kernel headers (`5.14-rhel9.7.series` for any 9.7 kernel) with no fuzz.
If a patch does not apply, the build stops and prints the failing patches;
do not force them. It also asserts that `kmod-lustre-osd-ldiskfs` was
produced and contains `ldiskfs.ko` and `osd_ldiskfs.ko`, because configure
silently drops ldiskfs when it cannot find the ext4 sources.

## Network access

A build contacts only:

- the container registry of `BASE_IMAGE` (docker.io), to pull the base image;
- `ROCKY_BASEURL` (dnf inside the containers; no mirrorlists);
- `pkg.linbit.com` and `downloads.whamcloud.com`, for the configured files only.

The single optional exception is LINBIT's spatch service
(`https://spaas.drbd.io`), used only with `DRBD_ALLOW_SPAAS=yes`.

### DRBD compat patches (SPAAS)

DRBD adapts its sources to each kernel with a Coccinelle-generated
`compat.patch`, cached by the md5 of a generated `compat.h`. The release
tarball ships patches for common distribution kernels, and the 9.3.4 tarball
covers 611.55.1, so no network is needed. For a kernel it does not cover, DRBD
would silently call `https://spaas.drbd.io`. The builder turns that off
(`SPAAS=false`) and fails with a clear message instead. To add such a kernel:

1. Build once with `DRBD_ALLOW_SPAAS=yes` in `config.local.env`, or with a
   local Coccinelle >= 1.1.1 in the image.
2. The generated entry is saved to `patches/drbd-compat/<md5>/`. Commit it.
3. Later builds inject it into the SRPM and the cache, and run offline and
   deterministically.

## Signing

In signed mode (`GPG_KEY_ID` set), `make repo` signs every RPM with
`rpmsign --addsign`. That includes Whamcloud's e2fsprogs, which are unsigned
upstream; we publish them after verifying Whamcloud's sha256, so our
signature vouches for exactly those files. It also writes a detached
`repodata/repomd.xml.asc` per repository for `repo_gpgcheck`, exports the
public key to `RPM-GPG-KEY-<repo-id>`, and renders the `.repo` file with
`gpgcheck=1` and `repo_gpgcheck=1` for all sections.

Create the new key once, outside this repository:

```sh
make keygen KEYDIR=/secure/place/gsi-kmods-key KEY_UID='GSI kmod repository <kmods@gsi.de>'
```

This creates an RSA 4096 key without expiry, with a revocation certificate
under `gnupg/openpgp-revocs.d/`. It leaves in `KEYDIR`:

- a GnuPG home, `gnupg/`;
- `secret-key.asc`, for a CI secret;
- the public key.

Set `GPG_PASSPHRASE_FILE` if the key should have a passphrase. Then put the
printed fingerprint into `config.env` as `GPG_KEY_ID` and commit that; the
fingerprint is public.

Hand the key to the build in one of these ways; neither is ever committed:

```sh
GPG_PRIVATE_KEY_FILE=/secure/place/gsi-kmods-key/secret-key.asc make repo   # e.g. a CI file secret
GNUPGHOME=/secure/place/gsi-kmods-key/gnupg make repo                       # default: ~/.gnupg
```

Both are mounted read-only and copied into the throwaway container. With a
passphrase, also set `GPG_PASSPHRASE_FILE`. Back up `KEYDIR` offline; losing
it means distributing a new key to every host.

When signing is enabled on a tree that holds unsigned (dev mode) packages, or
packages signed with another key, those are signed in place with a warning.
The same applies after a key rotation.

Unsigned dev mode (empty `GPG_KEY_ID`) signs nothing, renders `gpgcheck=0`,
and prints a warning. Never publish such a tree to production hosts.

## The output repository

- **Published files are immutable.** A package whose file name already exists
  in `OUT_DIR` is never replaced. Clients never see a NEVRA change content,
  and older builds stay available for rollback. To publish a rebuild of the
  same upstream version, bump `SITE_RELEASE_SUFFIX` (`gsi2`).
- **Deterministic metadata.** `createrepo_c` runs with a fixed revision
  (newest package mtime), timestamps set to it, and no sqlite. Re-running with
  an unchanged configuration leaves the tree byte-identical, including
  `repomd.xml.asc`, which is renewed only when `repomd.xml` changes. Adding a
  kernel to `KVERS` only adds packages.
- **Relative locations only.** The tree works under any base URL.
- **Pruning is explicit.** `make prune KEEP=N` (or `KEEP=N make repo`) keeps
  the N newest versions of each package name. Packages built for a kernel
  that is still listed in `KVERS` are never pruned. A source package is
  removed only when no published binary package was built from it.
- **Only configured kernels are published.** Builds in `build/` for a kernel
  no longer listed in `KVERS` are ignored, so pruned packages do not come
  back.

## Publishing

Pushing is not part of the build. Upload in two passes, so clients never see
metadata that references files not yet on the server:

```sh
# 1. packages, keys and the .repo file; repodata/ untouched, nothing deleted
rsync -av --exclude 'repodata/' out/repo/ web:/srv/www/gsi-kmods/
# 2. metadata, and deletions (pruned packages, old metadata files)
rsync -av --delete out/repo/ web:/srv/www/gsi-kmods/
```

Serve the directory as static files; any web server will do. To test locally:
`(cd out/repo && python3 -m http.server 8000)`, then set the `.repo` file's
base URL to `http://localhost:8000`. `make test-http` automates this.

## Adding a kernel

1. Append the kernel release to `KVERS` (e.g.
   `KVERS="5.14.0-611.55.1.el9_7 5.14.0-611.60.1.el9_7"`); it must exist in
   the configured trees, including the debug tree.
2. `make repo && make test`. The existing kernel's packages stay untouched.
   If DRBD reports a missing compat patch, follow the steps in
   [DRBD compat patches](#drbd-compat-patches-spaas).
3. Commit `config.env` (and any new `patches/drbd-compat/` entry), publish,
   then roll out: update `kernel_version` in Ansible, move the versionlock,
   reboot.

Remove a kernel from `KVERS` once no host runs it. Its published packages
stay until `make prune KEEP=N` removes them, and its builds are no longer
published.

## Moving to a new EL minor release

For example 9.8, once Lustre supports it. Set `EL_RELEASE`, `BASE_IMAGE` (a
9.8 image pinned by digest), `ROCKY_BASEURL`, `KVERS`, the Lustre SRPM for
that release and matching e2fsprogs in `config.env`, then run `make repo`.
The builder image is tagged separately, and the packages land in `el9.8/`
next to `el9.7/`, which stays as it is. The rendered `<repo-id>.repo`
describes the release of the current config; hosts on the other release keep
the repo definition they have (the Ansible example templates it anyway).

While a minor release is current, its trees under `dl.rockylinux.org/pub`
still change. Use a snapshot or a local mirror to get the same reproducibility
as with the frozen vault. EL10 needs a new base image, `%dist` and kernel
naming, but the layout and scripts are already parameterized by
`EL_RELEASE`.

## Consuming the repository on a host

[`examples/ansible/storage-node.yml`](examples/ansible/storage-node.yml) shows
the whole flow:

- `yum_repository` for the main repo, and for the e2fsprogs repo on Lustre
  servers only;
- `dnf` for the pinned kernel, DRBD (`kmod-drbd`, `drbd-utils`,
  `drbd-udev`), and the Lustre server set with e2fsprogs;
- `community.general.dnf_versionlock` for the kernel and the kmods;
- `/etc/modules-load.d/drbd.conf` with `drbd` and `drbd_transport_rdma`.

Points to keep in mind:

- The e2fsprogs section is disabled in the rendered `.repo` file on purpose.
  It replaces the distribution's e2fsprogs, which is right on Lustre servers
  and wrong anywhere else.
- Install the ldiskfs pair explicitly (`kmod-lustre-osd-ldiskfs`,
  `lustre-osd-ldiskfs-mount`). `lustre` only requires "some OSD", and the
  wbcfs OSD would also satisfy that.
- Lock the kmods together with the kernel. Once the repo carries builds for
  several kernels, a plain `dnf upgrade` would otherwise try to move a kmod to
  the build for another kernel.
- `lustre-resource-agents` needs `resource-agents` from Rocky's
  HighAvailability repository, which Pacemaker hosts have anyway.
- `kmod-drbd` ships LINBIT's Secure Boot certificate
  (`/etc/pki/linbit/…der`) because upstream's spec does. It is unused; our
  modules are not signed, and Secure Boot is off on the storage nodes.

## Migrating hosts from the old roles

Do this in a maintenance window, one node at a time, after failing its
resources over to the partner.

### DRBD

- The colleague's `kmod-drbd-9.3.4_5.14.0_611.55.1-1` has the same name, and
  ours (`…-1.gsi1.el9`) is newer, so `dnf install` replaces it in place.
  Check with `rpm -q kmod-drbd`.
- The old role installed userland with `dnf install drbd` from an unknown
  repository, probably EPEL. Make sure `drbd*` comes from our repo: add
  `excludepkgs=drbd*` to that repository (or remove it), then install
  `drbd-utils-9.35.0`. `rpm -q --qf '%{RELEASE}\n' drbd-utils` must show
  `.gsi1`.
- Delete what the old role left behind: the copied DRBD tarball, its build
  tree, and any `~/rpmbuild` of root. Also drop the role's
  `disable_gpg_check` usage; our packages are signed.

### Lustre

1. Stop Lustre and LNet and unmount the targets.
2. Remove the DKMS packages first. Their `%preun` runs `dkms remove`, which
   deletes the DKMS-built modules; remove them before our kmods install, so
   DKMS cannot delete files that now belong to our packages.
   `rpm -e --nodeps` removes only the named package; the Whamcloud userland
   it leaves behind is upgraded in step 5.

   ```sh
   dkms status
   rpm -e --nodeps lustre-ldiskfs-dkms      # and lustre-all-dkms / lustre-zfs-dkms if present
   dnf remove dkms
   dkms status 2>/dev/null; ls /var/lib/dkms 2>/dev/null   # expect nothing
   ```

3. Remove the ext4 sources the role copied into kernel-devel's tree. They
   belong to no package:

   ```sh
   for f in /usr/src/kernels/*/fs/ext4/*; do
       rpm -qf -- "$f" >/dev/null 2>&1 || rm -v -- "$f"
   done
   ```

   Also delete the kernel source RPM the role downloaded, and its unpacked
   tree (look in root's `~/rpmbuild`).
4. Remove the build toolchain the role installed. Review what it pulled in
   with `dnf history list` and `dnf history info <id>`, then remove those
   packages (typically `gcc`, `make`, `kernel-devel`, `kernel-headers`,
   `elfutils-libelf-devel`, `rpm-build`), for example with
   `dnf history undo <id>`. Keep anything else on the host that needs them.
5. Install from the repository (Ansible). Our `lustre-2.17.0-1.k…gsi1.el9`
   upgrades Whamcloud's `lustre-2.17.0-1.el9`, and the e2fsprogs repo
   upgrades e2fsprogs to `1.47.3-wc2`.
6. Check for leftovers that could shadow our modules:
   `find /lib/modules -name '*.ko*' -path '*/extra/*' -exec rpm -qf {} + | grep 'not owned'`
   must print nothing. Also check for `*.rpmsave` files under `/etc` (e.g.
   LNet configuration) and restore them.

## Smoke test on a real node

The container tests cannot load modules. On one test node, after the
Ansible run:

- [ ] `rpm -qa 'kmod-*' 'lustre*' 'drbd*' e2fsprogs` lists only `.gsi1`
      builds, and `e2fsprogs-1.47.3-wc2`.
- [ ] `dnf versionlock list` shows the kernel and the kmods.
- [ ] Reboot; `uname -r` is the pinned kernel.
- [ ] `lsmod | grep drbd` shows `drbd` and `drbd_transport_rdma`, loaded by
      `modules-load.d`.
- [ ] `drbdadm --version` shows `DRBD_KERNEL_VERSION=9.3.4` and
      `DRBDADM_VERSION=9.35.0`, and `cat /proc/drbd` shows `version: 9.3.4`.
- [ ] `modprobe lnet && lnetctl lnet configure && lnetctl net show` shows the
      o2ib network. Then `modprobe lustre && modprobe osd_ldiskfs`, and
      `lctl get_param version` shows `2.17.0`.
- [ ] `modinfo -n osd_ldiskfs` points to
      `/lib/modules/<kver>/extra/lustre-osd-ldiskfs/fs/osd_ldiskfs.ko`.
- [ ] `dmesg | grep -iE 'unknown symbol|disagrees about version|drbd|lustre|lnet|ldiskfs'`
      shows no symbol errors. Out-of-tree and unsigned-module taint flags
      (`O`, `E`) are expected.
- [ ] Bring up a DRBD resource (`drbdadm up <res>`), check `drbdadm status`,
      mount a test Lustre target, then unmount and `lustre_rmmod`.

## Verification

`make verify` runs `check-kmod.sh` on every kmod in `OUT_DIR`, and every build
runs it on its own result. It checks that:

- modules are only below `/lib/modules/<kver>/extra/`;
- `modinfo -F vermagic` of every module equals the kernel release;
- modules carry no debug info;
- the package has `kernel(…)` requirements and weak-modules scriptlets;
- the required modules are present. For `kmod-drbd` that includes
  `drbd_transport_rdma`; for `kmod-lustre` `ko2iblnd`; for
  `kmod-lustre-osd-ldiskfs` `ldiskfs` and `osd_ldiskfs`.

It also fails if a kernel in `KVERS` lacks `kmod-drbd`, `kmod-lustre` or
`kmod-lustre-osd-ldiskfs`.

`make test` starts one fresh `BASE_IMAGE` container per kernel with only the
pinned Rocky repos plus the generated repo, configured from the rendered
`.repo` file with the base URL pointed at `file:///repo`. It then:

1. installs `kernel-core-<kver>` and the full server set;
2. checks that each package is our build and that e2fsprogs came from the
   e2fsprogs repo;
3. checks that the modules resolve with `modprobe --show-depends` and that
   `drbdadm --version` works;
4. runs `dnf repoclosure` on both generated repos.

In signed mode it asserts `gpgcheck=1` and `repo_gpgcheck=1`, so dnf verifies
package signatures and repository metadata. `make test-http` does the same
against `python3 -m http.server`.

## Troubleshooting

- **"no DRBD compat patch for …"**: see
  [DRBD compat patches](#drbd-compat-patches-spaas).
- **ldiskfs patches do not apply**: the new kernel changed ext4 beyond what
  Lustre's series handles. Wait for a Lustre release that supports it; do not
  fuzz patches.
- **sha256 mismatch**: upstream replaced a file, or the download was
  corrupted. Never just update the hash; find out why first.
- **Behind a proxy**: set `https_proxy`, and `BUILDER_CA_BUNDLE` for a
  TLS-inspecting proxy; `BUILDER_NETWORK=host` if the proxy listens on
  localhost.
- **File ownership**: with a rootful runtime (e.g. Docker via the docker
  group) the containers hand everything they write back to the calling user.
  With rootless Podman or Docker, or with userns remapping, container root
  already maps to the caller, so nothing is changed.

## Layout of this repository

```
config.env                   versions, checksums, URLs (single source of truth)
Containerfile                builder image
Makefile                     entry points
scripts/builder              host side: runs each step in a container
scripts/lib.sh               shared helpers (config, naming, .repo rendering)
scripts/in-container/        fetch, build-*, check-kmod, verify, make-repo, test-install, keygen
patches/drbd-compat/         committed DRBD compat patches for kernels the tarball lacks
examples/ansible/            host consumption example
docs/upstream-notes.md       verified facts about the upstream build systems
```

There is no CI definition yet. The whole build is `make repo && make test`,
so a GitLab CI job on a runner with Podman needs little more than
`GPG_PRIVATE_KEY_FILE` as a file secret and an artifact or rsync step.
