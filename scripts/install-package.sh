#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_DIR/scripts/lib/common.sh"

latest_artifact() {
    local pattern="$1"
    [ -d "$REPO_DIR/dist" ] || return 0
    find "$REPO_DIR/dist" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr \
        | awk 'NR == 1 { sub(/^[^ ]+ /, ""); print }'
}

install_deb() {
    local artifact
    artifact="$(latest_artifact 'workbuddy_*.deb')"
    [ -n "$artifact" ] || return 1
    info "Installing $artifact"
    sudo dpkg -i "$artifact"
}

install_rpm() {
    local artifact
    artifact="$(latest_artifact 'workbuddy-*.rpm')"
    [ -n "$artifact" ] || return 1
    info "Installing $artifact"
    if command -v dnf5 >/dev/null 2>&1; then
        sudo dnf5 install -y "$artifact"
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "$artifact"
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper --non-interactive --no-gpg-checks install "$artifact"
    else
        return 1
    fi
}

install_pacman() {
    local artifact
    artifact="$(latest_artifact 'workbuddy-*.pkg.tar.zst')"
    [ -n "$artifact" ] || return 1
    command -v pacman >/dev/null 2>&1 || return 1
    info "Installing $artifact"
    sudo pacman -U --noconfirm "$artifact"
}

main() {
    if command -v dpkg >/dev/null 2>&1 && install_deb; then
        return 0
    fi
    if install_rpm; then
        return 0
    fi
    if install_pacman; then
        return 0
    fi

    error "No installable package artifact found in dist/. Run make package first."
}

main "$@"
