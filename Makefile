.PHONY: test test-linux test-mac test-snapshot help test-linux-inner test-mac-inner test-ci-mac build-admin

# Recipes use [[ ]]; make defaults to /bin/sh, which is dash on Debian/Ubuntu.
SHELL := /bin/bash

# A Go toolchain installed for the wrong architecture emits binaries for ITS
# architecture rather than the machine's: an Intel Go under Rosetta on Apple
# Silicon silently produces x86_64 services that then run translated. Build for
# the host's real architecture instead of the toolchain's default.
#
# cgo stays enabled deliberately. The admin resolves MagicDNS names for its
# health checks, and CGO_ENABLED=0 would switch it to Go's pure resolver, which
# does not read macOS's system DNS configuration -- so disabling cgo to make
# cross-compilation easy would quietly break health checks instead.
# Go turns cgo OFF by default as soon as GOARCH differs from the toolchain's own
# architecture, so CGO_ENABLED=1 must be stated explicitly here -- setting CC
# alone is not enough. It is set only on Darwin, where clang is present and can
# target either architecture; Linux builds are already native and keep Go's
# default.
HOST_ARCH := $(shell uname -m)
HOST_GOARCH := $(patsubst x86_64,amd64,$(patsubst aarch64,arm64,$(HOST_ARCH)))
GOBUILDENV := GOARCH=$(HOST_GOARCH)
ifeq ($(shell uname -s),Darwin)
GOBUILDENV := $(GOBUILDENV) CGO_ENABLED=1 CC="clang -arch $(HOST_ARCH)"
endif

DEFAULT: help

help:
	@echo "Targets:"
	@echo "  make test           # host-native, ~5s -- compiles admin as a check only (go build -o /dev/null), never touches the production binary"
	@echo "  make build-admin    # builds portable/home-stack/admin/home-stack-admin (the production path launchd runs)"
	@echo "  make test-linux     # Apple Container CLI / Docker, ~30s"
	@echo "  make test-mac       # Tart ephemeral macOS VM, ~90s incl boot"
	@echo "  make test-snapshot  # regenerate engine output goldens"

# Writes ONLY the production admin binary path. `make test` never calls this --
# it builds into admin/.test-build/ instead -- so a feature branch's `make test`
# can never leave branch code where launchd resolves the binary on next restart.
build-admin:
	cd portable/home-stack/admin && $(GOBUILDENV) go build -o home-stack-admin .

test:
	@echo "=== go tests ==="
	cd portable/home-stack/admin && go test ./...
	@echo "=== compiling admin (check only; nothing consumes this binary, production binary untouched) ==="
	cd portable/home-stack/admin && $(GOBUILDENV) go build -o /dev/null .
	@echo "=== shell tests (host) ==="
	@failed=""; skipped=""; \
	for t in tests/*.test.sh; do \
		if [[ "$$t" == *"status-launchd.test.sh" && "$$(uname)" != "Darwin" ]]; then \
			skipped="$$skipped $$t"; \
			continue; \
		fi; \
		bash "$$t"; rc=$$?; \
		case $$rc in \
			0) ;; \
			77) skipped="$$skipped $$t" ;; \
			*) failed="$$failed $$t" ;; \
		esac; \
	done; \
	if [[ -n "$$skipped" ]]; then echo "SKIPPED:$$skipped"; fi; \
	if [[ -n "$$failed" ]]; then echo "FAILED TESTS:$$failed" >&2; exit 1; fi

test-linux:
	@bash tools/run-linux-test.sh

# DISABLED pending three independent blockers. Re-enabling means exporting
# HOME_STACK_TEST_EPHEMERAL=1 in test-mac-inner, and doing that before the
# blockers are cleared would point real launchd tests at a read-write mount of
# the host's working tree:
#   1. tools/run-tart-test.sh mounts $(REPO_ROOT) rw (no :ro), so `hs sync` and
#      the test cleanups rewrite and then DELETE the live Caddyfile, which is
#      gitignored -- no signal, no recovery, ingress crashloops on next reload.
#   2. tools/build-tart-base.sh grants NOPASSWD for /bin/launchctl only, while
#      the installers also need sudo install and sudo rm -- those prompt, and
#      there is no tty over ssh.
#   3. No home-stack-test-base image exists, so none of this is verifiable yet.
# Failing loudly rather than skipping: this target silently reported success
# while running zero launchd tests, which is the bug class this suite exists
# to prevent.
test-mac:
	@echo "make test-mac is disabled: the Tart path would write to your live" >&2
	@echo "working tree over a read-write mount. See the comment above this" >&2
	@echo "target in the Makefile for the three blockers." >&2
	@exit 1

test-snapshot:
	REGEN=1 bash tests/engine-snapshot.test.sh

test-linux-inner:
	@echo "=== go tests (linux) ==="
	cd portable/home-stack/admin && go test ./...
	@echo "=== shell tests (linux) ==="
	@failed=""; skipped=""; \
	for t in tests/*.test.sh; do \
		if [[ "$$t" == *"status-launchd.test.sh" ]]; then \
			continue; \
		fi; \
		bash "$$t"; rc=$$?; \
		case $$rc in \
			0) ;; \
			77) skipped="$$skipped $$t" ;; \
			*) failed="$$failed $$t" ;; \
		esac; \
	done; \
	if [[ -n "$$skipped" ]]; then echo "SKIPPED:$$skipped"; fi; \
	if [[ -n "$$failed" ]]; then echo "FAILED TESTS:$$failed" >&2; exit 1; fi

# Runs inside the Tart VM, invoked by tools/run-tart-test.sh. Its only caller
# is `test-mac`, which is disabled -- see the blockers documented there. Left
# refusing rather than half-working: it opts in to system changes without
# declaring the host disposable, so every launchd test would exit 1 anyway.
# Re-enable it and `test-mac` together, once the Tart harness stops mounting
# the working tree read-write.
test-mac-inner:
	@echo "test-mac-inner is disabled along with 'make test-mac'." >&2
	@echo "See the comment above the test-mac target for the blockers." >&2
	@exit 1

# Darwin-only surface, for ephemeral CI runners. A hosted macOS runner is
# disposable like the Tart VM, so HOME_STACK_TEST_ALLOW_SYSTEM_CHANGES is safe
# here: the launchd e2e tests install real plists and bootstrap real jobs,
# which is the coverage actually worth GitHub's 10x macOS rate. Everything
# portable is covered by test-linux-inner at 1x.
#
DARWIN_TESTS := \
	tests/plist-lint.test.sh \
	tests/status-launchd.test.sh \
	tests/service-lifecycle.test.sh \
	tests/identifier-prefix-flow.test.sh \
	tests/install-launchd-e2e.test.sh

# The disposability declaration deliberately does NOT live here. It is set by
# the CI workflow, where it sits in a reviewed file rather than being inferred
# from an ambient variable that unrelated tooling also sets.
test-ci-mac:
	@if [[ "$${HOME_STACK_TEST_EPHEMERAL:-}" != "1" ]]; then \
		echo "test-ci-mac performs real launchd operations: it installs plists," >&2; \
		echo "bootstraps jobs into the system domain, and writes /Library." >&2; \
		echo "It runs only where the CI workflow has declared the host disposable." >&2; \
		echo "Locally use 'make test' -- the launchd tests skip there by design." >&2; \
		exit 1; \
	fi
	@echo "=== go tests (darwin) ==="
	cd portable/home-stack/admin && go test ./...
	@echo "=== building admin (darwin; production path -- this runner is disposable) ==="
	cd portable/home-stack/admin && $(GOBUILDENV) go build -o home-stack-admin .
	@echo "=== darwin shell tests (system changes allowed) ==="
	@failed=""; skipped=""; \
	for t in $(DARWIN_TESTS); do \
		HOME_STACK_TEST_ALLOW_SYSTEM_CHANGES=1 bash "$$t"; rc=$$?; \
		case $$rc in \
			0) ;; \
			77) skipped="$$skipped $$t" ;; \
			*) failed="$$failed $$t" ;; \
		esac; \
	done; \
	if [[ -n "$$failed" ]]; then echo "FAILED TESTS:$$failed" >&2; exit 1; fi; \
	if [[ -n "$$skipped" ]]; then \
		echo "SKIPPED ON A RUNNER THAT MUST RUN THEM:$$skipped" >&2; \
		echo "A Darwin test that skips in CI proves nothing while reporting green." >&2; \
		exit 1; \
	fi
