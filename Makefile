# Entry points. Everything runs in containers via scripts/builder; the host
# needs only bash, make and podman (or docker). See README.md.

BUILDER := scripts/builder
export FORCE KEEP

.PHONY: all repo image fetch drbd verify test shell lint clean help

all: repo

## repo      build everything for all KVERS and (re)generate OUT_DIR
repo: drbd
	$(BUILDER) repo

## image     build the builder container image (cached by content hash)
image:
	$(BUILDER) image

## fetch     download and verify all sources into sources/
fetch:
	$(BUILDER) fetch

## drbd      build kmod-drbd for every kernel in KVERS
drbd: fetch
	$(BUILDER) build drbd

## verify    check every kmod in OUT_DIR (paths, vermagic, ksyms, weak-modules)
verify:
	$(BUILDER) verify

## test      install test in fresh Rocky containers, one per kernel
test: verify
	$(BUILDER) test

## shell     interactive shell in the builder image
shell:
	$(BUILDER) shell

## lint      shellcheck all scripts (needs shellcheck on the host)
lint:
	shellcheck -x config.env scripts/lib.sh scripts/builder scripts/in-container/*.sh

## clean     remove build/ (sources/ and OUT_DIR are kept)
clean:
	rm -rf build

help:
	@sed -n 's/^## //p' $(MAKEFILE_LIST)
