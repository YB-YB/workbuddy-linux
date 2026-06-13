#!/bin/bash
# Shared shell helpers. Sourced by scripts; do not run directly.

info() {
    echo "[INFO] $*" >&2
}

warn() {
    echo "[WARN] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"
}

find_7z() {
    if command -v 7zz >/dev/null 2>&1; then
        command -v 7zz
        return 0
    fi
    if command -v 7z >/dev/null 2>&1; then
        local version_output major_version
        version_output="$(7z -version 2>&1 || true)"
        if [[ "$version_output" =~ 7-Zip\ (\[[0-9]+\]\ )?([0-9]+)\. ]]; then
            major_version="${BASH_REMATCH[2]}"
            if [ "$major_version" -lt 21 ]; then
                error "Found legacy p7zip (version $major_version), which cannot extract modern DMG files properly.
Please install the official 7zip package (version >= 21) instead:
  Debian/Ubuntu: sudo apt install 7zip (remove p7zip-full first)
  Fedora/RHEL:   sudo dnf install 7zip
  Arch Linux:    sudo pacman -S 7zip
  openSUSE:      sudo zypper install 7zip"
            fi
        fi
        command -v 7z
        return 0
    fi
    error "Missing 7z/7zz. Install 7zip."
}

# Read the upstream version from a built workbuddy-app's build-info.json.
# If PACKAGE_VERSION is already set, return it. Otherwise try to parse
# build-info.json; fall back to a UTC date string.
resolve_package_version() {
    local app_dir="${APP_DIR:-$REPO_DIR/workbuddy-app}"
    local build_info="$app_dir/.workbuddy-linux/build-info.json"
    if [ -z "${PACKAGE_VERSION:-}" ] && [ -f "$build_info" ]; then
        PACKAGE_VERSION="$(python3 -c "
import json, sys
with open('$build_info') as f:
    print(json.load(f).get('upstreamVersion', ''))
" 2>/dev/null)" || true
    fi
    echo "${PACKAGE_VERSION:-$(date -u +%Y.%m.%d.%H%M%S)}"
}

sanitize_package_tree() {
    local target_dir="$1"
    [ -d "$target_dir" ] || return 0
    find "$target_dir" -depth -name '*:*' -exec rm -rf {} +
}
