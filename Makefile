# Copyright Istio Authors
# Licensed under the Apache License, Version 2.0 (the "License")

.PHONY: dist

# Include versions of tools we build or fetch on-demand.
include Tools.mk

name := auth_server

# Root dir returns absolute path of current directory. It has a trailing "/".
root_dir := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Currently we resolve it using which. But more sophisticated approach is to use infer GOROOT.
go     := $(shell which go)
goarch := $(shell $(go) env GOARCH)
goos   := $(shell $(go) env GOOS)

VERSION ?= dev

current_binary_path := build/$(name)_$(goos)_$(goarch)
current_binary      := $(current_binary_path)/$(name)

archives := dist/$(name)_$(VERSION)_$(goos)_$(goarch).tar.gz

# Local cache directory.
CACHE_DIR ?= $(root_dir).cache

# Go tools directory holds the binaries of Go-based tools.
go_tools_dir          := $(CACHE_DIR)/tools/go
prepackaged_tools_dir := $(CACHE_DIR)/tools/prepackaged
bazel_cache_dir       := $(CACHE_DIR)/bazel
clang_version         := $(subst github.com/llvm/llvm-project/llvmorg/clang+llvm@,,$(clang@v))

main_cc_sources    := $(wildcard src/*/*.cc src/*/*.h src/*/*/*.cc src/*/*/*.h)
main_build_sources := $(wildcard src/*/BUILD src/*/*/BUILD)
main_sources       := $(main_cc_sources) $(main_build_sources)

testable_cc_sources    := $(wildcard test/*/*.cc test/*/*.h test/*/*/*.cc test/*/*/*.h)
testable_build_sources := $(wildcard test/*/BUILD test/*/*/BUILD)
testable_sources       := $(testable_cc_sources) $(testable_build_sources)

protos := $(wildcard config/*.proto config/*/*.proto config/*/*/*.proto)

export PATH            := $(go_tools_dir):$(prepackaged_tools_dir)/bin:$(PATH)
export LLVM_PREFIX     := $(prepackaged_tools_dir)
export RT_LIBRARY_PATH := $(prepackaged_tools_dir)/lib/clang/$(clang_version)/lib/$(goos)
export BAZELISK_HOME   := $(CACHE_DIR)/tools/bazelisk
export CGO_ENABLED     := 0

# Always build with libc++, but make it overrideable.
export BAZEL_FLAGS ?= --config=libc++

# Always use amd64 for bazelisk for build and test rules below, since we don't support for macOS
# arm64 yet (especially the protoc-gen-validate project).
bazel        := GOARCH=amd64 $(go) run $(bazelisk@v) --output_user_root=$(bazel_cache_dir)
buf          := $(go_tools_dir)/buf
buildifier   := $(go_tools_dir)/buildifier
envsubst     := $(go_tools_dir)/envsubst
clang        := $(prepackaged_tools_dir)/bin/clang
clang-format := $(prepackaged_tools_dir)/bin/clang-format
llvm-config  := $(prepackaged_tools_dir)/bin/llvm-config

# This is adopted from https://github.com/tetratelabs/func-e/blob/3df66c9593e827d67b330b7355d577f91cdcb722/Makefile#L60-L76.
# ANSI escape codes. f_ means foreground, b_ background.
# See https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_(Select_Graphic_Rendition)_parameters.
f_black            := $(shell printf "\33[30m")
b_black            := $(shell printf "\33[40m")
f_white            := $(shell printf "\33[97m")
f_gray             := $(shell printf "\33[37m")
f_dark_gray        := $(shell printf "\33[90m")
f_bright_cyan      := $(shell printf "\33[96m")
b_bright_cyan      := $(shell printf "\33[106m")
ansi_reset         := $(shell printf "\33[0m")
ansi_$(name)       := $(b_black)$(f_black)$(b_bright_cyan)$(name)$(ansi_reset)
ansi_format_dark   := $(f_gray)$(f_bright_cyan)%-10s$(ansi_reset) $(f_dark_gray)%s$(ansi_reset)\n
ansi_format_bright := $(f_white)$(f_bright_cyan)%-10s$(ansi_reset) $(f_black)$(b_bright_cyan)%s$(ansi_reset)\n

help: ## Describe how to use each target
	@printf "$(ansi_$(name))$(f_white)\n"
	@awk 'BEGIN {FS = ":.*?## "} /^[0-9a-zA-Z_-]+:.*?## / {sub("\\\\n",sprintf("\n%22c"," "), $$2);printf "$(ansi_format_dark)", $$1, $$2}' $(MAKEFILE_LIST)

build: $(current_binary) ## Build the authservice binary

release: $(current_binary).stripped ## Build the authservice release binary

TEST_FLAGS ?= --strategy=TestRunner=standalone --test_output=all --cache_test_results=no
test: clang.bazelrc $(main_sources) $(testable_sources) ## Run tests
	$(call bazel-test)

# Run tests with a filter.
# Usage examples:
#   make test-filter FILTER=*RetrieveToken*
#   make test-filter FILTER=OidcFilterTest.*
FILTER ?= *RetrieveToken*
testfilter: clang.bazelrc $(main_sources) $(testable_sources) ## Run tests with filter FILTER.
	$(call bazel-test,--test_arg='--gtest_filter=$(FILTER)')

format: $(buildifier) $(clang-format) ## Format files.
	@$(buildifier) --lint=fix -r bazel src test
	@$(buildifier) --lint=fix WORKSPACE BUILD.bazel
	@$(clang-format) -i $(main_cc_sources) $(testable_cc_sources) $(protos)

dist: $(archives) ## Generate release assets

HUB ?= ghcr.io/dio/authservice
# TODO(dio): Build with multiarch support.
docker:
ifeq ($(goos),linux)
	$(MAKE) dist/$(name)_linux_amd64/$(name).stripped
	@docker build --build-arg NAME=$(name) --tag $(HUB)/$(name):$(VERSION) .
else
# TODO(dio): Build the release binary in a docker container.
	@echo "building docker image currently is only supported on Linux."
endif

# By default, run the build rule with "fastbuild" compilation mode. "fastbuild" means build as fast
# as possible: generate minimal debugging information (-gmlt -Wl,-S), and don't optimize.
# This is the default. Note: -DNDEBUG will not be set.
#
# Reference: https://docs.bazel.build/versions/main/user-manual.html#flag--compilation_mode.
build/$(name)_$(goos)_$(goarch)/$(name): clang.bazelrc $(main_sources)
	@$(call bazel-build,$@)

# Stripped binary is compiled using "--compilation_mode opt". "opt" means build with optimization
# enabled and with assert() calls disabled (-O2 -DNDEBUG). Debugging information will not be
# generated in opt mode unless you also pass --copt -g.
#
# Reference: https://docs.bazel.build/versions/main/user-manual.html#flag--compilation_mode.
build/$(name)_$(goos)_$(goarch)/$(name).stripped: clang.bazelrc $(main_sources)
	@$(call bazel-build,$@,--compilation_mode opt)

dist/$(name)_$(VERSION)_$(goos)_$(goarch).tar.gz: build/$(name)_$(goos)_$(goarch)/$(name).stripped
	@mkdir -p $(@D)
	@tar -C $(<D) -cpzf $@ $(<F)

clang.bazelrc: bazel/clang.bazelrc.tmpl $(llvm-config) $(envsubst)
	@$(envsubst) < $< > $@

bazelclean: ## Clean up the bazel caches
	@$(bazel) clean --expunge --async

clean: ## Clean the dist directory
	@rm -fr dist build

modupdate: $(buf) ## Update buf.lock file
	@$(buf) mod update

modlint: $(buf) ## Lint all **/*.proto
	@$(buf) lint

$(llvm-config): $(clang)

# Catch all rules for Go-based tools.
$(go_tools_dir)/%:
	@GOBIN=$(go_tools_dir) go install $($(notdir $@)@v)

define bazel-build
	$(call bazel-dirs)
	$(bazel) build $(BAZEL_FLAGS) $2 //src/main:$(notdir $1)
	mkdir -p $(dir $1) && cp -f bazel-bin/src/main/$(notdir $1) $1
endef
define bazel-test
	$(call bazel-dirs)
	$(bazel) test $(BAZEL_FLAGS) $(TEST_FLAGS) //test/... $1
endef
define bazel-dirs
	mkdir -p $(BAZELISK_HOME)
	mkdir -p $(bazel_cache_dir)
endef

# Install clang from https://github.com/llvm/llvm-project. We don't support win32 yet as this script
# will fail.
clang-os                          = $(if $(findstring $(goos),darwin),apple-darwin,linux-gnu-ubuntu-20.04)
clang-download-archive-url-prefix = https://$(subst llvmorg/clang+llvm@,releases/download/llvmorg-,$($(notdir $1)@v))
$(clang):
	@mkdir -p $(dir $@)
	@curl -SL $(call clang-download-archive-url-prefix,$@)/clang+llvm-$(clang_version)-x86_64-$(call clang-os).tar.xz | \
		tar xJf - -C $(prepackaged_tools_dir) --strip-components 1

# Install clang-format from https://github.com/angular/clang-format. We don't support win32 yet as
# this script will fail.
clang-format-download-archive-url = https://$(subst @,/archive/refs/tags/,$($(notdir $1)@v)).tar.gz
clang-format-dir                  = $(subst github.com/angular/clang-format@v,clang-format-,$($(notdir $1)@v))
$(clang-format):
	@mkdir -p $(dir $@)
	@curl -SL $(call clang-format-download-archive-url,$@) | tar xzf - -C $(prepackaged_tools_dir)/bin \
		--strip 3 $(call clang-format-dir,$@)/bin/$(goos)_x64
