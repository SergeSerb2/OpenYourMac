SHELL := /bin/bash
# Invoke make from the repository root (including with make -C).
ROOT := $(CURDIR)/
export PATH := $(HOME)/.cargo/bin:$(PATH)
.DEFAULT_GOAL := all

.PHONY: all bundle engine app debug run snapshots icon test ci clean

all: bundle

bundle:
	"$(ROOT)scripts/build-app.sh"

engine:
	cd "$(ROOT)engine" && cargo build --locked --release --no-default-features

app:
	swift build -c release --package-path "$(ROOT)app"

debug:
	"$(ROOT)scripts/build-app.sh" --debug

run: bundle
	open "$(ROOT)build/OpenYourMac.app"

snapshots: bundle
	@oym_home=$$(mktemp -d /tmp/openyourmac-snapshots.XXXXXX) && \
	trap 'rm -rf "$$oym_home"' EXIT && \
	HOME="$$oym_home" OYM_MACH_SERVICE="com.openyourmac.engine.snapshot.$$$$test" \
	"$(ROOT)build/OpenYourMac.app/Contents/MacOS/OpenYourMac" --snapshot "$(ROOT)build/snapshots"

icon:
	"$(ROOT)scripts/make-icon.sh"

test:
	cd "$(ROOT)engine" && cargo test --locked --no-default-features

ci:
	"$(ROOT)scripts/ci.sh"

clean:
	rm -rf "$(ROOT)build" "$(ROOT)engine/target" "$(ROOT)app/.build"
