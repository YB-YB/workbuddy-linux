#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_DIR/scripts/lib/common.sh"

detect_package_format() {
    if command -v dpkg-deb >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
        echo "deb"
    elif command -v rpmbuild >/dev/null 2>&1; then
        echo "rpm"
    elif command -v makepkg >/dev/null 2>&1; then
        echo "pacman"
    else
        error "Could not detect a supported package builder. Install dpkg-deb, rpmbuild, or makepkg."
    fi
}

case "${PACKAGE_FORMAT:-$(detect_package_format)}" in
    deb) bash "$REPO_DIR/scripts/build-deb.sh" ;;
    rpm) bash "$REPO_DIR/scripts/build-rpm.sh" ;;
    pacman|pkg.tar.zst) bash "$REPO_DIR/scripts/build-pacman.sh" ;;
    *) error "Unsupported PACKAGE_FORMAT: ${PACKAGE_FORMAT}" ;;
esac
