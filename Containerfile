# check=skip=InvalidDefaultArgInFrom
# Builder image: the pinned Rocky base image, repo files that point only at the
# frozen minor-release trees, and the generic RPM toolchain. Kernel headers and
# per-package build dependencies are installed per build, in throwaway
# containers started from this image (see scripts/builder).
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG ROCKY_BASEURL
ARG ROCKY_GPGKEY

COPY render-rocky-repos.sh /usr/local/libexec/kmod-builder/render-rocky-repos.sh

# An optional CA bundle (TLS-inspecting proxy) is passed as a build secret and
# removed again, so it never ends up in the image.
RUN --mount=type=secret,id=ca \
    set -eu; \
    if [ -s /run/secrets/ca ]; then \
        cp /run/secrets/ca /etc/pki/ca-trust/source/anchors/builder-ca.crt; \
        update-ca-trust; \
    fi; \
    /usr/local/libexec/kmod-builder/render-rocky-repos.sh "$ROCKY_BASEURL" "$ROCKY_GPGKEY"; \
    printf '%s\n' keepcache=1 install_weak_deps=0 >>/etc/dnf/dnf.conf; \
    dnf -y --nodocs install \
        autoconf automake bc binutils bison bzip2 cpio createrepo_c diffutils \
        dnf-plugins-core elfutils-libelf-devel file findutils flex gcc gcc-c++ \
        gnupg2 gzip kernel-abi-stablelists kernel-rpm-macros kmod libtool make \
        patch perl python3 redhat-rpm-config rpm-build rpm-sign tar which xz; \
    dnf clean all; \
    rm -f /etc/pki/ca-trust/source/anchors/builder-ca.crt; \
    update-ca-trust
