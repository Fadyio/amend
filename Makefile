# MacDub Makefile
SHELL := /bin/bash
INSTALL_DIR ?= $(HOME)/Applications
APP_NAME := MacDub
DIST_DIR := dist
APP_BUNDLE := $(DIST_DIR)/$(APP_NAME).app
DMG_PATH := $(DIST_DIR)/$(APP_NAME).dmg

.PHONY: all help run build test app open install dmg clean

all: app

help:
	@echo "MacDub Build & Packaging Automation"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  help      Show this help message"
	@echo "  run       Launch MacDub in development mode (swift run macdub)"
	@echo "  build     Compile release executable (swift build -c release)"
	@echo "  test      Run test suite (swift test --no-parallel)"
	@echo "  app       Package release build into double-clickable $(APP_BUNDLE)"
	@echo "  open      Build and launch $(APP_BUNDLE)"
	@echo "  install   Install $(APP_NAME).app to $(INSTALL_DIR) (override with INSTALL_DIR=...)"
	@echo "  dmg       Create standalone $(DMG_PATH) containing $(APP_NAME).app"
	@echo "  clean     Remove dist/ output and SwiftPM build artifacts"

run:
	swift run macdub

build:
	swift build -c release --product macdub

test:
	swift test --no-parallel

app:
	@./scripts/build-app.sh

open: app
	open "$(APP_BUNDLE)"

install: app
	@echo "==> Installing $(APP_NAME).app into $(INSTALL_DIR)..."
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/"
	@echo "==> Successfully installed: $(INSTALL_DIR)/$(APP_NAME).app"

dmg: app
	@echo "==> Creating disk image $(DMG_PATH)..."
	@rm -f "$(DMG_PATH)"
	@hdiutil create -volname "$(APP_NAME)" -srcfolder "$(APP_BUNDLE)" -ov -format UDZO "$(DMG_PATH)"
	@echo "==> Successfully created: $(DMG_PATH)"

clean:
	@echo "==> Removing dist directory..."
	@rm -rf "$(DIST_DIR)"
	@echo "==> Cleaning SwiftPM build artifacts..."
	@swift package clean
	@echo "==> Clean complete."
