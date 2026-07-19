SHELL := /usr/bin/bash

ZIG ?= zig
CARGO ?= cargo
RUSTC ?= rustc
JOBS ?= 2

.PHONY: help linux-artifact linux-canvas

help:
	@echo "DarkPanda reproducible build entry points"
	@echo "  make linux-artifact  (requires all *_INPUT variables below)"
	@echo "  make linux-canvas    (real rust-skia component proof)"
	@echo "No target downloads dependencies or reuses zig-out/.zig-cache."

define require
	@test -n "$($(1))" || { echo "missing $(1)" >&2; exit 2; }
endef

linux-artifact:
	$(call require,V8_BUNDLE_MANIFEST)
	$(call require,CARGO_VENDOR_INPUT)
	$(call require,SKIA_SOURCE_INPUT)
	$(call require,SKIA_GN_INPUT)
	$(call require,SKIA_NINJA_INPUT)
	$(call require,CMAKE_ROOT_INPUT)
	$(call require,ZIG_PACKAGE_CACHE_INPUT)
	bash tools/Build-LinuxArtifactSet.sh \
		--zig "$$(command -v $(ZIG))" \
		--cargo "$$(command -v $(CARGO))" \
		--rustc "$$(command -v $(RUSTC))" \
		--v8-bundle-manifest "$(V8_BUNDLE_MANIFEST)" \
		--cargo-vendor "$(CARGO_VENDOR_INPUT)" \
		--skia-source "$(SKIA_SOURCE_INPUT)" \
		--skia-gn "$(SKIA_GN_INPUT)" \
		--skia-ninja "$(SKIA_NINJA_INPUT)" \
		--cmake-root "$(CMAKE_ROOT_INPUT)" \
		--zig-package-cache "$(ZIG_PACKAGE_CACHE_INPUT)" \
		--jobs "$(JOBS)"

linux-canvas:
	$(call require,CARGO_VENDOR_INPUT)
	$(call require,SKIA_SOURCE_INPUT)
	$(call require,SKIA_GN_INPUT)
	$(call require,SKIA_NINJA_INPUT)
	$(call require,ZIG_PACKAGE_CACHE_INPUT)
	bash tools/Build-LinuxCanvasSmoke.sh \
		--zig "$$(command -v $(ZIG))" \
		--cargo "$$(command -v $(CARGO))" \
		--rustc "$$(command -v $(RUSTC))" \
		--cargo-vendor "$(CARGO_VENDOR_INPUT)" \
		--skia-source "$(SKIA_SOURCE_INPUT)" \
		--skia-gn "$(SKIA_GN_INPUT)" \
		--skia-ninja "$(SKIA_NINJA_INPUT)" \
		--zig-package-cache "$(ZIG_PACKAGE_CACHE_INPUT)" \
		--jobs "$(JOBS)"
