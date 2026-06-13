SHELL := /bin/bash

.PHONY: help deps build-app run-app deb rpm pacman appimage package install check clean

help:
	@echo "Targets:"
	@echo "  make deps"
	@echo "  make build-app"
	@echo "  make build-app DMG=/path/to/WorkBuddy.dmg"
	@echo "  make run-app"
	@echo "  make deb"
	@echo "  make rpm"
	@echo "  make pacman"
	@echo "  make appimage"
	@echo "  make package               # auto-detect: deb / rpm / pacman / appimage"
	@echo "  make install"
	@echo "  make check"
	@echo "  make clean"

deps:
	bash scripts/install-deps.sh

build-app:
	@if [ -n "$(DMG)" ]; then bash install.sh "$(DMG)"; else bash install.sh; fi

run-app:
	bash workbuddy-app/start.sh

deb:
	bash scripts/build-deb.sh

rpm:
	bash scripts/build-rpm.sh

pacman:
	bash scripts/build-pacman.sh

appimage:
	bash scripts/build-appimage.sh

package:
	bash scripts/package.sh

install:
	bash scripts/install-package.sh

check:
	bash -n install.sh scripts/*.sh scripts/lib/*.sh
	node --check scripts/lib/apply-linux-patches.js
	bash scripts/check-portability.sh

clean:
	rm -rf workbuddy-app workbuddy-app-next dist dist-next
	rm -rf .asar-tool .asar-extract .test-repack.asar .test-repack.asar.unpacked
	rm -f .tmp-asar-tool.js .tmp-asar-repack.js
	rm -rf dist/AppDir
