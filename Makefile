SHELL := /bin/bash

ZIG ?= zig
PYTHON ?= python3
OPTIMIZE ?= Debug
TARGET ?=
PREFIX ?= zig-out

COMPONENT_ARGS = \
	-Dcanvas_dist="$(CANVAS_DIST)" \
	-Dhtml5ever_dist="$(HTML5EVER_DIST)" \
	-Dwreq_dist="$(WREQ_DIST)" \
	-Dboringssl_dist="$(BORINGSSL_DIST)" \
	-Dwebrtc_dist="$(WEBRTC_DIST)"
BUILD_ARGS = \
	$(COMPONENT_ARGS) \
	-Doptimize="$(OPTIMIZE)" \
	$(if $(TARGET),-Dtarget="$(TARGET)") \
	$(if $(V8_ARCHIVE),-Dprebuilt_v8_path="$(V8_ARCHIVE)")

.PHONY: help native-inputs fmt pffft check test install test-runner-report

help:
	@echo "DarkPanda developer entry points"
	@echo "  make fmt                 Check Zig formatting"
	@echo "  make pffft               Build the portable WebAudio FFT dependency"
	@echo "  make check               Compile-check with five component dist roots"
	@echo "  make test F=substring    Run browser tests with an optional filter"
	@echo "  make install             Install the complete adjacent runtime"
	@echo "  make test-runner-report  Verify JSON/JUnit, leak, and zero-test behavior"
	@echo ""
	@echo "Native targets require absolute CANVAS_DIST, HTML5EVER_DIST,"
	@echo "WREQ_DIST, BORINGSSL_DIST, and WEBRTC_DIST. TARGET and V8_ARCHIVE are optional."

define require
	@test -n "$($(1))" || { echo "missing $(1)" >&2; exit 2; }
endef

native-inputs:
	$(call require,CANVAS_DIST)
	$(call require,HTML5EVER_DIST)
	$(call require,WREQ_DIST)
	$(call require,BORINGSSL_DIST)
	$(call require,WEBRTC_DIST)

fmt:
	$(ZIG) build fmt

pffft:
	$(ZIG) build pffft

check: native-inputs
	$(ZIG) build check $(BUILD_ARGS)

test: native-inputs
	TEST_FILTER="$(if $(F),$(F),$(TEST_FILTER))" $(ZIG) build test $(BUILD_ARGS)

install: native-inputs
	$(ZIG) build install $(BUILD_ARGS) -p "$(PREFIX)"

test-runner-report:
	$(PYTHON) tools/ci/test_test_runner_reports.py --zig "$$(command -v $(ZIG))"
