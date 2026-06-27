# wifiscan — terminal WiFi survey & channel planner (Swift / CoreWLAN).
# `make` builds wifiscan.app into ~/Applications and a `wifiscan` launcher on PATH.
#
# Why an .app bundle? macOS gates Wi-Fi SSIDs behind Location Services and only
# grants it to an app with its own identity. A bare CLI has none, so its request
# can't be attributed to the terminal reliably. Running the binary *inside* a
# signed .app gives the process the bundle's identity, so "wifiscan" appears in
# Location Services on its own — independent of which terminal you launch it from.

# Optional machine-local overrides (git-ignored) — e.g. SIGN := <your cert>.
-include Makefile.local

BINARY      := wifiscan
# Core.swift = pure, framework-free logic (also compiled standalone by `make test`
# and held at 100% coverage by `make coverage`); main.swift = CoreWLAN/CoreLocation,
# TUI, scan helper, entrypoint.
CORE        := Sources/wifiscan/Core.swift
SRC         := $(CORE) Sources/wifiscan/main.swift
TEST_SRC    := $(CORE) Tests/CoreTests.swift
COV_DIR     := .build/coverage
PLIST       := Info.plist
INSTALL_DIR := $(HOME)/.bin
APP_DIR     := $(HOME)/Applications
APP         := $(APP_DIR)/$(BINARY).app
EXE         := $(APP)/Contents/MacOS/$(BINARY)
BUNDLE_ID   := com.lucasdaddiego.wifiscan
# Signing identity. Ad-hoc ("-") by default — but ad-hoc has no stable identity, so
# macOS ties the Location grant to the exact build and forgets it on every rebuild.
# For a grant that survives rebuilds, create a self-signed "Code Signing" certificate
# once (Keychain Access → Certificate Assistant → Create a Certificate, type "Code
# Signing"), then build with:  make SIGN="Your Cert Name"
SIGN        ?= -

FRAMEWORKS  := -framework CoreWLAN -framework CoreLocation
# Release: optimise (-O), strip local symbols (-x), drop dead code (-dead_strip).
# No -g, so zero debug info. Stripping is at link time, before signing.
RELEASE     := -O -Xlinker -x -Xlinker -dead_strip

LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.DEFAULT_GOAL := install
.PHONY: install clean test coverage

install: ## Build wifiscan.app into ~/Applications + a `wifiscan` launcher on ~/.bin
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(INSTALL_DIR)"
	cp $(PLIST) "$(APP)/Contents/Info.plist"
	swiftc $(RELEASE) $(SRC) -o "$(EXE)" $(FRAMEWORKS)
	codesign --force --sign $(SIGN) --identifier $(BUNDLE_ID) "$(APP)"
	ln -sf "$(EXE)" "$(INSTALL_DIR)/$(BINARY)"
	-$(LSREGISTER) -f "$(APP)"
	@echo "installed $(APP) ($$(du -sh "$(APP)" | cut -f1))"
	@echo "         launcher: $(INSTALL_DIR)/$(BINARY) -> in-bundle binary"
	@echo
	@echo "one-time permission:"
	@echo "  1. run \`$(BINARY)\` once  (registers it with Location Services)"
	@echo "  2. System Settings → Privacy & Security → Location Services → enable 'wifiscan'"
	@echo "  3. fully quit Terminal (⌘Q) and reopen, then run \`$(BINARY)\`"

test: ## Build & run the dependency-free core unit tests (no Xcode/XCTest needed)
	@swiftc -parse-as-library $(TEST_SRC) -o /tmp/wifiscan-tests
	@/tmp/wifiscan-tests

coverage: ## Run the core tests under coverage; fail unless Core.swift is 100% covered
	@mkdir -p "$(COV_DIR)"
	@swiftc -profile-generate -profile-coverage-mapping -parse-as-library $(TEST_SRC) -o "$(COV_DIR)/tests"
	@LLVM_PROFILE_FILE="$(COV_DIR)/tests.profraw" "$(COV_DIR)/tests"
	@xcrun llvm-profdata merge -sparse "$(COV_DIR)/tests.profraw" -o "$(COV_DIR)/tests.profdata"
	@xcrun llvm-cov report "$(COV_DIR)/tests" -instr-profile="$(COV_DIR)/tests.profdata" $(CORE)
	@bash scripts/check-coverage.sh "$(COV_DIR)/tests" "$(COV_DIR)/tests.profdata" $(CORE)

clean: ## Remove the app bundle and the launcher
	rm -rf "$(APP)" "$(INSTALL_DIR)/$(BINARY)"
