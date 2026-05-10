SHELL := /bin/bash

.PHONY: help deps build-app run-app deb rpm pacman package install clean check

help:
	@echo "Targets:"
	@echo "  make deps"
	@echo "  make build-app"
	@echo "  make build-app DMG=/path/to/WorkBuddy.dmg"
	@echo "  make run-app"
	@echo "  make deb"
	@echo "  make rpm"
	@echo "  make pacman"
	@echo "  make package"
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

package:
	bash scripts/package.sh

install:
	bash scripts/install-package.sh

check:
	bash -n install.sh scripts/*.sh scripts/lib/*.sh

clean:
	rm -rf workbuddy-app workbuddy-app-next dist dist-next
