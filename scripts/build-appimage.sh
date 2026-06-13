#!/bin/bash
set -Eeuo pipefail
# Build a portable AppImage from a previously built workbuddy-app/ directory.
#
# Usage:
#   make build-app                  # build workbuddy-app/ first
#   bash scripts/build-appimage.sh  # produce dist/WorkBuddy-*.AppImage
#
# Environment:
#   PACKAGE_VERSION     Version string (default: YYYY.MM.DD.HHMMSS)
#   PACKAGE_NAME        Application slug (default: WorkBuddy)
#   APPIMAGETOOL_URL    Custom appimagetool download URL (default: GitHub release)
#   ARCH                Target architecture (default: auto-detect from uname -m)
#
# Dependencies at build time:
#   - appimagetool (auto-downloaded to .cache/appimagetool if not in PATH)
#   - fuse2 / fuse3 (for running AppImage; not needed for building on modern Linux)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_DIR/scripts/lib/common.sh"

APP_DIR="${APP_DIR:-$REPO_DIR/workbuddy-app}"
DIST_DIR="${DIST_DIR:-$REPO_DIR/dist}"
CACHE_DIR="${CACHE_DIR:-$REPO_DIR/.cache}"
PACKAGE_NAME="${PACKAGE_NAME:-WorkBuddy}"
APP_ID="${APP_ID:-workbuddy}"
PACKAGE_VERSION="${PACKAGE_VERSION:-$(resolve_package_version)}"
DESKTOP_TEMPLATE="$REPO_DIR/packaging/linux/workbuddy.desktop"

map_arch() {
    case "${ARCH:-$(uname -m)}" in
        x86_64|amd64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *) error "Unsupported AppImage architecture: ${ARCH:-$(uname -m)}" ;;
    esac
}

# Download appimagetool if not available in PATH or cache.
resolve_appimagetool() {
    if command -v appimagetool >/dev/null 2>&1; then
        command -v appimagetool
        return 0
    fi

    local arch cache_dir tool_path
    arch="$(map_arch)"
    cache_dir="$CACHE_DIR/appimagetool"
    tool_path="$cache_dir/appimagetool-$arch"

    if [ -x "$tool_path" ]; then
        echo "$tool_path"
        return 0
    fi

    local url
    case "$arch" in
        x86_64) url="${APPIMAGETOOL_URL:-https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage}" ;;
        aarch64) url="${APPIMAGETOOL_URL:-https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-aarch64.AppImage}" ;;
    esac

    info "Downloading appimagetool for $arch ..."
    mkdir -p "$cache_dir"
    curl -fsSL -o "$tool_path" "$url" || error "Failed to download appimagetool from $url"
    chmod +x "$tool_path"
    echo "$tool_path"
}

main() {
    [ -x "$APP_DIR/start.sh" ] || error "Missing generated app. Run make build-app first."

    local arch output_file appdir_path
    arch="$(map_arch)"
    output_file="$DIST_DIR/${PACKAGE_NAME}-${PACKAGE_VERSION}-${arch}.AppImage"
    appdir_path="$DIST_DIR/AppDir"

    # Clean and re-create AppDir
    rm -rf "$appdir_path"
    mkdir -p \
        "$appdir_path/opt/$APP_ID" \
        "$appdir_path/usr/bin" \
        "$appdir_path/usr/share/applications" \
        "$appdir_path/usr/share/icons/hicolor/256x256/apps"

    # ---------------------------------------------------------------
    # 1. Copy app payload
    # ---------------------------------------------------------------
    info "Copying app payload into AppDir ..."
    cp -a "$APP_DIR/." "$appdir_path/opt/$APP_ID/"

    # ---------------------------------------------------------------
    # 2. Generate AppRun entry point
    # ---------------------------------------------------------------
    cat > "$appdir_path/AppRun" <<'APPRUN'
#!/bin/bash
set -euo pipefail

# ---- AppImage metadata ----
APPDIR="$(dirname "$(readlink -f "$0")")"
export APPIMAGE="${APPIMAGE:-}"
export APPDIR="${APPDIR:-}"

# ---- App-specific exports (same as start.sh) ----
export CHROME_DESKTOP="workbuddy.desktop"
export ELECTRON_FORCE_IS_PACKAGED=1
export XDG_CURRENT_DESKTOP="Unity:${XDG_CURRENT_DESKTOP:-}"
export MCP_TIMEOUT="${MCP_TIMEOUT:-3000}"
export MCP_TOOL_TIMEOUT="${MCP_TOOL_TIMEOUT:-30000}"
# Avoid double-dipping into sidecar re-direct when launched through AppImage
unset ELECTRON_RUN_AS_NODE

# ---- Ozone / Wayland hints ----
ARGS=(
  --disable-dev-shm-usage
  --in-process-gpu
  --ozone-platform-hint=auto
  --enable-wayland-ime
)

# ---- AppImage cannot use setuid chrome-sandbox (FUSE) ----
if [ "${WORKBUDDY_DISABLE_SANDBOX:-0}" = "1" ] || [ -n "${APPIMAGE:-}" ]; then
  ARGS+=(--no-sandbox --disable-gpu-sandbox)
fi

# ---- Launch Electron ----
exec "$APPDIR/opt/workbuddy/electron" "${ARGS[@]}" "$@"
APPRUN
    chmod 0755 "$appdir_path/AppRun"

    # ---------------------------------------------------------------
    # 3. Desktop entry
    # ---------------------------------------------------------------
    sed -e "s|__EXEC__|opt/workbuddy/start.sh %F|g" "$DESKTOP_TEMPLATE" \
        > "$appdir_path/usr/share/applications/$APP_ID.desktop"
    chmod 0644 "$appdir_path/usr/share/applications/$APP_ID.desktop"
    # Also link root-level .desktop for appimagetool discovery
    cp -a "$appdir_path/usr/share/applications/$APP_ID.desktop" "$appdir_path/$APP_ID.desktop"

    # ---------------------------------------------------------------
    # 4. Icon
    # ---------------------------------------------------------------
    if [ -f "$APP_DIR/.workbuddy-linux/workbuddy.png" ]; then
        cp "$APP_DIR/.workbuddy-linux/workbuddy.png" \
            "$appdir_path/usr/share/icons/hicolor/256x256/apps/workbuddy.png"
        chmod 0644 "$appdir_path/usr/share/icons/hicolor/256x256/apps/workbuddy.png"
        cp -a "$appdir_path/usr/share/icons/hicolor/256x256/apps/workbuddy.png" "$appdir_path/workbuddy.png"
    fi
    # .DirIcon is required by the AppImage spec
    if [ -f "$appdir_path/workbuddy.png" ]; then
        cp "$appdir_path/workbuddy.png" "$appdir_path/.DirIcon"
    fi

    # ---------------------------------------------------------------
    # 5. Sanity check against the AppDir spec
    # ---------------------------------------------------------------
    [ -f "$appdir_path/AppRun" ] || error "AppDir missing AppRun"
    [ -f "$appdir_path/$APP_ID.desktop" ] || error "AppDir missing .desktop entry"
    if [ ! -f "$appdir_path/.DirIcon" ] && [ ! -f "$appdir_path/workbuddy.png" ]; then
        warn "No PNG icon found; appimagetool may embed a placeholder"
    fi

    # ---------------------------------------------------------------
    # 6. Build the AppImage
    # ---------------------------------------------------------------
    local appimagetool
    appimagetool="$(resolve_appimagetool)"
    info "Building AppImage with $appimagetool ..."
    mkdir -p "$DIST_DIR"
    # appimagetool is itself an AppImage; on systems without FUSE it may
    # fail at first. APPIMAGE_EXTRACT_AND_RUN=1 tells it to self-extract
    # to a temp dir instead of using FUSE mount, which works everywhere.
    # appimagetool exits 0 even on warnings; capture stderr for diagnostics.
    APPIMAGE_EXTRACT_AND_RUN=1 \
    $appimagetool \
        --no-appstream \
        "$appdir_path" "$output_file" 2>&1 | \
        grep -v "WARNING:.*updateinfo\|WARNING:.*appstream\|AppStream\|updateinformation" || true

    if [ -f "$output_file" ]; then
        chmod 0755 "$output_file"
        info "Built AppImage: $output_file ($(du -h "$output_file" | cut -f1))"
    else
        error "appimagetool did not produce an output file"
    fi

    # Clean up
    rm -rf "$appdir_path"
}

main "$@"
