# canopy/native — developer entry points.
#
# The one you want when a build fails for no obvious reason:
#
#     make rebuild-artifacts   # recompile all artifacts.dat when builds fail mysteriously
#
# A stale per-package compiled-interface cache (artifacts.dat) is the #1 cause of cryptic
# "Missing global X.init" / "could not find module" errors. See docs/troubleshooting.md.

SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

# recompile all artifacts.dat when builds fail mysteriously
# (force-fresh: wipes every canopy/* package's stale cache, then recompiles from source
#  under the current compiler via `canopy setup`). Run this FIRST whenever a build dies
#  with a "Missing global" / "could not find module" error you can't otherwise explain.
.PHONY: rebuild-artifacts
rebuild-artifacts:
	./scripts/rebuild-artifacts.sh

# dev-link the monorepo canopy/* source packages into ~/.canopy/packages (via `canopy link`)
# so the compiler resolves the live sources. Run this on a fresh machine, or after a
# package's *version* changes (then follow with `make rebuild-artifacts`).
.PHONY: link-packages
link-packages:
	./scripts/link-dev-packages.sh

# report native toolchain readiness (compiler, Node, Android/iOS SDKs, ...).
.PHONY: doctor
doctor:
	canopy-native doctor

# list the available targets.
.PHONY: help
help:
	@echo "canopy/native dev targets:"
	@echo "  make rebuild-artifacts  recompile all artifacts.dat when builds fail mysteriously"
	@echo "  make link-packages      dev-link monorepo canopy/* packages into ~/.canopy/packages"
	@echo "  make doctor             report native toolchain readiness"
	@echo "  make help               show this list"
	@echo
	@echo "Stuck on a cryptic compile error? See docs/troubleshooting.md"
